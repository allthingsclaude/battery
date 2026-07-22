cask "claude-battery" do
  version "0.6.3"
  sha256 "ab09859f6e822fc81302801ae9c8d4dc3ed0b46db0cc62e652174139bd26bc7d"

  url "https://github.com/allthingsclaude/battery/releases/download/v0.6.3/Battery-0.6.3.dmg"
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
