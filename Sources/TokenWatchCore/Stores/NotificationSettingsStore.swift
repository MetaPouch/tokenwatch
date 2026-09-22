import Foundation
import Combine

private struct NotificationSettingsFile: Codable {
    var almostOut: Bool
    var cuttingItClose: Bool
    var willRunOut: Bool
}

/// Persists the three pace-crossing notification toggles (all off by default) to their own
/// `notifications.json`, independent of the other stores.
@MainActor
public final class NotificationSettingsStore: ObservableObject {
    @Published public var almostOut: Bool { didSet { persist() } }
    @Published public var cuttingItClose: Bool { didSet { persist() } }
    @Published public var willRunOut: Bool { didSet { persist() } }

    private let fileURL: URL

    public init(directory: URL? = nil) {
        let base = directory ?? ConfigStore.defaultDirectory()
        self.fileURL = base.appendingPathComponent("notifications.json")
        if let data = try? Data(contentsOf: fileURL), let file = try? JSONDecoder().decode(NotificationSettingsFile.self, from: data) {
            self.almostOut = file.almostOut
            self.cuttingItClose = file.cuttingItClose
            self.willRunOut = file.willRunOut
        } else {
            self.almostOut = false
            self.cuttingItClose = false
            self.willRunOut = false
        }
    }

    public var settings: QuotaAlertSettings {
        QuotaAlertSettings(almostOut: almostOut, cuttingItClose: cuttingItClose, willRunOut: willRunOut)
    }

    public var anyEnabled: Bool { almostOut || cuttingItClose || willRunOut }

    private func persist() {
        let file = NotificationSettingsFile(almostOut: almostOut, cuttingItClose: cuttingItClose, willRunOut: willRunOut)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
