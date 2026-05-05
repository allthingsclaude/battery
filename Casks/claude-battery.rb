cask "claude-battery" do
  version "0.3.9"
  sha256 "8daa000fa5268997e825a8ec18182d782d27d1c76d192761b4c49f7002706cc0"

  url "https://github.com/allthingsclaude/battery/releases/download/v0.3.9/Battery-0.3.9.dmg"
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
