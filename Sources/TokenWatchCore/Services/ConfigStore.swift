import Foundation

/// Persisted app configuration: `~/Library/Application Support/TokenWatch/config.json`.
/// Missing file -> every provider disabled, `refreshIntervalSeconds: 300`.
public struct AppConfig: Sendable, Equatable, Codable {
    public var enabledProviders: Set<ProviderID>
    public var refreshIntervalSeconds: Int
    public var providers: [String: [String: JSONValue]]

    public init(enabledProviders: Set<ProviderID> = [], refreshIntervalSeconds: Int = 300, providers: [String: [String: JSONValue]] = [:]) {
        self.enabledProviders = enabledProviders
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.providers = providers
    }

    public func setting(_ provider: ProviderID, _ key: String) -> JSONValue? {
        providers[provider.rawValue]?[key]
    }
}

/// Reads/writes `AppConfig` to disk. Not actor-isolated; callers serialize access themselves
/// (in practice, only `ProviderEnablementStore`/`RefreshScheduler` on the main actor touch it).
public final class ConfigStore: @unchecked Sendable {
    public static let shared = ConfigStore()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "dev.tokenwatch.configstore")

    public init(directory: URL? = nil) {
        let base = directory ?? Self.defaultDirectory()
        self.fileURL = base.appendingPathComponent("config.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    public static func defaultDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return appSupport.appendingPathComponent("TokenWatch", isDirectory: true)
    }

    public func load() -> AppConfig {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL) else { return AppConfig() }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let config = try? decoder.decode(AppConfig.self, from: data) else { return AppConfig() }
            return config
        }
    }

    public func save(_ config: AppConfig) {
        queue.sync {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(config) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    public func mutate(_ transform: (inout AppConfig) -> Void) {
        var config = load()
        transform(&config)
        save(config)
    }
}
