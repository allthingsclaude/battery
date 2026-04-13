cask "claude-battery" do
  version "0.3.7"
  sha256 "99815b2c798c34bc250d73931714bff09fafd7a5234d4bd780287482c653492e"

  url "https://github.com/allthingsclaude/battery/releases/download/v0.3.7/Battery-0.3.7.dmg"
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
