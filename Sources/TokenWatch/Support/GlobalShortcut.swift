import AppKit
import Carbon.HIToolbox

/// One recorded key combination -- Carbon key code plus Carbon modifier flags (not
/// `NSEvent.ModifierFlags`, since `RegisterEventHotKey` takes the Carbon set).
struct KeyCombo: Codable, Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32

    var displayString: String {
        var parts: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if carbonModifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if carbonModifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(KeyCombo.keyName(for: keyCode))
        return parts.joined()
    }

    /// Builds a combo from a live `NSEvent`, translating Cocoa's modifier flags to Carbon's --
    /// used by the Settings recorder field, which captures the next key press while focused.
    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        self.keyCode = UInt32(event.keyCode)
        var carbon: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        self.carbonModifiers = carbon
    }

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// Common key names for the recorder's display string. Falls back to a `?` placeholder for
    /// keys outside this table rather than guessing -- a shortcut still works either way, this
    /// is display-only.
    private static let keyNames: [UInt32: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z", 0x07: "X",
        0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y",
        0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x19: "9",
        0x1A: "7", 0x1C: "8", 0x1D: "0", 0x1F: "O", 0x20: "U", 0x22: "I", 0x23: "P", 0x25: "L",
        0x26: "J", 0x28: "K", 0x2D: "N", 0x2E: "M", 0x31: "Space", 0x24: "Return", 0x30: "Tab",
        0x33: "Delete", 0x35: "Escape", 0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4",
        0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
    ]

    private static func keyName(for keyCode: UInt32) -> String {
        keyNames[keyCode] ?? "Key \(keyCode)"
    }

    private static let defaultsKey = "dev.tokenwatch.globalShortcut"

    /// Persisted directly via `UserDefaults` -- this is a small, non-critical piece of platform-
    /// specific UI state (not app data worth its own store/file), matching the precedent set by
    /// `ProviderSectionView`'s `sectionExpanded.*` flags.
    static func loadPersisted() -> KeyCombo? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }

    static func persist(_ combo: KeyCombo?) {
        guard let combo, let data = try? JSONEncoder().encode(combo) else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return
        }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

/// Registers a single global hotkey (via the Carbon Event Manager -- still the standard,
/// permission-free way to do this on macOS; `NSEvent.addGlobalMonitorForEvents` needs Input
/// Monitoring permission and is unreliable without it). One instance for the whole app: the
/// hotkey toggles the dashboard popover, there's only ever one action to route to.
@MainActor
final class GlobalHotKeyManager {
    static let shared = GlobalHotKeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var action: (() -> Void)?

    func register(combo: KeyCombo, action: @escaping () -> Void) {
        unregister()
        self.action = action

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, eventRef, userData in
            guard let userData, let eventRef else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(eventRef, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard hotKeyID.signature == GlobalHotKeyManager.signature else { return noErr }
            let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            manager.action?()
            return noErr
        }, 1, &eventSpec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        action = nil
    }

    /// Four-char-code signature identifying TokenWatch's hotkey registrations among any other
    /// app's -- 'TKWD' packed into an `OSType`.
    private static let signature: OSType = {
        let bytes: [UInt8] = Array("TKWD".utf8)
        return bytes.reduce(OSType(0)) { ($0 << 8) | OSType($1) }
    }()
}
