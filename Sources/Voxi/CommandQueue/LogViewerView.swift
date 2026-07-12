import SwiftUI

/// Full-window log for one card: complete persisted log (or the live tail
/// while running — see `QueueLogic.displayLog`), monospaced and selectable,
/// with follow-tail autoscroll and copy.
///
/// Resolves the card live from the model so the content keeps updating
/// while the run streams; the window survives the card finishing.
struct LogViewerView: View {
    let cardID: UUID
    let model: QueueModel
    let runner: QueueRunner

    @State private var followTail = true

    private var card: ActionCard? {
        model.cards.first { $0.id == cardID }
    }

    private var log: String {
        guard let card else { return "" }
        return QueueLogic.displayLog(
            status: card.status,
            liveTail: runner.liveRuns[card.id]?.logTail,
            persistedLog: card.log)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    Text(log.isEmpty ? "No output yet." : log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(log.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    Color.clear
                        .frame(height: 1)
                        .id("logEnd")
                }
                .onChange(of: log) {
                    if followTail { proxy.scrollTo("logEnd", anchor: .bottom) }
                }
                .onChange(of: followTail) {
                    if followTail { proxy.scrollTo("logEnd", anchor: .bottom) }
                }
                .onAppear {
                    proxy.scrollTo("logEnd", anchor: .bottom)
                }
            }
        }
    }

    private var toolbar: some View {
        HStack {
            if let card {
                StatusChip(status: card.status)
                if card.status == .running, let activity = runner.liveRuns[card.id]?.activity {
                    Text(activity)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text("Card deleted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Follow", isOn: $followTail)
                .toggleStyle(.checkbox)
                .help("Keep scrolled to the newest output")
            Button("Copy All") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(log, forType: .string)
            }
            .disabled(log.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
