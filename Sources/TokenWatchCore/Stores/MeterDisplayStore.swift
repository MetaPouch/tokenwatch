import Foundation
import Combine

/// Whether a bounded metric's headline reads "48% used" or "52% left".
public enum MeterReadingMode: String, Sendable, Codable {
    case used
    case left
}

/// Whether a reset timestamp reads as a countdown ("Resets in 3h 25m") or an exact clock time
/// ("Resets today at 6:38 PM").
public enum ResetDisplayMode: String, Sendable, Codable {
    case countdown
    case exact
}

private struct DisplayFile: Codable {
    var reading: MeterReadingMode
    var reset: ResetDisplayMode
    var alwaysShowPacing: Bool
}

/// App-wide, click-to-flip display preferences. Flipping one row's headline or reset label
/// flips every row -- a single mental model ("this app currently shows Used") instead of
/// per-row state nobody would remember they set.
@MainActor
public final class MeterDisplayStore: ObservableObject {
    @Published public var readingMode: MeterReadingMode {
        didSet { persist() }
    }
    @Published public var resetDisplayMode: ResetDisplayMode {
        didSet { persist() }
    }
    /// Off (default): pacing notes/ticks show only once a metric is close to or projected past
    /// its limit. On: every metric with a reset window shows its projection, even when it's
    /// comfortably ahead of pace.
    @Published public var alwaysShowPacing: Bool {
        didSet { persist() }
    }

    private let fileURL: URL
    private var isLoading = false

    public init(directory: URL? = nil) {
        let base = directory ?? ConfigStore.defaultDirectory()
        self.fileURL = base.appendingPathComponent("display.json")
        if let data = try? Data(contentsOf: fileURL), let file = try? JSONDecoder().decode(DisplayFile.self, from: data) {
            self.readingMode = file.reading
            self.resetDisplayMode = file.reset
            self.alwaysShowPacing = file.alwaysShowPacing
        } else {
            self.readingMode = .used
            self.resetDisplayMode = .countdown
            self.alwaysShowPacing = false
        }
    }

    public func toggleReadingMode() {
        readingMode = readingMode == .used ? .left : .used
    }

    public func toggleResetDisplayMode() {
        resetDisplayMode = resetDisplayMode == .countdown ? .exact : .countdown
    }

    private func persist() {
        let file = DisplayFile(reading: readingMode, reset: resetDisplayMode, alwaysShowPacing: alwaysShowPacing)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
