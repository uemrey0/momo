import Foundation
import Testing

@testable import MomoKit

@Suite("BrainRouter")
struct BrainRouterTests {
    let local = BrainCandidate(id: "apple", name: "Apple", kind: .local, comfortableLength: 6_000)
    let codex = BrainCandidate(id: "codex", name: "ChatGPT", kind: .subscription)

    @Test("keeps simple requests local")
    func simpleStaysLocal() {
        let decision = BrainRouter().route(
            text: "Remind me to call mom at 5", candidates: [local, codex])
        #expect(decision == .use(local, reason: .simpleRequest(difficulty: 1), needsConsent: false))
    }

    @Test("sends hard requests to a remote brain with consent")
    func hardGoesRemote() {
        let text = String(
            repeating: "Please analyze this contract in detail and compare the clauses. ", count: 12
        )
        guard
            case .use(let brain, _, let consent) = BrainRouter().route(
                text: text, candidates: [local, codex])
        else {
            Issue.record("Expected a brain")
            return
        }
        #expect(brain == codex)
        #expect(consent)
    }

    @Test("never leaves the Mac in local-only mode")
    func localOnly() {
        let router = BrainRouter(policy: RoutingPolicy(localOnly: true))
        let text = String(repeating: "analyze in detail ", count: 400)
        #expect(
            router.route(text: text, candidates: [local, codex])
                == .use(local, reason: .privacyLock, needsConsent: false))
        if case .use = router.route(text: "hi", candidates: [codex]) {
            Issue.record("Should not use a remote brain")
        }
    }

    @Test("uses a remote brain when nothing local is available")
    func noLocal() {
        let unavailable = BrainCandidate(
            id: "apple", name: "Apple", kind: .local, isAvailable: false)
        #expect(
            BrainRouter().route(text: "hi", candidates: [unavailable, codex], remoteApproved: true)
                == .use(codex, reason: .noLocalBrain, needsConsent: false))
    }

    @Test("honours the user's choice")
    func forcedChoice() {
        #expect(
            BrainRouter().route(text: "hi", candidates: [local, codex], forcedBrainID: "codex")
                == .use(codex, reason: .userChoice, needsConsent: true))
    }

    @Test("estimates difficulty across languages")
    func difficulty() {
        #expect(DifficultyEstimator.estimate("Yarın saat 3'te toplantıyı hatırlat") == 1)
        #expect(
            DifficultyEstimator.estimate("Bu sözleşmeyi detaylı analiz et ve riskleri karşılaştır")
                >= 3)
        #expect(DifficultyEstimator.estimate("```swift\nfunc a() {}\n```\nDebug this") >= 4)
    }
}
