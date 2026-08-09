cask "claude-battery" do
  version "0.8.0"
  sha256 "a7ac1f3c59c1c115e04b6eb94f564b8bc5b1a108925dbe823d146c3de598620e"

  url "https://github.com/allthingsclaude/battery/releases/download/v0.8.0/Battery-0.8.0.dmg"
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
