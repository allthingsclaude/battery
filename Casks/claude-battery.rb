cask "claude-battery" do
  version "0.3.8"
  sha256 "a0d7c41d43167cfea072ed444e0d1cd325c4ccb54489e4339c3241449dd37058"

  url "https://github.com/allthingsclaude/battery/releases/download/v0.3.8/Battery-0.3.8.dmg"
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
