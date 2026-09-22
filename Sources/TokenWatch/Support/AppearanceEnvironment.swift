import SwiftUI
import TokenWatchCore

extension AppTheme {
    /// `nil` (system) for `.system`; `ColorScheme` is a SwiftUI type, so this mapping lives in
    /// the App layer rather than on the UI-framework-agnostic `AppTheme` itself.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

private struct AppDensityKey: EnvironmentKey {
    static let defaultValue: AppDensity = .regular
}

extension EnvironmentValues {
    /// The current row/section density -- read by `ProviderCardView`/`ProviderSectionView` to
    /// step padding and font sizes down one notch in `.compact`, instead of each view reaching
    /// for a store directly.
    var appDensity: AppDensity {
        get { self[AppDensityKey.self] }
        set { self[AppDensityKey.self] = newValue }
    }
}

/// Density-driven spacing/sizing constants, kept in one place so `.compact` behaves consistently
/// everywhere it's read rather than each call site picking its own numbers.
enum Density {
    static func rowSpacing(_ density: AppDensity) -> CGFloat { density == .compact ? 2 : 3 }
    static func sectionSpacing(_ density: AppDensity) -> CGFloat { density == .compact ? 5 : 8 }
    static func cardPadding(_ density: AppDensity) -> CGFloat { density == .compact ? 8 : 12 }
    static func labelFont(_ density: AppDensity) -> Font { density == .compact ? .caption : .subheadline }
    static func valueFont(_ density: AppDensity) -> Font { density == .compact ? .caption2 : .caption }
}
