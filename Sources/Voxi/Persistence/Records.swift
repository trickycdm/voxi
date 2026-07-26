import Foundation

/// One completed dictation, kept locally forever (searchable in the Hub).
struct HistoryEntry: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var createdAt: Date
    var rawTranscript: String
    /// Post-refinement text as inserted (or as carded, for command mode).
    var finalText: String
    /// ASREngine.id that produced it.
    var engineID: String
    var modelID: String
    /// Refiner.id used, if any refinement ran.
    var refinerID: String?
    /// Bundle id of the app the text was inserted into, nil for command mode.
    var targetAppBundleID: String?
    var durationSeconds: Double

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        rawTranscript: String,
        finalText: String,
        engineID: String,
        modelID: String,
        refinerID: String? = nil,
        targetAppBundleID: String? = nil,
        durationSeconds: Double = 0
    ) {
        self.id = id
        self.createdAt = createdAt
        self.rawTranscript = rawTranscript
        self.finalText = finalText
        self.engineID = engineID
        self.modelID = modelID
        self.refinerID = refinerID
        self.targetAppBundleID = targetAppBundleID
        self.durationSeconds = durationSeconds
    }
}

/// One wrong→right pair picked up by post-insert correction learning.
/// Pure log for the Hub's "Learned Corrections" list — enforcement happens
/// through the dictionary entry the pair was folded into.
struct LearnedCorrection: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    /// What was inserted (the mishearing).
    var wrong: String
    /// What the user corrected it to.
    var right: String
    var learnedAt: Date

    init(id: UUID = UUID(), wrong: String, right: String, learnedAt: Date = Date()) {
        self.id = id
        self.wrong = wrong
        self.right = right
        self.learnedAt = learnedAt
    }
}

/// Personal dictionary term fed to the transcriber/refiner.
struct DictionaryEntry: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var term: String
    /// Optional common misspellings/mishearings that should map to `term`.
    var variants: [String]
    var createdAt: Date

    init(id: UUID = UUID(), term: String, variants: [String] = [], createdAt: Date = Date()) {
        self.id = id
        self.term = term
        self.variants = variants
        self.createdAt = createdAt
    }
}
