cask "claude-battery" do
  version "0.4.0"
  sha256 "a8dcc20307f2921d37a863097dc982cd4995728d532fd3832b835d68ab126944"

  url "https://github.com/allthingsclaude/battery/releases/download/v0.4.0/Battery-0.4.0.dmg"
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
