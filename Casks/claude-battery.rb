cask "claude-battery" do
  version "0.8.3"
  sha256 "21bcc2abcf8319cd5e6c18b9d3020a3e5b5dd9acdc9fd2b9d27aa8b988bd332f"

  url "https://github.com/allthingsclaude/battery/releases/download/v0.8.3/Battery-0.8.3.dmg"
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
