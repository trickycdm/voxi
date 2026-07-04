import AppKit
import SwiftUI

/// Owns the local NSEvent monitor while a chord is being recorded and feeds
/// events through the pure `ChordCaptureState`. Local monitors need no
/// permission; keyboard events are swallowed while recording, mouse clicks
/// cancel and pass through (click-away).
@MainActor
@Observable
final class ChordRecorderModel {
    private(set) var isRecording = false
    private(set) var heldPreview = ChordBinding()

    private var monitor: Any?
    private var state = ChordCaptureState()
    private var commit: ((ChordBinding) -> Void)?

    func begin(commit: @escaping (ChordBinding) -> Void) {
        guard !isRecording else { return }
        self.commit = commit
        state = ChordCaptureState()
        heldPreview = ChordBinding()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            // NSEvent is not Sendable: reduce it to Sendable values before
            // hopping into the isolated handler, which returns swallow-or-not.
            // keyCode/modifierFlags are only valid on key events; mouse
            // events just cancel.
            let isMouse = event.type == .leftMouseDown || event.type == .rightMouseDown
            let captureEvent = isMouse ? nil : Self.captureEvent(from: event)
            let swallow = MainActor.assumeIsolated {
                self.handle(captureEvent, isMouse: isMouse)
            }
            return swallow ? nil : event
        }
    }

    func cancel() {
        stop()
    }

    /// Returns true when the event should be swallowed.
    private func handle(_ event: ChordCaptureEvent?, isMouse: Bool) -> Bool {
        guard let event, !isMouse else {
            stop() // click-away cancels; let the click land
            return false
        }
        switch state.handle(event) {
        case .inProgress(let held):
            heldPreview = held
        case .captured(let chord):
            let commit = commit
            stop()
            commit?(chord)
        case .cancelled:
            stop()
        }
        return true // swallow keys while recording
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        commit = nil
        heldPreview = ChordBinding()
    }

    static func captureEvent(from event: NSEvent) -> ChordCaptureEvent {
        let flags = event.modifierFlags
        return ChordCaptureEvent(
            kind: event.type == .keyDown ? .keyDown : .flagsChanged,
            keyCode: event.keyCode,
            control: flags.contains(.control),
            option: flags.contains(.option),
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            fnFlag: flags.contains(.function)
        )
    }
}

/// A focusable-looking chord recorder field: shows the bound chord as symbols;
/// click to record, press the chord to set it, Esc or click-away to cancel.
struct ChordRecorderView: View {
    @Binding var chord: ChordBinding
    @State private var recorder = ChordRecorderModel()

    var body: some View {
        Button {
            if recorder.isRecording {
                recorder.cancel()
            } else {
                recorder.begin { chord = $0 }
            }
        } label: {
            Text(labelText)
                .foregroundStyle(recorder.isRecording ? .secondary : .primary)
                .frame(minWidth: 130)
        }
        .buttonStyle(.bordered)
        .help(recorder.isRecording
            ? "Press the chord now — Esc or click away to cancel"
            : "Click, then press the modifier chord (Fn works)")
        .onDisappear { recorder.cancel() }
        .accessibilityLabel("Chord recorder")
        .accessibilityValue(ChordSymbols.render(chord))
    }

    private var labelText: String {
        guard recorder.isRecording else { return ChordSymbols.render(chord) }
        let held = recorder.heldPreview
        return held.hasAnyModifier ? "\(ChordSymbols.render(held)) …" : "Press chord…"
    }
}
