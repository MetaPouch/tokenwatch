import Foundation
import Combine

/// Which providers look set up on this Mac (`ProviderRuntime.detect()`), for onboarding's
/// "found on this Mac" list and Settings' per-provider hints. Every check is silent -- no network,
/// no Keychain prompt -- so scanning is safe to run any time the list is about to be shown.
@MainActor
public final class ProviderDetectionStore: ObservableObject {
    @Published public private(set) var detections: [ProviderID: ProviderDetection] = [:]
    /// False until the first scan finishes, so a view can tell "nothing found" from "not looked yet".
    @Published public private(set) var hasScanned = false

    private let runtimes: [any ProviderRuntime]
    private var scanTask: Task<Void, Never>?

    public init(runtimes: [any ProviderRuntime]) {
        self.runtimes = runtimes
    }

    /// Detected providers, in `ProviderID` order.
    public var detectedProviders: [ProviderID] {
        ProviderID.allCases.filter { detections[$0] != nil }
    }

    public func scan() {
        guard scanTask == nil else { return }
        let runtimes = runtimes
        scanTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Self.detect(runtimes) }.value
            guard let self else { return }
            detections = result
            hasScanned = true
            scanTask = nil
        }
    }

    nonisolated static func detect(_ runtimes: [any ProviderRuntime]) -> [ProviderID: ProviderDetection] {
        var result: [ProviderID: ProviderDetection] = [:]
        for runtime in runtimes {
            if let detection = runtime.detect() {
                result[type(of: runtime).id] = detection
            }
        }
        return result
    }
}
