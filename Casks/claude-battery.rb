cask "claude-battery" do
  version "0.7.1"
  sha256 "fd6935d675e8fb2f817a75225d7186c3f9564de33909bcd33f5590730d9f4fd5"

  url "https://github.com/allthingsclaude/battery/releases/download/v0.7.1/Battery-0.7.1.dmg"
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
