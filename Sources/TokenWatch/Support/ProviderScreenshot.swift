import SwiftUI
import AppKit
import TokenWatchCore

/// Renders one provider's card -- header plus every currently visible metric row -- to a PNG
/// and copies it to the clipboard. Follows the current appearance (light/dark) since it's
/// rendered with the same view code, not a raw screen grab. Shared between a card's own
/// right-click "Share Screenshot" and the footer Options menu's per-provider submenu, so both
/// produce an identical image.
enum ProviderScreenshot {
    @MainActor
    static func share(provider: ProviderID, snapshot: ProviderSnapshot, displayStore: MeterDisplayStore, density: AppDensity, timeFormat: TimeFormatPreference) {
        let content = VStack(alignment: .leading, spacing: Density.sectionSpacing(density)) {
            HStack(spacing: 6) {
                ProviderIcon(provider: provider, size: 16)
                Text(provider.displayName).font(.subheadline.weight(.semibold))
                if let plan = snapshot.plan, !plan.isEmpty {
                    Text(plan).font(.caption).foregroundStyle(.secondary)
                }
            }
            ProviderCardView(snapshot: snapshot, displayStore: displayStore, timeFormat: timeFormat)
        }
        .padding(Density.cardPadding(density))
        .frame(width: TokenWatchPanel.width, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
}
