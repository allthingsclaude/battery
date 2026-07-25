cask "claude-battery" do
  version "0.7.2"
  sha256 "7f2c0052b37fd2b5cb49a6dfc4e7208b379da8790644079ea47b9dbd2a438ba0"

  url "https://github.com/allthingsclaude/battery/releases/download/v0.7.2/Battery-0.7.2.dmg"
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
