import AppKit
import SwiftUI
import Combine
import TokenWatchCore

/// Owns the `NSStatusItem`. On every store update, renders whichever enabled provider's metric
/// is closest to its limit (highest used/limit ratio wins) as status-item text plus a small
/// colored ring -- the MeterBar-style "always show what's about to run out" behavior.
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

    /// Highest used/limit ratio across every enabled provider's `.progress` lines wins the icon.
    private func closestToLimit() -> (ratio: Double, tone: NSColor)? {
        var best: Double?
        for provider in enablementStore.enabledProviders {
            guard let snapshot = dataStore.snapshot(for: provider) else { continue }
            for line in snapshot.lines {
                guard let ratio = line.progressRatio else { continue }
                if best == nil || ratio > best! {
                    best = ratio
                }
            }
        }
        guard let ratio = best else { return nil }
        let tone: NSColor
        if ratio >= 0.9 {
            tone = .systemRed
        } else if ratio >= 0.7 {
            tone = .systemOrange
        } else {
            tone = .systemGreen
        }
        return (ratio, tone)
    }

    private func render() {
        guard let button = statusItem.button else { return }
        guard let (ratio, tone) = closestToLimit() else {
            button.image = Self.ringImage(ratio: 0, tone: .secondaryLabelColor, filled: false)
            button.title = ""
            return
        }
        button.image = Self.ringImage(ratio: ratio, tone: tone, filled: true)
        button.title = " \(Int((ratio * 100).rounded()))%"
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
}
