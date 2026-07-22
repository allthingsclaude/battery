cask "claude-battery" do
  version "0.6.2"
  sha256 "a79c03db393ebcc48347f7472074206300c92517b3adcf0574122dba40802581"

  url "https://github.com/allthingsclaude/battery/releases/download/v0.6.2/Battery-0.6.2.dmg"
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
