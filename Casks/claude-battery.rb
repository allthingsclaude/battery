cask "claude-battery" do
  version "0.9.3"
  sha256 "ebc072cd3621f3243a3ea6f66f4951ad04c874c82a7a8e197d4ca78e2e863300"

  url "https://github.com/allthingsclaude/battery/releases/download/v0.9.3/Battery-0.9.3.dmg"
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
