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

// MARK: - Queue

/// The command queue: action cards newest-first, expandable in place.
struct QueueView: View {
    let model: QueueModel
    let runner: QueueRunner
    let resolver: any DispatcherResolving
    var openLog: ((ActionCard) -> Void)? = nil

    @State private var expandedCardID: UUID?

    /// Queued cards a "Run All" would pick up right now.
    private var dispatchableCount: Int {
        QueueLogic.drainOrder(cards: model.cards) { resolver.dispatcher(for: $0)?.paramSpecs }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Rectangle().fill(Color.voxiHairline).frame(height: 1)
            if model.cards.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: Theme.Space.sm) {
                        ForEach(Array(model.cards.enumerated()), id: \.element.id) { index, card in
                            CardView(
                                card: card,
                                number: index + 1,
                                isExpanded: expandedCardID == card.id,
                                onToggleExpanded: {
                                    expandedCardID = expandedCardID == card.id ? nil : card.id
                                },
                                model: model,
                                runner: runner,
                                resolver: resolver,
                                openLog: openLog
                            )
                        }
                    }
                    .padding(Theme.Space.md)
                }
            }
        }
        .background(Color.voxiPaper)
        .frame(minWidth: 440, minHeight: 320)
        .task { model.startObserving() }
    }

    private var headerBar: some View {
        HStack {
            if runner.isDraining {
                ProgressView()
                    .controlSize(.small)
                Text("Running queue…")
                    .font(.callout)
                    .foregroundStyle(Color.voxiInk2)
            }
            Spacer()
            if runner.isDraining {
                Button("Stop (\(runner.drainRemaining ?? 0) left)") {
                    runner.stopDrain()
                }
            } else {
                Button("Run All (\(dispatchableCount))") {
                    Task { await runner.runAll() }
                }
                .disabled(dispatchableCount == 0)
                .help("Dispatch every ready card, oldest first, one at a time")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundStyle(Color.voxiInk3)
            Text("No commands queued")
                .font(.headline)
                .foregroundStyle(Color.voxiInk)
            Text("Hold the command hotkey and dictate a task — it lands here as a card you can review and dispatch.")
                .font(.callout)
                .foregroundStyle(Color.voxiInk2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Card row

struct CardView: View {
    let card: ActionCard
    /// 1-based display position — the racing number on the card's disc.
    let number: Int
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    let model: QueueModel
    let runner: QueueRunner
    let resolver: any DispatcherResolving
    var openLog: ((ActionCard) -> Void)? = nil

    private var workingDirectory: String? {
        let params = (try? QueueParams.decode(card.paramsJSON)) ?? [:]
        let dir = params[QueueParams.workingDirectoryKey] ?? ""
        return dir.isEmpty ? nil : dir
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggleExpanded)
            if isExpanded {
                Rectangle().fill(Color.voxiHairline).frame(height: 1)
                    .padding(.horizontal, Theme.Space.md)
                CardDetailView(card: card, model: model, runner: runner, resolver: resolver, openLog: openLog)
                    .padding(Theme.Space.md)
            }
        }
        .background(Color.voxiCard, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Color.voxiHairline, lineWidth: 1))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                RacingNumberDisc(number: number)
                Text(card.title)
                    .font(.headline)
                    .foregroundStyle(Color.voxiInk)
                    .lineLimit(1)
                Spacer()
                StatusChip(status: card.status)
            }
            Text(card.summary)
                .font(.callout)
                .foregroundStyle(Color.voxiInk2)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(card.createdAt, style: .relative)
                if let workingDirectory {
                    Text("·")
                    Image(systemName: "folder")
                        .imageScale(.small)
                    Text(workingDirectory)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if card.status == .running, let activity = runner.liveRuns[card.id]?.activity {
                    Text("·")
                    Text(activity)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(Color.voxiInk3)
            }
            .font(.caption)
            .foregroundStyle(Color.voxiInk2)
        }
        .padding(Theme.Space.md)
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
