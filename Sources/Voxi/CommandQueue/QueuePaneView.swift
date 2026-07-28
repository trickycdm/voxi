import SwiftUI

/// The Hub's Queue pane: a hand-rolled master–detail split (card list left,
/// full card detail right) — same manual-HStack convention as HubView itself;
/// the app deliberately avoids NavigationSplitView.
struct QueuePaneView: View {
    let model: QueueModel
    let runner: QueueRunner
    let resolver: any DispatcherResolving
    /// Opens the card's full log window (threaded down from AppState).
    var openLog: ((ActionCard) -> Void)? = nil
    /// Notification deep-link: card to select on next appearance (HubRouter).
    @Binding var pendingCardID: UUID?

    @State private var selectedCardID: UUID?
    @State private var confirmingClearFinished = false

    /// Queued cards a "Run All" would pick up right now.
    private var dispatchableCount: Int {
        QueueLogic.drainOrder(cards: model.cards) { resolver.dispatcher(for: $0)?.paramSpecs }.count
    }

    private var finishedCount: Int {
        model.cards.count { $0.status.isTerminal }
    }

    private var selectedCard: ActionCard? {
        model.cards.first { $0.id == selectedCardID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HubPaneHeader("Queue") { headerControls }
            Rectangle().fill(Color.voxiHairline).frame(height: 1)
            if model.cards.isEmpty {
                emptyState
            } else {
                split
            }
        }
        .background(Color.voxiPaper)
        .task { model.startObserving() }
        .onChange(of: pendingCardID, initial: true) { consumePendingCard() }
        .onChange(of: model.cards) { maintainSelection() }
        .onAppear { maintainSelection() }
        .confirmationDialog(
            "Delete \(finishedCount) finished card\(finishedCount == 1 ? "" : "s")?",
            isPresented: $confirmingClearFinished
        ) {
            Button("Delete Finished", role: .destructive) {
                Task { try? await model.clearFinished() }
            }
        } message: {
            Text(
                "This permanently deletes every succeeded and failed card. "
                    + "Queued and running cards are kept. This cannot be undone.")
        }
    }

    // MARK: Header

    @ViewBuilder
    private var headerControls: some View {
        if runner.isDraining {
            ProgressView()
                .controlSize(.small)
            Button("Stop (\(runner.drainRemaining ?? 0) left)") {
                runner.stopDrain()
            }
        } else {
            Button("Run All (\(dispatchableCount))") {
                Task { await runner.runAll() }
            }
            .disabled(dispatchableCount == 0)
            .help("Dispatch every ready card, oldest first, one at a time")
            Button("Clear Finished", systemImage: "trash") {
                confirmingClearFinished = true
            }
            .disabled(finishedCount == 0)
            .help("Delete every succeeded and failed card")
        }
    }

    // MARK: Split

    private var split: some View {
        HStack(spacing: 0) {
            listColumn
                .frame(width: 300)
            Rectangle().fill(Color.voxiHairline).frame(width: 1)
            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var listColumn: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Space.sm) {
                ForEach(Array(model.cards.enumerated()), id: \.element.id) { index, card in
                    QueueCardRow(
                        card: card,
                        number: index + 1,
                        isSelected: selectedCardID == card.id,
                        liveActivity: card.status == .running
                            ? runner.liveRuns[card.id]?.activity : nil,
                        onSelect: { selectedCardID = card.id }
                    )
                    .contextMenu { contextMenu(for: card) }
                }
            }
            .padding(Theme.Space.md)
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let card = selectedCard {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    detailHeader(card)
                    CardDetailView(
                        card: card, model: model, runner: runner,
                        resolver: resolver, openLog: openLog)
                }
                .padding(.horizontal, Theme.Space.xl)
                .padding(.vertical, Theme.Space.lg)
            }
            // Load-bearing: CardDetailView seeds its prompt/params drafts in
            // .onAppear; without an identity reset per card, edits bleed
            // across selections.
            .id(card.id)
        } else {
            ContentUnavailableView(
                "No Card Selected",
                systemImage: "rectangle.stack",
                description: Text("Select a card to review and dispatch it.")
            )
        }
    }

    private func detailHeader(_ card: ActionCard) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                Text(card.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.voxiInk)
                    .textSelection(.enabled)
                Spacer()
                StatusChip(status: card.status)
            }
            Text(card.createdAt, style: .relative)
                .font(.caption)
                .foregroundStyle(Color.voxiInk2)
        }
    }

    // MARK: Row actions

    /// Status is re-checked inside each action: a context menu can outlive a
    /// status flip (e.g. a drain dispatching the card mid-menu).
    @ViewBuilder
    private func contextMenu(for card: ActionCard) -> some View {
        if card.status == .dispatched || card.status == .running {
            Button("Cancel") { runner.cancel(cardID: card.id) }
        }
        if card.status == .failed {
            Button("Retry") {
                Task { try? await model.retry(id: card.id) }
            }
        }
        if card.status.isTerminal, card.sessionID != nil {
            Button("Follow Up") {
                Task { try? await model.followUp(from: card) }
            }
        }
        if card.status != .dispatched && card.status != .running {
            Button("Delete", role: .destructive) {
                Task {
                    guard let current = model.cards.first(where: { $0.id == card.id }),
                        current.status != .dispatched, current.status != .running
                    else { return }
                    try? await model.delete(id: card.id)
                }
            }
        }
    }

    // MARK: Selection maintenance

    private func consumePendingCard() {
        guard let pending = pendingCardID,
            model.cards.contains(where: { $0.id == pending })
        else { return }
        selectedCardID = pending
        pendingCardID = nil
    }

    /// Keep a valid selection: seed with the newest card, and fall back when
    /// the selected card is deleted. Never auto-switch on new-card arrival —
    /// the user may be mid-edit.
    private func maintainSelection() {
        consumePendingCard()
        if selectedCardID == nil || selectedCard == nil {
            selectedCardID = model.cards.first?.id
        }
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

struct QueueCardRow: View {
    let card: ActionCard
    /// 1-based display position — the racing number on the card's disc.
    let number: Int
    let isSelected: Bool
    /// Current activity line while running (from the runner's live state).
    let liveActivity: String?
    let onSelect: () -> Void

    @State private var isHovering = false

    private var workingDirectory: String? {
        let params = (try? QueueParams.decode(card.paramsJSON)) ?? [:]
        let dir = params[QueueParams.workingDirectoryKey] ?? ""
        return dir.isEmpty ? nil : dir
    }

    private var fill: Color {
        isSelected || isHovering ? .voxiInset : .voxiCard
    }

    private var border: Color {
        isSelected ? .accentColor : .voxiHairline
    }

    var body: some View {
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
                    Text((workingDirectory as NSString).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if let liveActivity {
                    Text("·")
                    Text(liveActivity)
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(Color.voxiInk2)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(border, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
