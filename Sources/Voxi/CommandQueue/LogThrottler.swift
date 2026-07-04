import Foundation

/// Batches log chunks so a chatty dispatcher doesn't turn into hundreds of
/// database writes per second: appends accumulate in memory and flush on a
/// fixed cadence (~4x/sec by default). `finish()` always flushes whatever
/// remains, after waiting out any in-flight flush so chunk order is preserved.
@MainActor
final class LogThrottler {
    private let interval: Duration
    private let flush: (String) async -> Void
    private var buffer = ""
    private var flushTask: Task<Void, Never>?
    private var isFinished = false

    init(interval: Duration = .milliseconds(250), flush: @escaping (String) async -> Void) {
        self.interval = interval
        self.flush = flush
    }

    func append(_ chunk: String) {
        guard !isFinished, !chunk.isEmpty else { return }
        buffer += chunk
        scheduleFlushIfNeeded()
    }

    /// Flushes the remainder and refuses further appends.
    func finish() async {
        isFinished = true
        let inFlight = flushTask
        flushTask = nil
        inFlight?.cancel()
        // If a periodic flush is mid-write, let it complete first so the
        // final chunk lands after it, not interleaved.
        await inFlight?.value
        await flushNow()
    }

    private func scheduleFlushIfNeeded() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            while true {
                guard let self, !self.isFinished else { return }
                try? await Task.sleep(for: self.interval)
                if Task.isCancelled { return }
                await self.flushNow()
                if self.buffer.isEmpty {
                    self.flushTask = nil
                    return
                }
            }
        }
    }

    private func flushNow() async {
        guard !buffer.isEmpty else { return }
        let chunk = buffer
        buffer = ""
        await flush(chunk)
    }
}
