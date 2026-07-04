import Testing
@testable import Voxi

@Suite struct CardLifecycleTests {
    @Test func legalTransitions() {
        #expect(CardStatus.queued.canTransition(to: .dispatched))
        #expect(CardStatus.dispatched.canTransition(to: .running))
        #expect(CardStatus.running.canTransition(to: .succeeded))
        #expect(CardStatus.running.canTransition(to: .failed))
        #expect(CardStatus.failed.canTransition(to: .queued))
    }

    @Test func illegalTransitions() {
        #expect(!CardStatus.queued.canTransition(to: .running))
        #expect(!CardStatus.succeeded.canTransition(to: .queued))
        #expect(!CardStatus.running.canTransition(to: .queued))
    }
}

@Suite struct SignalGuardTests {
    @Test func silenceIsFlagged() {
        #expect(SignalGuard.isLikelySilence(peak: 0.001, rms: 0.0002, duration: 3.0))
    }
    @Test func speechIsNotFlagged() {
        #expect(!SignalGuard.isLikelySilence(peak: 0.4, rms: 0.05, duration: 2.0))
    }
    @Test func tooShortIsFlagged() {
        #expect(SignalGuard.isLikelySilence(peak: 0.5, rms: 0.1, duration: 0.1))
    }
}
