import Foundation

/// One provider's pipeline: auth check -> network fetch -> mapping -> normalized snapshot.
/// Every implementation must be exception-safe: wrap network/parse work in do/catch and
/// return `.error(...)` on failure. NEVER force-unwrap response JSON.
public protocol ProviderRuntime: Sendable {
    static var id: ProviderID { get }
    static var displayName: String { get }

    /// Whether this provider looks set up on this Mac -- the basis for onboarding's "found on
    /// this Mac" list. Must be cheap and silent: file/directory existence, a PATH lookup, or a
    /// Keychain *existence* probe (`KeychainPresence`), never a Keychain secret read (which can
    /// raise macOS's access prompt), a network call, a subprocess, or a write. Doesn't guarantee
    /// the credential still works -- that's what `refresh()` finds out.
    func detect() -> ProviderDetection?

    /// Fetch and map current usage. Must never throw; failures become `.error(...)` snapshots.
    func refresh() async -> ProviderSnapshot
}

/// Evidence that a provider is set up on this Mac, found by `ProviderRuntime.detect()`.
public struct ProviderDetection: Sendable, Equatable {
    /// Where it was found, phrased for a person: "Signed in with Claude Code", "OPENAI_API_KEY is set".
    public let source: String
    /// Tracking it reads another app's Keychain item, so macOS may ask to allow that the first time.
    public let needsKeychainApproval: Bool

    public init(source: String, needsKeychainApproval: Bool = false) {
        self.source = source
        self.needsKeychainApproval = needsKeychainApproval
    }
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
