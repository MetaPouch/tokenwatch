import Foundation

/// z.ai API key: Keychain (`zai.apiKey`) or `Z_AI_API_KEY` env fallback.
public func makeZaiAuthStore() -> APIKeyAuthStore {
    APIKeyAuthStore(provider: .zai, envVars: ["Z_AI_API_KEY"])
}

/// API region: `global` (api.z.ai, default) or `bigmodel-cn` (open.bigmodel.cn).
public enum ZaiRegion: String {
    case global
    case bigmodelCN = "bigmodel-cn"

    var host: String {
        switch self {
        case .global: return "https://api.z.ai"
        case .bigmodelCN: return "https://open.bigmodel.cn"
        }
    }

    /// Reads the configured region from `config.json`, defaulting to `global`.
    public static func configured(configStore: ConfigStore = .shared) -> ZaiRegion {
        guard let raw = configStore.load().setting(.zai, "region")?.stringValue else { return .global }
        return ZaiRegion(rawValue: raw) ?? .global
    }
}
