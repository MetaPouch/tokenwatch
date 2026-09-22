cask "tokenwatch" do
  version "1.2.0"
  sha256 "82d1852ee88b7fc4c5c4a6468d123d032f03c7f36441e565a5da03db8f2b8b2d"

  url "https://github.com/MetaPouch/tokenwatch/releases/download/v#{version}/TokenWatch-#{version}.dmg"
  name "TokenWatch"
  desc "Menu-bar usage tracker for AI subscriptions, routing providers, and API keys"
  homepage "https://tokenwatch.fyi"

  auto_updates false
  depends_on macos: :sonoma

  app "TokenWatch.app"

  zap trash: [
    "~/Library/Application Support/TokenWatch",
    "~/Library/Caches/dev.tokenwatch.TokenWatch",
    "~/Library/Preferences/dev.tokenwatch.TokenWatch.plist",
    "~/Library/Saved Application State/dev.tokenwatch.TokenWatch.savedState",
  ]
end
