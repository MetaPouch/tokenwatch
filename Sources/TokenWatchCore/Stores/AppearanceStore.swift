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

private struct AppearanceFile: Codable {
    var theme: AppTheme
    var density: AppDensity
    var timeFormat: TimeFormatPreference
    var reduceAnimations: Bool
    var increaseTransparency: Bool
}

/// Persists the popover's Appearance settings (Theme, Density, Time Format, Reduce Animations,
/// Increase Transparency) to their own `appearance.json`, independent of the other stores so a
/// decode failure here can't take any of them down.
@MainActor
public final class AppearanceStore: ObservableObject {
    @Published public var theme: AppTheme { didSet { persist() } }
    @Published public var density: AppDensity { didSet { persist() } }
    @Published public var timeFormat: TimeFormatPreference { didSet { persist() } }
    @Published public var reduceAnimations: Bool { didSet { persist() } }
    @Published public var increaseTransparency: Bool { didSet { persist() } }

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
        } else {
            self.theme = .system
            self.density = .regular
            self.timeFormat = .auto
            self.reduceAnimations = false
            self.increaseTransparency = false
        }
    }

    private func persist() {
        let file = AppearanceFile(theme: theme, density: density, timeFormat: timeFormat, reduceAnimations: reduceAnimations, increaseTransparency: increaseTransparency)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
