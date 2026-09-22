import Foundation

/// Tracks which one-time dashboard hint cards the user has already dismissed, so each shows
/// exactly once across the app's lifetime (never re-appears after being dismissed, doesn't
/// reappear on relaunch). Backed by plain `UserDefaults` -- two booleans don't warrant their own
/// JSON file the way the larger stores' settings do.
@MainActor
public final class HintStore: ObservableObject {
    private enum Key {
        static let providerDetectionDismissed = "hint.providerDetection.dismissed"
        static let customizeTipDismissed = "hint.customizeTip.dismissed"
    }

    @Published public var providerDetectionDismissed: Bool {
        didSet { defaults.set(providerDetectionDismissed, forKey: Key.providerDetectionDismissed) }
    }
    @Published public var customizeTipDismissed: Bool {
        didSet { defaults.set(customizeTipDismissed, forKey: Key.customizeTipDismissed) }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.providerDetectionDismissed = defaults.bool(forKey: Key.providerDetectionDismissed)
        self.customizeTipDismissed = defaults.bool(forKey: Key.customizeTipDismissed)
    }

    public func dismissProviderDetection() { providerDetectionDismissed = true }
    public func dismissCustomizeTip() { customizeTipDismissed = true }
}
