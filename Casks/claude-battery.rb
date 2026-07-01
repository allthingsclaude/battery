cask "claude-battery" do
  version "0.6.0"
  sha256 "d0f6c4de5bab79679645943f2691d85acb8d553d0b73516d3702a6c089635223"

  url "https://github.com/allthingsclaude/battery/releases/download/v0.6.0/Battery-0.6.0.dmg"
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
