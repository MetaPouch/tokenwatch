cask "tokenwatch" do
  version "1.8.7"
  sha256 "be1fba4c0107e70a1928bbb24a1a0b81fe44daba7a282373c6ec4fcccba8a903"

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
