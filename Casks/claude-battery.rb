cask "claude-battery" do
  version "0.9.1"
  sha256 "d4d3cb5ca9fab5532ef26c3010184a4d99bf783b966763a99dd88bd067222d5c"

  url "https://github.com/allthingsclaude/battery/releases/download/v0.9.1/Battery-0.9.1.dmg"
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
