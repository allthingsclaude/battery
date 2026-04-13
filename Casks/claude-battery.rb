cask "claude-battery" do
  version "0.3.6"
  sha256 "67b03901d28255482f4ef0bf5248d1f138f49cb4fe45a97afa9446154b41c586"

  url "https://github.com/allthingsclaude/battery/releases/download/v0.3.6/Battery-0.3.6.dmg"
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
