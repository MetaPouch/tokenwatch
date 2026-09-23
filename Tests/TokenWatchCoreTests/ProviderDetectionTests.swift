import XCTest
@testable import TokenWatchCore

final class ProviderDetectionTests: XCTestCase {
    /// The onboarding probe must see an item that exists and not one that doesn't -- checked
    /// against a real Keychain item under a throwaway service name.
    func testKeychainPresenceSeesExistenceWithoutReadingValue() throws {
        let store = KeychainStore(service: "dev.tokenwatch.tests.\(UUID().uuidString)")
        defer { _ = try? store.delete(account: "probe") }
        XCTAssertFalse(store.contains(account: "probe"))
        try store.set(account: "probe", value: "secret")
        XCTAssertTrue(store.contains(account: "probe"))
        try store.delete(account: "probe")
        XCTAssertFalse(store.contains(account: "probe"))
    }

    /// A Gemini CLI set up for an API key or Vertex AI still has an oauth_creds.json lying around,
    /// but TokenWatch can't use that setup -- onboarding must not offer it.
    func testGeminiAPIKeySetupIsNotAUsableSignIn() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let gemini = home.appendingPathComponent(".gemini")
        try FileManager.default.createDirectory(at: gemini, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"access_token":"x"}"#.utf8).write(to: gemini.appendingPathComponent("oauth_creds.json"))
        let store = GeminiAuthStore(homeDirectory: home.path)
        XCTAssertTrue(store.hasUsableSignIn())

        try Data(#"{"security":{"auth":{"selectedType":"gemini-api-key"}}}"#.utf8).write(to: gemini.appendingPathComponent("settings.json"))
        XCTAssertFalse(store.hasUsableSignIn())
    }
}

/// Counts refreshes so a test can see which providers were fetched.
private final class CountingRuntime: ProviderRuntime, @unchecked Sendable {
    static let id: ProviderID = .grok
    static let displayName = "Grok"
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }

    func detect() -> ProviderDetection? { nil }
    func refresh() async -> ProviderSnapshot {
        lock.withLock { _count += 1 }
        return ProviderSnapshot(provider: Self.id)
    }
}

@MainActor
final class RefreshSchedulerEnableTests: XCTestCase {
    /// Turning a provider on (e.g. onboarding's "Track") fetches it right away, rather than
    /// leaving an empty card until the next scheduled cycle minutes later.
    func testNewlyEnabledProviderIsFetchedImmediately() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = CountingRuntime()
        let dataStore = WidgetDataStore(runtimes: [runtime], cacheDirectory: directory)
        let enablement = ProviderEnablementStore(configStore: ConfigStore(directory: directory))
        let scheduler = RefreshScheduler(dataStore: dataStore, enablementStore: enablement)
        scheduler.start()
        defer { scheduler.stop() }

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(runtime.count, 0, "nothing enabled yet")

        enablement.enable([.grok])
        for _ in 0..<50 where runtime.count == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(runtime.count, 1)
    }
}
