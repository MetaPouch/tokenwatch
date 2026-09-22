import Foundation

/// The app's own version, for display in the UI (dashboard header, Settings). Reads
/// `CFBundleShortVersionString` from the running bundle's `Info.plist` -- set by
/// `scripts/release.sh` for every real build. A `swift run` dev build has no such bundle
/// entry, so this falls back to a plain "dev" label rather than showing a blank or a stale value.
enum AppVersion {
    static var displayString: String {
        guard let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !version.isEmpty else {
            return "dev"
        }
        return version
    }
}
