cask "claude-battery" do
  version "0.5.0"
  sha256 "d535220b52b42155d0cebdd85d7ff2544b53a6cbf63f2566f6f4c47458015c7e"

  url "https://github.com/allthingsclaude/battery/releases/download/v0.5.0/Battery-0.5.0.dmg"
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
