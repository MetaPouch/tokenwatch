import Foundation
import Combine

/// App-wide appearance override for the popover. `.system` (default) follows macOS; `.light`/
/// `.dark` force one regardless of the system setting.
public enum AppTheme: String, Sendable, Codable, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    public var id: String { rawValue }
}

/// How tightly the popover's rows and sections pack. `.compact` steps text down one size and
/// pulls padding together; `.regular` is the normal spacing.
public enum AppDensity: String, Sendable, Codable, CaseIterable, Identifiable {
    case regular = "Default"
    case compact = "Compact"

    public var id: String { rawValue }
}

/// How an exact reset time reads. `.auto` (default) follows the system 12/24-hour setting.
public enum TimeFormatPreference: String, Sendable, Codable, CaseIterable, Identifiable {
    case auto = "Auto"
    case twelveHour = "12-hour"
    case twentyFourHour = "24-hour"

    public var id: String { rawValue }
}

/// How starred metrics render in the menu bar strip. `.text` shows each provider's icon plus
/// its value(s); `.bars` renders a compact glyph of up to four bounded metrics' fill fractions
/// (metrics without a limit only ever appear in `.text`).
public enum MenuBarIconStyle: String, Sendable, Codable, CaseIterable, Identifiable {
    case text = "Text"
    case bars = "Bars"

    public var id: String { rawValue }
}

/// Independent menu-bar values, ordered as they appear in Settings and the token strip.
public enum MenuBarValue: String, Sendable, Codable, CaseIterable, Identifiable {
    case limits
    case inputTokens
    case outputTokens
    case cacheTokens

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .limits: return "Session limit / pinned metrics"
        case .inputTokens: return "Input tokens"
        case .outputTokens: return "Output tokens"
        case .cacheTokens: return "Cache tokens"
        }
    }

    public var help: String {
        switch self {
        case .limits: return "Show the usual session-limit summary or your starred metrics, including the Bars style. Turn off for token counts only."
        case .inputTokens: return "Today's input tokens excluding cache, across enabled providers with usage history."
        case .outputTokens: return "Today's output tokens across enabled providers with usage history."
        case .cacheTokens: return "Today's cache reads plus writes. Hover the menu bar for the exact breakdown."
        }
    }
}

/// `iconStyle` was added after `appearance.json` already shipped -- a custom decode so an
/// existing file missing that key defaults it to `.text` instead of failing the whole decode.
private struct AppearanceFile: Codable {
    var theme: AppTheme
    var density: AppDensity
    var timeFormat: TimeFormatPreference
    var reduceAnimations: Bool
    var increaseTransparency: Bool
    var iconStyle: MenuBarIconStyle
    var hideFromScreenShare: Bool
    var menuBarValues: Set<MenuBarValue>

    private enum CodingKeys: String, CodingKey {
        case theme, density, timeFormat, reduceAnimations, increaseTransparency, iconStyle, hideFromScreenShare, menuBarValues
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case showMenuBarTokenCounts
    }

    init(theme: AppTheme, density: AppDensity, timeFormat: TimeFormatPreference, reduceAnimations: Bool, increaseTransparency: Bool, iconStyle: MenuBarIconStyle, hideFromScreenShare: Bool, menuBarValues: Set<MenuBarValue>) {
        self.theme = theme
        self.density = density
        self.timeFormat = timeFormat
        self.reduceAnimations = reduceAnimations
        self.increaseTransparency = increaseTransparency
        self.iconStyle = iconStyle
        self.hideFromScreenShare = hideFromScreenShare
        self.menuBarValues = menuBarValues
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        theme = try container.decode(AppTheme.self, forKey: .theme)
        density = try container.decode(AppDensity.self, forKey: .density)
        timeFormat = try container.decode(TimeFormatPreference.self, forKey: .timeFormat)
        reduceAnimations = try container.decode(Bool.self, forKey: .reduceAnimations)
        increaseTransparency = try container.decode(Bool.self, forKey: .increaseTransparency)
        iconStyle = try container.decodeIfPresent(MenuBarIconStyle.self, forKey: .iconStyle) ?? .text
        hideFromScreenShare = try container.decodeIfPresent(Bool.self, forKey: .hideFromScreenShare) ?? false
        if let values = try container.decodeIfPresent([String].self, forKey: .menuBarValues) {
            menuBarValues = Set(values.compactMap(MenuBarValue.init(rawValue:)))
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            let showTokens = try legacy.decodeIfPresent(Bool.self, forKey: .showMenuBarTokenCounts) ?? true
            menuBarValues = showTokens ? Set(MenuBarValue.allCases) : [.limits]
        }
    }
}

/// Persists the popover's Appearance settings (Theme, Density, Time Format, Reduce Animations,
/// Increase Transparency, menu-bar Icon Style and selected values, Hide From Screen Share) to their own
/// `appearance.json`, independent of the other stores so a decode failure here can't take any of
/// them down.
@MainActor
public final class AppearanceStore: ObservableObject {
    @Published public var theme: AppTheme { didSet { persist() } }
    @Published public var density: AppDensity { didSet { persist() } }
    @Published public var timeFormat: TimeFormatPreference { didSet { persist() } }
    @Published public var reduceAnimations: Bool { didSet { persist() } }
    @Published public var increaseTransparency: Bool { didSet { persist() } }
    @Published public var iconStyle: MenuBarIconStyle { didSet { persist() } }
    /// Excludes the popover window from screen recordings and screen sharing
    /// (`NSWindow.sharingType = .none`) -- useful when presenting/streaming with usage figures
    /// visible in the menu bar dropdown that shouldn't be broadcast.
    @Published public var hideFromScreenShare: Bool { didSet { persist() } }
    @Published public var menuBarValues: Set<MenuBarValue> { didSet { persist() } }

    private let fileURL: URL

    public init(directory: URL? = nil) {
        let base = directory ?? ConfigStore.defaultDirectory()
        self.fileURL = base.appendingPathComponent("appearance.json")
        if let data = try? Data(contentsOf: fileURL), let file = try? JSONDecoder().decode(AppearanceFile.self, from: data) {
            self.theme = file.theme
            self.density = file.density
            self.timeFormat = file.timeFormat
            self.reduceAnimations = file.reduceAnimations
            self.increaseTransparency = file.increaseTransparency
            self.iconStyle = file.iconStyle
            self.hideFromScreenShare = file.hideFromScreenShare
            self.menuBarValues = file.menuBarValues
        } else {
            self.theme = .system
            self.density = .regular
            self.timeFormat = .auto
            self.reduceAnimations = false
            self.increaseTransparency = false
            self.iconStyle = .text
            self.hideFromScreenShare = false
            self.menuBarValues = Set(MenuBarValue.allCases)
        }
    }

    private func persist() {
        let file = AppearanceFile(theme: theme, density: density, timeFormat: timeFormat, reduceAnimations: reduceAnimations, increaseTransparency: increaseTransparency, iconStyle: iconStyle, hideFromScreenShare: hideFromScreenShare, menuBarValues: menuBarValues)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
