cask "claude-battery" do
  version "0.5.2"
  sha256 "0d1063bb473061b073ae773a7b7ed22d8ae48c45f1a1964db336f433c24f0b3f"

  url "https://github.com/allthingsclaude/battery/releases/download/v0.5.2/Battery-0.5.2.dmg"
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
