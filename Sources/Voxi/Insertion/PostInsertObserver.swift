import Foundation

/// Watches the focused text field briefly after an insertion and learns a
/// narrow `wrong → right` pair from the user's manual fix (polling shape
/// ported from ghost-pepper, MIT). The diff heuristic and all its guards are
/// `CorrectionInference`; this is the impure polling shell.
///
/// Privacy: field reads stay in-process and are never logged (root steering
/// rule); observation only ever targets the app the text was inserted into
/// and aborts the moment the user switches away.
@MainActor
final class PostInsertObserver {
    static let observationWindow: TimeInterval = 15
    static let pollInterval: TimeInterval = 1
    static let quiescencePeriod: TimeInterval = 2

    static var maximumPollCount: Int { Int(observationWindow / pollInterval) + 1 }
    static var requiredStablePollCount: Int { Int(quiescencePeriod / pollInterval) }

    /// Reads the frontmost app's focused-field text, or nil when unreadable.
    typealias FieldReader = @MainActor () -> String?
    /// Current frontmost application bundle ID.
    typealias FrontmostReader = @MainActor () -> String?
    /// Injectable delay for tests.
    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    var onLearnedCorrection: (@MainActor (CorrectionInference.Correction) -> Void)?

    private let readField: FieldReader
    private let readFrontmost: FrontmostReader
    private let sleeper: Sleeper
    private var task: Task<Void, Never>?

    init(
        readField: @escaping FieldReader,
        readFrontmost: @escaping FrontmostReader,
        sleeper: @escaping Sleeper = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.readField = readField
        self.readFrontmost = readFrontmost
        self.sleeper = sleeper
    }

    /// Starts observing after an insertion. A new call (next dictation)
    /// cancels the previous observation.
    func begin(insertedText: String, targetBundleID: String?) {
        cancel()
        guard let targetBundleID else { return }
        task = Task { [weak self] in
            await self?.run(insertedText: insertedText, targetBundleID: targetBundleID)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func run(insertedText: String, targetBundleID: String) async {
        // Snapshot right after insertion = the diff baseline. If the field
        // isn't readable yet, the first successful poll becomes the baseline.
        var baseline = normalized(readField())
        var latest: String?
        var stablePolls = 0

        for _ in 0..<Self.maximumPollCount {
            do { try await sleeper(Self.pollInterval) } catch { return }
            guard !Task.isCancelled else { return }
            // The user moved on — text in another app is none of our business.
            guard readFrontmost() == targetBundleID else { return }

            if let text = normalized(readField()) {
                if baseline == nil {
                    baseline = text
                    latest = text
                } else if let current = latest,
                          text.caseInsensitiveCompare(current) == .orderedSame {
                    stablePolls += 1
                } else {
                    latest = text
                    stablePolls = 0
                }
            }

            if let baseline, let latest, stablePolls >= Self.requiredStablePollCount {
                if let correction = CorrectionInference.inferredCorrection(
                    from: baseline, to: latest, constrainedTo: insertedText) {
                    onLearnedCorrection?(correction)
                }
                return
            }
        }
    }

    private func normalized(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }
}
