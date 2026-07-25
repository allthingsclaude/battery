cask "claude-battery" do
  version "0.7.3"
  sha256 "ff6235f93b042ff3a680d71c7724ab185ec2c9157a777f6baec60602f89198ec"

  url "https://github.com/allthingsclaude/battery/releases/download/v0.7.3/Battery-0.7.3.dmg"
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
