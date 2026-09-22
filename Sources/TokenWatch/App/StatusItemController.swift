import AppKit
import SwiftUI
import Combine
import TokenWatchCore

/// Owns the `NSStatusItem`. Primary display: whichever enabled provider has the most recent
/// local activity signal (currently only Claude provides one) gets its name, its own session
/// percent (weekly is never shown here -- see `primaryRatio`), and a progress ring colored by
/// how close that is to the limit. When cache-temperature data is available the ring is tinted
/// warm-green or cold-blue instead of the usual threshold color. Because the percent is
/// account-wide but cache warmth is scoped to one specific local session, a hover tooltip names
/// which session and when it was last touched. Falls back to the MeterBar-style "closest to
/// limit across every enabled provider" ring when no provider has a recent-activity signal.
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let panel: TokenWatchPanel
    private let dataStore: WidgetDataStore
    private let enablementStore: ProviderEnablementStore
    private let layoutStore: LayoutStore
    private let appearanceStore: AppearanceStore
    private var cancellables: Set<AnyCancellable> = []

    init(container: AppContainer) {
        self.dataStore = container.dataStore
        self.enablementStore = container.enablementStore
        self.layoutStore = container.layoutStore
        self.appearanceStore = container.appearanceStore
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.panel = TokenWatchPanel(initialHeight: 420) { onHeightChange in
            DashboardView(dataStore: container.dataStore, enablementStore: container.enablementStore, refreshScheduler: container.refreshScheduler, apiKeyManagers: container.apiKeyManagers, usageService: container.usageService, layoutStore: container.layoutStore, displayStore: container.displayStore, appearanceStore: container.appearanceStore, notificationSettingsStore: container.notificationSettingsStore, claudeSpendHistoryStore: container.claudeSpendHistoryStore, notificationService: container.notificationService, toggleDashboardPanel: { container.toggleDashboardPanel() }, onHeightChange: onHeightChange)
        }

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.imagePosition = .imageLeading
        }

        render()

        dataStore.$snapshots
            .combineLatest(enablementStore.$enabledProviders, layoutStore.$metricLayouts, layoutStore.$providerOrder)
            .combineLatest(appearanceStore.$iconStyle)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.render() }
            .store(in: &cancellables)
    }

    @objc func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else if let button = statusItem.button {
            panel.show(relativeTo: button)
        }
    }

    /// Shows the dashboard panel programmatically, anchored to the status item button --
    /// the status item's own faint, ratio-less icon is easy to miss on a first launch before
    /// anything is configured, so `AppDelegate` calls this once to guide a brand-new install
    /// straight to "no providers enabled, open Settings" instead of leaving the user to notice
    /// the icon on their own.
    func showPanel() {
        guard let button = statusItem.button, !panel.isVisible else { return }
        panel.show(relativeTo: button)
    }

    /// Ratio to show for a provider's status-item percent/ring. Prefers a line explicitly
    /// identified as "session" (Claude's 5-hour window) over any other progress line -- plain
    /// max-of-all-lines let weekly (which only ever accumulates over days) dominate the display
    /// with an alarming-looking number when the actionable one is how much of the CURRENT
    /// session remains. Falls back to the highest ratio among whatever progress lines exist,
    /// which is just "the one line" for every provider except Claude.
    private func primaryRatio(in snapshot: ProviderSnapshot) -> Double? {
        if let sessionRatio = snapshot.lines.first(where: { $0.id == "session" })?.progressRatio {
            return sessionRatio
        }
        return snapshot.lines.compactMap(\.progressRatio).max()
    }

    /// Highest `primaryRatio` across every enabled provider wins the icon when there's no
    /// "latest active" provider to prefer instead.
    private func closestToLimitAcrossAll() -> (ratio: Double, tone: NSColor)? {
        var best: Double?
        for provider in enablementStore.enabledProviders {
            guard let snapshot = dataStore.snapshot(for: provider) else { continue }
            if let ratio = primaryRatio(in: snapshot), best == nil || ratio > best! {
                best = ratio
            }
        }
        guard let ratio = best else { return nil }
        return (ratio, toneForRatio(ratio))
    }

    private func toneForRatio(_ ratio: Double) -> NSColor {
        if ratio >= 0.9 { return .systemRed }
        if ratio >= 0.7 { return .systemOrange }
        return .systemGreen
    }

    /// The enabled provider with the most recent `lastActivityAt`, ignored once older than a
    /// day so a long-idle "last tool" doesn't dominate the icon forever.
    private func mostRecentlyActive() -> (provider: ProviderID, snapshot: ProviderSnapshot)? {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        var best: (ProviderID, ProviderSnapshot)?
        for provider in enablementStore.enabledProviders {
            guard let snapshot = dataStore.snapshot(for: provider),
                  let activity = snapshot.lastActivityAt,
                  activity > cutoff
            else { continue }
            if best == nil || activity > best!.1.lastActivityAt! {
                best = (provider, snapshot)
            }
        }
        return best
    }

    private func render() {
        guard let button = statusItem.button else { return }

        if appearanceStore.iconStyle == .bars {
            let fractions = barsFractions()
            if !fractions.isEmpty {
                button.attributedTitle = NSAttributedString(string: "")
                button.image = Self.barsImage(fractions: fractions)
                button.toolTip = pinnedSegments().map { "\($0.provider.displayName): \($0.text)" }.joined(separator: "\n")
                return
            }
        }

        let pins = pinnedSegments()
        if !pins.isEmpty {
            button.image = nil
            button.attributedTitle = Self.stripTitle(segments: pins)
            button.toolTip = pins.map { "\($0.provider.displayName): \($0.text)" }.joined(separator: "\n")
            return
        }

        if let (provider, snapshot) = mostRecentlyActive() {
            let ratio = primaryRatio(in: snapshot)
            let percentText = ratio.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
            button.attributedTitle = NSAttributedString(string: "")
            button.title = "\(shortName(provider))\(percentText)"
            button.toolTip = tooltip(for: provider, snapshot: snapshot)

            if let tone = snapshot.cacheTemperatureTone {
                let isWarm = tone == .neutral
                button.image = Self.ringImage(ratio: ratio ?? 0, tone: isWarm ? .systemGreen : .systemBlue, filled: true)
            } else if let ratio {
                button.image = Self.ringImage(ratio: ratio, tone: toneForRatio(ratio), filled: true)
            } else {
                button.image = Self.symbolImage(systemName: "circle.fill", tint: .secondaryLabelColor)
            }
            return
        }

        guard let (ratio, tone) = closestToLimitAcrossAll() else {
            button.image = Self.ringImage(ratio: 0, tone: .secondaryLabelColor, filled: false)
            button.attributedTitle = NSAttributedString(string: "")
            button.title = ""
            button.toolTip = nil
            return
        }
        button.attributedTitle = NSAttributedString(string: "")
        button.image = Self.ringImage(ratio: ratio, tone: tone, filled: true)
        button.title = " \(Int((ratio * 100).rounded()))%"
        button.toolTip = nil
    }

    private struct PinnedSegment {
        let provider: ProviderID
        let text: String
    }

    /// One segment per provider with at least one starred metric that currently has real data
    /// -- a provider whose stars all lack data drops out entirely rather than showing a "--"
    /// placeholder. Empty when nothing anywhere is starred, which is the common case until a
    /// user stars something from a row's context menu or Customize.
    private func pinnedSegments() -> [PinnedSegment] {
        var segments: [PinnedSegment] = []
        for provider in layoutStore.orderedProviders(enabled: enablementStore.enabledProviders) {
            guard let snapshot = dataStore.snapshot(for: provider) else { continue }
            let starredIDs = Set(layoutStore.starredMetricIDs(for: provider))
            guard !starredIDs.isEmpty else { continue }
            let parts = snapshot.lines
                .filter { starredIDs.contains($0.id) }
                .compactMap { pinText(for: $0) }
            guard !parts.isEmpty else { continue }
            segments.append(PinnedSegment(provider: provider, text: "\(shortName(provider)) \(parts.joined(separator: " "))"))
        }
        return segments
    }

    private func pinText(for line: MetricLine) -> String? {
        switch line {
        case let .progress(_, _, used, limit, format, _, _):
            guard limit > 0 else { return nil }
            switch format {
            case .percent: return "\(Int((used / limit * 100).rounded()))%"
            case .dollars: return String(format: "$%.0f", used)
            case .count(let suffix): return "\(Int(used.rounded()))\(suffix)"
            }
        case let .values(_, _, values):
            guard let first = values.first else { return nil }
            let numberText = first.number.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(first.number)) : String(format: "%.1f", first.number)
            return numberText
        case let .badge(_, text, _, _, _):
            return text
        default:
            return nil
        }
    }

    /// Up to four starred *bounded* metrics' fill fractions, across every enabled provider in
    /// layout order -- the data behind Bars icon style. A starred metric with no limit (a
    /// balance, a badge) simply doesn't appear here; it only ever shows in Text style.
    private func barsFractions() -> [Double] {
        var fractions: [Double] = []
        for provider in layoutStore.orderedProviders(enabled: enablementStore.enabledProviders) {
            guard let snapshot = dataStore.snapshot(for: provider) else { continue }
            let starredIDs = Set(layoutStore.starredMetricIDs(for: provider))
            guard !starredIDs.isEmpty else { continue }
            for line in snapshot.lines where starredIDs.contains(line.id) {
                if case let .progress(_, _, used, limit, _, _, _) = line, limit > 0 {
                    fractions.append(max(0, min(used / limit, 1)))
                }
            }
        }
        return Array(fractions.prefix(4))
    }

    /// Renders an 18x18 template image of up to four horizontal bars, each showing one
    /// metric's fill fraction -- a compact alternative to Text style for someone who'd rather
    /// glance at bar heights than read numbers. A simplified, not pixel-exact, port of the
    /// underlying idea (up to four bars, track + fill) rather than a copy of any specific
    /// implementation.
    private static func barsImage(fractions: [Double]) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let count = max(fractions.count, 1)
        let gap: CGFloat = 2
        let barHeight = (size.height - CGFloat(count - 1) * gap) / CGFloat(count)

        for (index, fraction) in fractions.enumerated() {
            let y = size.height - CGFloat(index + 1) * barHeight - CGFloat(index) * gap
            let trackRect = NSRect(x: 0, y: y, width: size.width, height: barHeight)
            let track = NSBezierPath(roundedRect: trackRect, xRadius: barHeight / 2, yRadius: barHeight / 2)
            NSColor.labelColor.withAlphaComponent(0.18).setFill()
            track.fill()

            let fillWidth = max(trackRect.width * CGFloat(fraction), fraction > 0 ? barHeight : 0)
            let fillRect = NSRect(x: 0, y: y, width: fillWidth, height: barHeight)
            let fill = NSBezierPath(roundedRect: fillRect, xRadius: barHeight / 2, yRadius: barHeight / 2)
            NSColor.labelColor.setFill()
            fill.fill()
        }

        image.isTemplate = true
        return image
    }

    /// Composes every pinned segment into one title string, separated by a thin divider --
    /// this status item stays a single `NSStatusItem`, not one per provider.
    private static func stripTitle(segments: [PinnedSegment]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuBarFont(ofSize: 0),
            .foregroundColor: NSColor.labelColor
        ]
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "  ·  ", attributes: [.font: NSFont.menuBarFont(ofSize: 0), .foregroundColor: NSColor.tertiaryLabelColor]))
            }
            result.append(NSAttributedString(string: segment.text, attributes: attrs))
        }
        return result
    }

    /// Spells out which local session the title/icon describe -- the percent is this provider's
    /// account-wide session ratio, but the cache icon color (when present) is scoped to one
    /// specific session, and a user running several at once has no other way to tell which.
    private func tooltip(for provider: ProviderID, snapshot: ProviderSnapshot) -> String? {
        guard let activityAt = snapshot.lastActivityAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: activityAt)
        if let label = snapshot.lastActivityLabel {
            return "\(provider.displayName) — \(label) · last active \(time)"
        }
        return "\(provider.displayName) · last active \(time)"
    }

    /// Short label for the menu bar title -- every provider's display name is already compact
    /// except GitHub Copilot's, which is shortened to fit.
    private func shortName(_ provider: ProviderID) -> String {
        provider == .copilot ? "Copilot" : provider.displayName
    }

    /// Renders a 12x12 ring/bar image colored by threshold.
    private static func ringImage(ratio: Double, tone: NSColor, filled: Bool) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let inset: CGFloat = 1.5
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)

        let track = NSBezierPath(ovalIn: rect)
        // A ratio-less icon (nothing enabled yet, or every enabled provider is still loading or
        // erroring) draws *only* this track -- it has to read as a clear, deliberate icon on its
        // own rather than fade into the menu bar, since there's no colored arc to carry the
        // visual weight the way there is once a ratio exists.
        NSColor.secondaryLabelColor.withAlphaComponent(filled ? 0.25 : 0.85).setStroke()
        track.lineWidth = 1.6
        track.stroke()

        if filled {
            let path = NSBezierPath()
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = rect.width / 2
            let startAngle: CGFloat = 90
            let endAngle = startAngle - CGFloat(ratio) * 360
            path.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
            tone.setStroke()
            path.lineWidth = 1.6
            path.lineCapStyle = .round
            path.stroke()
        }

        image.isTemplate = false
        return image
    }

    /// Renders an SF Symbol tinted with a fixed color -- currently only the "no ratio to show"
    /// placeholder dot. Falls back to a filled ring if the symbol name doesn't resolve.
    private static func symbolImage(systemName: String, tint: NSColor) -> NSImage {
        guard let base = NSImage(systemSymbolName: systemName, accessibilityDescription: nil) else {
            return ringImage(ratio: 1, tone: tint, filled: true)
        }
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium).applying(.init(paletteColors: [tint]))
        let tinted = base.withSymbolConfiguration(config) ?? base
        tinted.isTemplate = false
        return tinted
    }
}
