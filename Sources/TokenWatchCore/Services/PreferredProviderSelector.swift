import Foundation

/// Chooses which provider's detail the dashboard's provider picker should default to -- on
/// first launch, or whenever the previously-selected provider gets disabled. Mirrors the status
/// item's own precedence (see `StatusItemController`) so opening the dashboard shows the same
/// provider the menu bar was just talking about, rather than an unrelated one: prefer whichever
/// enabled provider has local activity within the last day, else whichever is closest to its own
/// limit, else simply the first enabled provider. Pure and independently testable; the status
/// item computes its own version of this inline since it also needs the ratio/tone for drawing,
/// not just the provider identity.
public enum PreferredProviderSelector {
    static let recentActivityWindowSeconds: TimeInterval = 24 * 3600

    public static func select(enabledProviders: [ProviderID], snapshots: [ProviderID: ProviderSnapshot], now: Date = Date()) -> ProviderID? {
        let cutoff = now.addingTimeInterval(-recentActivityWindowSeconds)

        let mostRecentlyActive = enabledProviders
            .compactMap { provider -> (ProviderID, Date)? in
                guard let activity = snapshots[provider]?.lastActivityAt, activity > cutoff else { return nil }
                return (provider, activity)
            }
            .max { $0.1 < $1.1 }?.0
        if let mostRecentlyActive { return mostRecentlyActive }

        let closestToLimit = enabledProviders
            .compactMap { provider -> (ProviderID, Double)? in
                guard let ratio = snapshots[provider]?.lines.compactMap(\.progressRatio).max() else { return nil }
                return (provider, ratio)
            }
            .max { $0.1 < $1.1 }?.0
        if let closestToLimit { return closestToLimit }

        return enabledProviders.first
    }
}
