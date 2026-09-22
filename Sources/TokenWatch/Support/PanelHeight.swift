import SwiftUI

/// Which of the popover's pager screens is currently showing. All three are mounted
/// simultaneously (side by side in the sliding `HStack`) so the slide has something to animate
/// between -- only the panel host resizes to match whichever one is actually in view.
enum DashboardScreen: Int, CaseIterable {
    case dashboard = 0
    case customize = 1
    case settings = 2
}

/// Reports each pager screen's natural (unclipped) content height, tagged by screen, up to the
/// pager host -- which reads out only the *currently visible* screen's height to resize the
/// actual AppKit panel. A plain "keep the latest value" key wouldn't work here: because all
/// three screens are mounted at once, they all publish on every layout pass in an unspecified
/// order, so the host needs to know *which* screen each height belongs to, not just the most
/// recent one.
struct PanelHeightPreferenceKey: PreferenceKey {
    static let defaultValue: [DashboardScreen: CGFloat] = [:]
    static func reduce(value: inout [DashboardScreen: CGFloat], nextValue: () -> [DashboardScreen: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Measures this screen's natural height via an invisible `GeometryReader` background and
    /// publishes it, tagged as `screen`, through `PanelHeightPreferenceKey`.
    func reportPanelHeight(for screen: DashboardScreen) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: PanelHeightPreferenceKey.self, value: [screen: proxy.size.height])
            }
        )
    }
}

/// A `ScrollView` that sizes itself to its content's natural height, capped at `maxHeight` --
/// scrolls internally only once content exceeds the cap, instead of always reserving a fixed
/// height with an ever-present scrollbar even for two rows of content.
///
/// Measuring a `ScrollView`'s natural content height in SwiftUI is notoriously unreliable via
/// the usual `GeometryReader` + `PreferenceKey` combination once the `ScrollView`'s own frame is
/// itself state-driven (the very case here): the preference change callback consistently
/// reports the placeholder default instead of the true measured size, confirmed by direct
/// instrumentation. `.onAppear` on the same `GeometryReader`, by contrast, reliably reports the
/// real geometry -- so that is what this measures with, at the cost of only capturing height at
/// first appearance rather than on every subsequent content change. `refreshID` lets a caller
/// force a fresh measurement (e.g. after the enabled-provider set changes) by giving the hidden
/// measurement copy a new identity, which re-triggers `.onAppear`.
struct MeasuredScrollView<Content: View>: View {
    let maxHeight: CGFloat
    var refreshID: AnyHashable = 0
    @ViewBuilder let content: () -> Content

    @State private var contentHeight: CGFloat = 200

    var body: some View {
        ScrollView {
            content()
        }
        .frame(height: min(contentHeight, maxHeight))
        .background(
            content()
                .fixedSize(horizontal: false, vertical: true)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .focusable(false)
                .background(
                    GeometryReader { proxy in
                        Color.clear.onAppear { contentHeight = proxy.size.height }
                    }
                )
                .id(refreshID),
            alignment: .top
        )
    }
}
