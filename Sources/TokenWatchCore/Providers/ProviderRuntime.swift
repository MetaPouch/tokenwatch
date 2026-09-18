import Foundation

/// One provider's pipeline: auth check -> network fetch -> mapping -> normalized snapshot.
/// Every implementation must be exception-safe: wrap network/parse work in do/catch and
/// return `.error(...)` on failure. NEVER force-unwrap response JSON.
public protocol ProviderRuntime: Sendable {
    static var id: ProviderID { get }
    static var displayName: String { get }

    /// Cheap, synchronous-ish check for whether local credentials/config exist at all
    /// (does not guarantee they are still valid -- that's what `refresh()` finds out).
    func hasLocalCredentials() async -> Bool

    /// Fetch and map current usage. Must never throw; failures become `.error(...)` snapshots.
    func refresh() async -> ProviderSnapshot
}

/// Status of an API key backing an `APIKeyManaging` provider.
public enum APIKeyStatus: Sendable, Equatable {
    case notSet
    case fromEnvironment
    case saved
}

/// Conformed to by providers authenticated with a plain bearer/API key rather than OAuth or
/// a subprocess. Backed by `KeychainStore` with an environment-variable fallback.
public protocol APIKeyManaging: AnyObject, Sendable {
    func keyStatus() -> APIKeyStatus
    func currentAPIKey() -> String?
    func saveAPIKey(_ key: String) throws
    func deleteAPIKey() throws
}
