import SwiftUI

// MARK: - Status chip styling (pure, unit-tested)

extension CardStatus {
    var chipLabel: String {
        rawValue.capitalized
    }

    /// Chip fill from the token layer (steering/DESIGN_SYSTEM.md). Status
    /// colors appear only on status UI; alpha is baked into the color sets.
    var chipBackground: Color {
        switch self {
        case .queued: .voxiStatusQueuedBg
        case .dispatched: .voxiStatusDispatchedBg
        case .running: .voxiStatusRunningBg
        case .succeeded: .voxiStatusSucceededBg
        case .failed: .voxiStatusFailedBg
        }
    }

    var chipForeground: Color {
        switch self {
        case .queued: .voxiInk2
        case .dispatched: .voxiStatusDispatchedText
        case .running: .accentColor
        case .succeeded: .voxiSuccess
        case .failed: .voxiDanger
        }
    }

    var showsSpinner: Bool {
        self == .running
    }
}

struct StatusChip: View {
    let status: CardStatus

    var body: some View {
        HStack(spacing: 4) {
            if status.showsSpinner {
                Image(systemName: "circle.fill")
                    .font(.system(size: 5))
                    .symbolEffect(.pulse, options: .repeating)
            }
            Text(status.chipLabel)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(status.chipBackground, in: Capsule())
        .foregroundStyle(status.chipForeground)
    }
}
