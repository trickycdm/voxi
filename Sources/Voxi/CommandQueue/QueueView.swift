import SwiftUI

// MARK: - Status chip styling (pure, unit-tested)

extension CardStatus {
    var chipLabel: String {
        rawValue.capitalized
    }

    var chipColor: Color {
        switch self {
        case .queued: .gray
        case .dispatched: .orange
        case .running: .blue
        case .succeeded: .green
        case .failed: .red
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

    @State private var expandedCardID: UUID?

    var body: some View {
        Group {
            if model.cards.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.cards) { card in
                            CardView(
                                card: card,
                                isExpanded: expandedCardID == card.id,
                                onToggleExpanded: {
                                    expandedCardID = expandedCardID == card.id ? nil : card.id
                                },
                                model: model,
                                runner: runner,
                                resolver: resolver
                            )
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 320)
        .task { model.startObserving() }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No commands queued")
                .font(.headline)
            Text("Hold the command hotkey and dictate a task — it lands here as a card you can review and dispatch.")
                .font(.callout)
                .foregroundStyle(.secondary)
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
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    let model: QueueModel
    let runner: QueueRunner
    let resolver: any DispatcherResolving

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
                Divider()
                    .padding(.horizontal, 12)
                CardDetailView(card: card, model: model, runner: runner, resolver: resolver)
                    .padding(12)
            }
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                StatusChip(status: card.status)
            }
            Text(card.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
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
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
    }
}

struct StatusChip: View {
    let status: CardStatus

    var body: some View {
        HStack(spacing: 4) {
            if status.showsSpinner {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(status.chipLabel)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(status.chipColor.opacity(0.18), in: Capsule())
        .foregroundStyle(status.chipColor)
    }
}
