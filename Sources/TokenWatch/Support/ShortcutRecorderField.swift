import SwiftUI

/// A click-to-record field for the global shortcut: click it, press a key combo, it captures the
/// next `.keyDown` via a *local* event monitor (only fires while this app is key -- no Input
/// Monitoring permission needed, unlike a global monitor). The ⓧ clears it and disables the
/// shortcut, matching `settings.md`'s spec for this control.
struct ShortcutRecorderField: View {
    @Binding var combo: KeyCombo?
    var onChange: (KeyCombo?) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleRecording) {
                Text(isRecording ? "Press a shortcut…" : (combo?.displayString ?? "Click to record"))
                    .frame(minWidth: 110)
                    .foregroundStyle(isRecording ? .secondary : .primary)
            }
            .buttonStyle(.bordered)
            if combo != nil {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape cancels without changing the combo
                stopRecording()
                return nil
            }
            // A bare key with no modifier isn't a usable global shortcut (it would fire on
            // every keystroke) -- require at least one before accepting the capture.
            if let captured = KeyCombo(event: event), captured.carbonModifiers != 0 {
                combo = captured
                onChange(captured)
                stopRecording()
                return nil
            }
            return event
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func clear() {
        combo = nil
        onChange(nil)
    }
}
