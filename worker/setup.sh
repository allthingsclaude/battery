#!/usr/bin/env bash
#
# One-time setup for the Battery push relay.
#
# Creates the KV namespace, wires wrangler.toml, uploads both secrets, and
# deploys. Safe to re-run — it skips whatever is already configured.
#
#   cd worker && ./setup.sh
#
# Prerequisites: a Cloudflare account (free), and an APNs auth key (.p8) from an
# Apple Developer account. See the README for how to create the key.

set -euo pipefail

cd "$(dirname "$0")"
TOML=wrangler.toml
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
ask() { printf '\033[1m%s\033[0m ' "$1"; read -r REPLY; }

command -v npx >/dev/null || { echo "node/npx is required"; exit 1; }
[ -d node_modules/wrangler ] || { say "Installing wrangler…"; npm install; }
WRANGLER="npx wrangler"

# ── 1. Cloudflare login ──────────────────────────────────────────────────

say "1/5  Cloudflare account"
if $WRANGLER whoami 2>/dev/null | grep -qi "you are logged in\|account id"; then
  ok "already logged in"
else
  echo "  A browser window will open to authorise wrangler."
  $WRANGLER login
fi

# ── 2. KV namespace ──────────────────────────────────────────────────────

say "2/5  KV namespace"
if grep -q 'REPLACE_WITH_YOUR_KV_NAMESPACE_ID' "$TOML"; then
  echo "  Creating namespace DEVICES…"
  OUT=$($WRANGLER kv namespace create DEVICES 2>&1 | tee /dev/stderr)
  # wrangler has printed the id in a few shapes over the years; take the first
  # 32-char hex string, which is unambiguous.
  KV_ID=$(printf '%s' "$OUT" | grep -oE '[0-9a-f]{32}' | head -1)
  [ -n "$KV_ID" ] || { echo "Couldn't parse the namespace id — paste it into $TOML by hand."; exit 1; }
  perl -pi -e "s/REPLACE_WITH_YOUR_KV_NAMESPACE_ID/$KV_ID/" "$TOML"
  ok "namespace created and written to $TOML ($KV_ID)"
else
  ok "already set in $TOML"
fi

# ── 3. APNs identifiers ──────────────────────────────────────────────────

say "3/5  APNs key + team"
if grep -q 'REPLACE_WITH_YOUR_APNS_KEY_ID' "$TOML"; then
  cat <<'EOF'
  Create the key at https://developer.apple.com/account/resources/authkeys/list
    Keys ▸ ＋ ▸ name it "Battery Push"
    ▸ tick "Apple Push Notifications service (APNs)" ▸ Continue ▸ Register
    ▸ Download.  Apple lets you download the .p8 EXACTLY ONCE.

  The Key ID is the 10 characters in the filename: AuthKey_XXXXXXXXXX.p8
EOF
  ask "  Key ID:"; KEY_ID="$REPLY"
  [ -n "$KEY_ID" ] || { echo "A Key ID is required."; exit 1; }
  perl -pi -e "s/REPLACE_WITH_YOUR_APNS_KEY_ID/$KEY_ID/" "$TOML"
  ok "Key ID written to $TOML"
else
  ok "Key ID already set"
fi

CURRENT_TEAM=$(grep -E '^APNS_TEAM_ID' "$TOML" | sed -E 's/.*"(.*)".*/\1/')
echo "  Team ID currently set to: $CURRENT_TEAM"
ask "  Press return to keep it, or type a different Team ID:"
if [ -n "$REPLY" ]; then
  perl -pi -e "s/^APNS_TEAM_ID = .*/APNS_TEAM_ID = \"$REPLY\"/" "$TOML"
  ok "Team ID updated"
fi

# ── 4. Secrets ───────────────────────────────────────────────────────────

say "4/5  Secrets"
ask "  Path to your AuthKey_XXXXXXXXXX.p8:"
P8=$(printf '%s' "$REPLY" | sed "s/^['\"]//;s/['\"]$//")   # tolerate drag-and-drop quoting
P8="${P8/#\~/$HOME}"
[ -f "$P8" ] || { echo "  No file at: $P8"; exit 1; }
grep -q 'BEGIN PRIVATE KEY' "$P8" || {
  echo "  That file isn't a PKCS#8 key. Apple's .p8 starts with '-----BEGIN PRIVATE KEY-----'."
  exit 1
}
# Piped from the file so the key is never echoed or stored in shell history.
$WRANGLER secret put APNS_KEY < "$P8"
ok "APNS_KEY uploaded"

openssl rand -base64 48 | $WRANGLER secret put CLOUD_KEY
ok "CLOUD_KEY generated and uploaded"

# ── 5. Deploy ────────────────────────────────────────────────────────────

say "5/5  Deploy"
# Run plainly, NOT under $(…): capturing stdout makes wrangler treat itself as
# non-interactive, so its prompts silently take the fallback answer — which is
# "no" for registering a workers.dev subdomain, and that one is required.
$WRANGLER deploy || {
  cat <<'EOF'

  Deploy failed. If it asked for a workers.dev subdomain, register one at the
  dashboard link printed above (one-time, any name), then re-run this script.
EOF
  exit 1
}

ask "  Paste the workers.dev URL printed above:"
URL=$(printf '%s' "$REPLY" | sed 's#/*$##')

if [ -n "$URL" ]; then
  say "Done — $URL"
  echo "  Health check:"
  curl -s "$URL/v1/health"; echo
  cat <<EOF

  Next: paste that URL back into the conversation and I'll run the full
  integration suite against it, including a real APNs round-trip.

  It also needs to go into both apps:
    ios/BatteryApp/AppConfig.swift   → AppConfig.defaultPushRelayURL
    Sources/Utilities/Constants.swift → Constants.pushRelayURL
EOF
else
  echo "Deployed, but couldn't parse the URL — find it with: npx wrangler deployments list"
fi
