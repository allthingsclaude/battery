cask "claude-battery" do
  version "0.5.4"
  sha256 "2b04132d9bce13c24983a9ce3c692bb0fdde3a8b96e56f555ee97b5494f05d8e"

  url "https://github.com/allthingsclaude/battery/releases/download/v0.5.4/Battery-0.5.4.dmg"
  name "Battery"
  desc "Claude Code usage monitor for your menu bar"
  homepage "https://github.com/allthingsclaude/battery"

  app "Battery.app"
  binary "#{appdir}/Battery.app/Contents/Resources/claude-battery"

  zap trash: [
    "~/Library/Preferences/com.allthingsclaude.battery.plist",
    "~/.battery",
  ]
end
