cask "claude-battery" do
  version "0.9.0"
  sha256 "532f79d0ca840943dcda910c26c82839dfa3ca2497ab590154e2020bcaed1a8d"

  url "https://github.com/allthingsclaude/battery/releases/download/v0.9.0/Battery-0.9.0.dmg"
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
