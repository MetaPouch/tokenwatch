import AppKit
import SwiftUI
import Combine
import TokenWatchCore

/// Owns the `NSStatusItem`. Primary display: whichever enabled provider has the most recent
/// local activity signal (currently only Claude provides one) gets its name, its own
/// closest-to-limit percent, and a warm/cold cache icon when cache-temperature data is
/// available. Falls back to the MeterBar-style "closest to limit across every enabled
/// provider" ring when no provider has a recent-activity signal.
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let panel: TokenWatchPanel
    private let dataStore: WidgetDataStore
    private let enablementStore: ProviderEnablementStore
    private var cancellables: Set<AnyCancellable> = []

    init(container: AppContainer) {
        self.dataStore = container.dataStore
        self.enablementStore = container.enablementStore
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.panel = TokenWatchPanel(content: DashboardView(dataStore: container.dataStore, enablementStore: container.enablementStore, refreshScheduler: container.refreshScheduler, apiKeyManagers: container.apiKeyManagers))

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.imagePosition = .imageLeading
        }

        render()

        dataStore.$snapshots
            .combineLatest(enablementStore.$enabledProviders)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.render() }
            .store(in: &cancellables)
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else if let button = statusItem.button {
            panel.show(relativeTo: button)
        }
    }

    /// Highest used/limit ratio among a snapshot's own `.progress` lines.
    private func closestToLimit(in snapshot: ProviderSnapshot) -> Double? {
        snapshot.lines.compactMap(\.progressRatio).max()
    }

    /// Highest used/limit ratio across every enabled provider's `.progress` lines wins the icon
    /// when there's no "latest active" provider to prefer instead.
    private func closestToLimitAcrossAll() -> (ratio: Double, tone: NSColor)? {
        var best: Double?
        for provider in enablementStore.enabledProviders {
            guard let snapshot = dataStore.snapshot(for: provider) else { continue }
            if let ratio = closestToLimit(in: snapshot), best == nil || ratio > best! {
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

        if let (provider, snapshot) = mostRecentlyActive() {
            let ratio = closestToLimit(in: snapshot)
            let percentText = ratio.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
            button.title = "\(shortName(provider))\(percentText)"

            if let tone = snapshot.cacheTemperatureTone {
                let isWarm = tone == .neutral
                button.image = Self.symbolImage(systemName: isWarm ? "flame.fill" : "snowflake", tint: isWarm ? .systemGreen : .systemBlue)
            } else if let ratio {
                button.image = Self.ringImage(ratio: ratio, tone: toneForRatio(ratio), filled: true)
            } else {
                button.image = Self.symbolImage(systemName: "circle.fill", tint: .secondaryLabelColor)
            }
            return
        }

        guard let (ratio, tone) = closestToLimitAcrossAll() else {
            button.image = Self.ringImage(ratio: 0, tone: .secondaryLabelColor, filled: false)
            button.title = ""
            return
        }
        button.image = Self.ringImage(ratio: ratio, tone: tone, filled: true)
        button.title = " \(Int((ratio * 100).rounded()))%"
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
        NSColor.secondaryLabelColor.withAlphaComponent(0.25).setStroke()
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

    /// Renders an SF Symbol tinted with a fixed color, for the cache-temperature flame/snowflake
    /// glyphs. Falls back to a filled ring if the symbol name doesn't resolve.
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
