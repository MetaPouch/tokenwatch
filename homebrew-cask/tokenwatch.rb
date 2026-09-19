cask "tokenwatch" do
  version "1.1.0"
  sha256 "70741e0407721f324c1a80aae2545e7a31ab320f9b70a535261f5565e7a20902"

  url "https://github.com/ajays97/tokenwatch/releases/download/v#{version}/TokenWatch-#{version}.dmg"
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
