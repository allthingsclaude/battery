#!/bin/bash

# App Store Connect TestFlight helper — the half of the release the CI workflow
# doesn't do.
#
#   ./Scripts/testflight.sh status
#   ./Scripts/testflight.sh distribute <build-number> [group]
#
# `altool --upload-app` hands the binary to App Store Connect and stops. A build
# is only installable once it belongs to a **testing group**, and nothing in
# ios-release.yml does that — which is why an uploaded build can sit in "Version
# X" forever while testers see nothing. `status` shows exactly where every recent
# build stands; `distribute` assigns one to a group.
#
# Credentials — the same App Store Connect API key the workflow uses. The key
# itself can arrive as a file or as its contents, so this runs unchanged on a
# laptop and inside CI (where it comes straight from a secret):
#
#   export ASC_KEY_ID=XXXXXXXXXX
#   export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#   export ASC_KEY_PATH=~/path/to/AuthKey_XXXXXXXXXX.p8   # or ASC_KEY=<PEM text>
#
# The key needs the App Manager role to change TestFlight distribution; a
# Developer-role key can read but the POST comes back 403.

set -euo pipefail

BUNDLE_ID="com.allthingsclaude.battery.ios"
DEFAULT_GROUP="Battery"
API="https://api.appstoreconnect.apple.com"

# How long `distribute` waits for a just-uploaded build to finish processing.
WAIT_SECONDS="${ASC_WAIT_SECONDS:-1500}"

CMD="${1:-status}"

# ── Credentials ─────────────────────────────────────────────────────────

KEY_ID="${ASC_KEY_ID:-}"
ISSUER_ID="${ASC_ISSUER_ID:-}"
KEY_PATH="${ASC_KEY_PATH:-}"
TEMP_KEY=""

cleanup() { [ -n "$TEMP_KEY" ] && rm -f "$TEMP_KEY"; }
trap cleanup EXIT

# ASC_KEY carries the PEM itself — how a CI secret naturally arrives. Accept it
# base64-wrapped too, since that's a common way to paste a .p8 into a secret
# store (and what ios-release.yml already tolerates).
if [ -z "$KEY_PATH" ] && [ -n "${ASC_KEY:-}" ]; then
  TEMP_KEY=$(mktemp)
  chmod 600 "$TEMP_KEY"
  printf '%s\n' "$ASC_KEY" > "$TEMP_KEY"
  if ! grep -q "BEGIN PRIVATE KEY" "$TEMP_KEY"; then
    if base64 --decode < "$TEMP_KEY" 2>/dev/null | grep -q "BEGIN PRIVATE KEY"; then
      base64 --decode < "$TEMP_KEY" > "$TEMP_KEY.pem" && mv "$TEMP_KEY.pem" "$TEMP_KEY"
      chmod 600 "$TEMP_KEY"
    fi
  fi
  KEY_PATH="$TEMP_KEY"
fi

# Fall back to the directory altool and xcodebuild look in, so a key already set
# up for local uploads works without extra environment.
if [ -z "$KEY_PATH" ] && [ -n "$KEY_ID" ]; then
  CANDIDATE="$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"
  [ -f "$CANDIDATE" ] && KEY_PATH="$CANDIDATE"
fi

if [ -z "$KEY_ID" ] || [ -z "$ISSUER_ID" ] || [ -z "$KEY_PATH" ]; then
  echo "Error: missing credentials. Set all three:"
  echo "  ASC_KEY_ID      the key's 10-character ID"
  echo "  ASC_ISSUER_ID   the issuer UUID (App Store Connect ▸ Users and Access ▸ Integrations)"
  echo "  ASC_KEY_PATH    path to AuthKey_<KEY_ID>.p8  (or ASC_KEY with the PEM text)"
  exit 1
fi

KEY_PATH="${KEY_PATH/#\~/$HOME}"
if [ ! -f "$KEY_PATH" ]; then
  echo "Error: no such key file: $KEY_PATH"
  echo "       Apple lets a .p8 be downloaded exactly once — if it's gone,"
  echo "       revoke that key and issue a new one."
  exit 1
fi

# Check the key parses before signing anything. Without this, a file that isn't
# a key produces an unsigned token and Apple answers 401 "credentials are
# invalid" — which sends you hunting for a permissions problem that isn't there.
if ! openssl pkey -in "$KEY_PATH" -noout 2>/dev/null; then
  echo "Error: $KEY_PATH is not a private key."
  echo "       Expected PEM text beginning -----BEGIN PRIVATE KEY-----."
  echo "       ($(wc -c < "$KEY_PATH" | tr -d ' ') bytes, $(wc -l < "$KEY_PATH" | tr -d ' ') line(s).)"
  echo "       If you wrote it with pbpaste, make sure the key — not something"
  echo "       else — was on the clipboard."
  exit 1
fi

for tool in jq openssl; do
  command -v "$tool" >/dev/null || { echo "Error: $tool is required."; exit 1; }
done

# Hex to raw bytes. xxd is normally there, but it rides along with vim rather
# than being part of any base system — perl is the more reliable of the two on a
# minimal CI image, so take whichever exists.
if command -v xxd >/dev/null; then
  hex2bin() { xxd -r -p; }
elif command -v perl >/dev/null; then
  hex2bin() { perl -pe 's/([0-9a-fA-F]{2})/chr hex $1/gie'; }
else
  echo "Error: need either xxd or perl to encode the signature."
  exit 1
fi

# ── ES256 JWT ───────────────────────────────────────────────────────────
# Apple requires ES256. openssl emits a DER-encoded signature, but JWS wants the
# raw r||s pair — hence the asn1parse dance rather than a straight base64.

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

mint_token() {
  local now exp header payload signing_input sig_der r s sig
  now=$(date +%s)
  exp=$((now + 1200))   # Apple rejects anything beyond 20 minutes

  header=$(printf '{"alg":"ES256","kid":"%s","typ":"JWT"}' "$KEY_ID" | b64url)
  payload=$(printf '{"iss":"%s","iat":%d,"exp":%d,"aud":"appstoreconnect-v1"}' \
    "$ISSUER_ID" "$now" "$exp" | b64url)
  signing_input="$header.$payload"

  sig_der=$(mktemp)
  printf '%s' "$signing_input" | openssl dgst -sha256 -sign "$KEY_PATH" -binary > "$sig_der"

  # Two INTEGERs: r then s. Each is left-padded to 32 bytes, and a leading 0x00
  # (DER's sign bit guard) is dropped.
  r=$(openssl asn1parse -inform der -in "$sig_der" | awk -F: 'NR==2 {print $4}')
  s=$(openssl asn1parse -inform der -in "$sig_der" | awk -F: 'NR==3 {print $4}')
  rm -f "$sig_der"

  r=$(printf '%064s' "${r: -64}" | tr ' ' '0')
  s=$(printf '%064s' "${s: -64}" | tr ' ' '0')
  sig=$(printf '%s%s' "$r" "$s" | hex2bin | b64url)

  printf '%s.%s' "$signing_input" "$sig"
}

TOKEN=$(mint_token)

api() {
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sS -X "$method" "$API$path" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "$body" -w '\n%{http_code}'
  else
    curl -sS -X "$method" "$API$path" \
      -H "Authorization: Bearer $TOKEN" -w '\n%{http_code}'
  fi
}

# Split the trailing status code off an api() response and fail loudly on it.
#
# Diagnostics go to stderr, never stdout: every caller pipes this into jq, so an
# error printed on stdout would be swallowed as malformed JSON and the real
# problem would surface as "parse error" instead. `set -o pipefail` then carries
# the non-zero status out of the command substitution and stops the script.
check() {
  local response="$1" context="$2" code payload
  code=$(printf '%s' "$response" | tail -n1)
  payload=$(printf '%s' "$response" | sed '$d')
  if ! [[ "$code" =~ ^[0-9]+$ ]]; then
    echo "Error: $context — no HTTP status in the response (network problem?)" >&2
    return 1
  fi
  if [ "$code" -ge 400 ]; then
    echo "Error: $context failed (HTTP $code)" >&2
    if ! printf '%s' "$payload" | jq -e -r '.errors[]? | "  \(.title): \(.detail)"' >&2 2>/dev/null; then
      printf '  %s\n' "$payload" >&2
    fi
    return 1
  fi
  printf '%s' "$payload"
}

# ── App ─────────────────────────────────────────────────────────────────

APP_ID=$(check "$(api GET "/v1/apps?filter\[bundleId\]=$BUNDLE_ID&fields\[apps\]=name")" \
  "app lookup" | jq -r '.data[0].id // empty')

if [ -z "$APP_ID" ]; then
  echo "Error: no app with bundle ID $BUNDLE_ID is visible to this key."
  exit 1
fi

# ── Commands ────────────────────────────────────────────────────────────

groups_json() {
  check "$(api GET "/v1/apps/$APP_ID/betaGroups?limit=50&fields\[betaGroups\]=name,isInternalGroup,hasAccessToAllBuilds")" \
    "beta group list"
}

case "$CMD" in
  status)
    echo "App: $BUNDLE_ID ($APP_ID)"
    echo ""
    echo "Beta groups"
    groups_json | jq -r '.data[] |
      "  \(.attributes.name)  [\(if .attributes.isInternalGroup then "internal" else "external" end)]" +
      "  auto-distribute: \(.attributes.hasAccessToAllBuilds)"'

    echo ""
    echo "Recent builds"
    BUILDS=$(check "$(api GET "/v1/builds?filter\[app\]=$APP_ID&limit=8&sort=-version&fields\[builds\]=version,processingState,expired,uploadedDate&include=preReleaseVersion")" \
      "build list")

    # Group membership is a per-build relationship, so it needs its own call.
    printf '%s' "$BUILDS" | jq -r '.data[] | "\(.id)\t\(.attributes.version)\t\(.attributes.processingState)\t\(.attributes.expired)"' |
    while IFS=$'\t' read -r id build state expired; do
      version=$(printf '%s' "$BUILDS" | jq -r --arg id "$id" \
        '(.included // [])[] | select(.type=="preReleaseVersions") | .attributes.version' | head -1)
      names=$(check "$(api GET "/v1/builds/$id/betaGroups?fields\[betaGroups\]=name")" "groups for build $build" |
        jq -r '[.data[].attributes.name] | join(", ")')
      [ -z "$names" ] && names="— none (testers cannot install this)"
      [ "$expired" = "true" ] && state="$state, expired"
      printf '  build %-6s %-12s groups: %s\n' "$build" "($state)" "$names"
    done
    ;;

  distribute)
    BUILD_NUMBER="${2:-}"
    GROUP_NAME="${3:-$DEFAULT_GROUP}"
    if [ -z "$BUILD_NUMBER" ]; then
      echo "Usage: ./Scripts/testflight.sh distribute <build-number> [group]"
      exit 1
    fi

    # Straight after an upload the build either isn't in the API yet or is still
    # PROCESSING, and it can't be assigned in either state — so wait rather than
    # fail. Run right after `altool --upload-app`, this is the whole difference
    # between a build testers can install and one that just sits there.
    DEADLINE=$(( $(date +%s) + WAIT_SECONDS ))
    BUILD_ID=""
    ANNOUNCED=false
    while :; do
      RESPONSE=$(check "$(api GET "/v1/builds?filter\[app\]=$APP_ID&filter\[version\]=$BUILD_NUMBER&fields\[builds\]=version,processingState,expired")" \
        "build lookup") || RESPONSE=""
      BUILD_ID=$(printf '%s' "$RESPONSE" | jq -r '.data[0].id // empty')
      STATE=$(printf '%s' "$RESPONSE" | jq -r '.data[0].attributes.processingState // empty')

      case "$STATE" in
        VALID)
          break
          ;;
        FAILED|INVALID)
          echo "Error: build $BUILD_NUMBER finished processing as $STATE — it can't be distributed."
          exit 1
          ;;
      esac

      if [ "$(date +%s)" -ge "$DEADLINE" ]; then
        echo "Error: build $BUILD_NUMBER is still ${STATE:-absent} after ${WAIT_SECONDS}s."
        echo "       Processing occasionally runs long; re-run this command later."
        exit 1
      fi

      if [ "$ANNOUNCED" = false ]; then
        echo "Waiting for build $BUILD_NUMBER to finish processing (${STATE:-not uploaded yet})..."
        ANNOUNCED=true
      fi
      sleep 30
      TOKEN=$(mint_token)   # Apple caps a token at 20 minutes; the wait can exceed that
    done

    GROUP_JSON=$(groups_json)
    GROUP_ID=$(printf '%s' "$GROUP_JSON" | jq -r --arg n "$GROUP_NAME" \
      '.data[] | select(.attributes.name == $n) | .id' | head -1)
    if [ -z "$GROUP_ID" ]; then
      echo "Error: no beta group named '$GROUP_NAME'. Groups on this app:"
      printf '%s' "$GROUP_JSON" | jq -r '.data[] | "  \(.attributes.name)"'
      exit 1
    fi

    if check "$(api GET "/v1/builds/$BUILD_ID/betaGroups?fields\[betaGroups\]=name")" \
         "groups for build $BUILD_NUMBER" | jq -e --arg n "$GROUP_NAME" \
         '.data[] | select(.attributes.name == $n)' >/dev/null; then
      echo "Build $BUILD_NUMBER is already distributed to '$GROUP_NAME'."
      exit 0
    fi

    # A group with automatic distribution ("has access to all builds") owns its
    # own membership, and App Store Connect may reject an explicit add as
    # redundant. Attempt it anyway rather than assuming: the flag being set is
    # not proof the build actually reached anyone, and a rejection tells us more
    # than a skip does. Only that specific case is downgraded to a warning.
    AUTO=$(printf '%s' "$GROUP_JSON" | jq -r --arg n "$GROUP_NAME" \
      '.data[] | select(.attributes.name == $n) | .attributes.hasAccessToAllBuilds')

    BODY=$(jq -nc --arg id "$BUILD_ID" '{data: [{type: "builds", id: $id}]}')
    if ! check "$(api POST "/v1/betaGroups/$GROUP_ID/relationships/builds" "$BODY")" \
           "adding build $BUILD_NUMBER to '$GROUP_NAME'" >/dev/null; then
      if [ "$AUTO" = "true" ]; then
        echo "Note: '$GROUP_NAME' has automatic distribution enabled, so App Store"
        echo "      Connect manages its builds and refused the explicit add above."
        echo "      Treating that as success — but if testers still can't see build"
        echo "      $BUILD_NUMBER, automatic distribution is not reaching them and the"
        echo "      switch should be turned off so builds can be assigned directly."
        exit 0
      fi
      exit 1
    fi

    echo "Build $BUILD_NUMBER is now distributed to '$GROUP_NAME'."
    echo "It appears in the TestFlight app within a minute or two."
    ;;

  *)
    echo "Usage: ./Scripts/testflight.sh status"
    echo "       ./Scripts/testflight.sh distribute <build-number> [group]"
    exit 1
    ;;
esac
