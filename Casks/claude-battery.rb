cask "claude-battery" do
  version "0.5.1"
  sha256 "476dbcd516545c7b40322a6018819f86599862f73157b8fbf89c1ceefe815df4"

  url "https://github.com/allthingsclaude/battery/releases/download/v0.5.1/Battery-0.5.1.dmg"
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
