cask "tokenwatch" do
  version "1.4.1"
  sha256 "b7ea723aeaecc8c137ad29f86496a1ccb501dff9453991efcc3408f4cc810d40"

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
