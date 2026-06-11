cask "claude-battery" do
  version "0.3.10"
  sha256 "1f9d8b6182426baec2aca38acaf74df9e71c5d27fe62ce3be22574e10ca98031"

  url "https://github.com/allthingsclaude/battery/releases/download/v0.3.10/Battery-0.3.10.dmg"
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
