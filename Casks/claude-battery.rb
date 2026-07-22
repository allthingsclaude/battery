cask "claude-battery" do
  version "0.6.1"
  sha256 "78911345b90d7c7e3133145c2299c75a3cdf603c2d6c4a50b91016d4941fe9e6"

  url "https://github.com/allthingsclaude/battery/releases/download/v0.6.1/Battery-0.6.1.dmg"
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
