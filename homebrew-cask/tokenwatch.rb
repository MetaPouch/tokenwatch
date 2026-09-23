cask "tokenwatch" do
  version "1.7.4"
  sha256 "40bba7f18f0bb2aefa61d74b7174380363e4b429c1b9cada0a198fac60811d3d"

  url "https://github.com/MetaPouch/tokenwatch/releases/download/v#{version}/TokenWatch-#{version}.dmg"
  name "TokenWatch"
  desc "Menu-bar usage tracker for AI subscriptions, routing providers, and API keys"
  homepage "https://tokenwatch.fyi"

  auto_updates false
  depends_on macos: :tahoe

  app "TokenWatch.app"

  zap trash: [
    "~/Library/Application Support/TokenWatch",
    "~/Library/Caches/dev.tokenwatch.TokenWatch",
    "~/Library/Preferences/dev.tokenwatch.TokenWatch.plist",
    "~/Library/Saved Application State/dev.tokenwatch.TokenWatch.savedState",
  ]
end
