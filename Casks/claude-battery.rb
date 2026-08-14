cask "claude-battery" do
  version "0.8.1"
  sha256 "42a3970978356065e64b11d34bbafd60e808532393315ccd9ffe651e211472d7"

  url "https://github.com/allthingsclaude/battery/releases/download/v0.8.1/Battery-0.8.1.dmg"
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
