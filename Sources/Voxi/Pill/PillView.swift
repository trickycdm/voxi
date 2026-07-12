import SwiftUI

/// The pill's SwiftUI content — a pure function of PillController.state.
struct PillView: View {
    let controller: PillController

    var body: some View {
        content
            .frame(minHeight: 22)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Color.voxiCard, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.voxiHairline, lineWidth: 1))
            // Coachline: the pill's one ornament — a cream keyline inset just
            // inside the edge, like hand-painted bodywork. Pill only.
            .overlay(Capsule().strokeBorder(Color.voxiCoachline, lineWidth: 1).padding(3))
            .fixedSize()  // intrinsic size → panel sizes itself via sizingOptions
            .padding(6)   // room for the panel shadow
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .idle:
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.voxiInk3)
                .symbolEffect(.variableColor.iterative.dimInactiveLayers,
                              options: .repeating.speed(0.4))

        case .recording(let mode, _):
            HStack(spacing: 12) {
                affordance("xmark", help: "Cancel dictation") {
                    controller.onCancel?()
                }
                HStack(spacing: 8) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(tint(for: mode))
                        .symbolEffect(.pulse, options: .repeating)
                    WaveformBars(level: { controller.level }, isActive: true)
                        .foregroundStyle(tint(for: mode))
                        .frame(width: 84, height: 20)
                }
                affordance("checkmark", help: "Finish dictation") {
                    controller.onDone?()
                }
            }

        case .processing:
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.voxiInk2)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                Text("Working…")
                    .font(.callout)
                    .foregroundStyle(Color.voxiInk2)
            }

        case .notice(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.voxiWarning)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(Color.voxiInk)
                    .lineLimit(1)
            }
        }
    }

    /// Waveform + dot tint. Butter is the live dictation color; command mode
    /// reads as mint (the dark-resolved VoxiSuccess — the panel pins darkAqua).
    private func tint(for mode: PillState.RecordingMode) -> Color {
        switch mode {
        case .dictation: .voxiLive
        case .command: .voxiCommandTint
        }
    }

    private func affordance(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.voxiInk2)
                .frame(width: 20, height: 20)
                .background(Color.voxiInset, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Live waveform bars driven by the mic level. `level` is a closure so Canvas
/// re-reads the freshest smoothed value on every TimelineView tick without
/// per-sample view diffing; `paused:` drops redraw cost to zero when inactive.
struct WaveformBars: View {
    var level: () -> Float          // 0...1, already smoothed upstream
    var isActive: Bool
    var barCount: Int = 14

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isActive)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let lvl = CGFloat(max(0, min(1, level())))
                let barWidth = size.width / (CGFloat(barCount) * 1.6)
                let gap = barWidth * 0.6

                for i in 0..<barCount {
                    // Phase-offset sine per bar, amplitude scaled by mic level:
                    // quiet input = subtle ripple, loud input = tall bars.
                    let phase = t * 6 + Double(i) * 0.7
                    let wobble = (sin(phase) + 1) / 2
                    let h = max(2, size.height * lvl * (0.35 + 0.65 * wobble))
                    let x = CGFloat(i) * (barWidth + gap)
                    let rect = CGRect(x: x, y: (size.height - h) / 2, width: barWidth, height: h)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .style(ForegroundStyle())
                    )
                }
            }
        }
        .drawingGroup()
    }
}
