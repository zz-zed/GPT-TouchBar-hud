import Foundation
import Testing
@testable import ResetNewsCore

struct ResetNewsRuleSemanticsTests {
    private let now = Date(timeIntervalSince1970: 1_790_985_600)

    private func source(_ text: String, facts: [ResetNewsFact]? = nil) -> ResetNewsSourceItem {
        ResetNewsSourceItem(source: .feed, sourceID: "100", url: URL(string: "https://x.com/thsottiaux/status/100"),
                            body: text, publishedAt: now, structuredFacts: facts)
    }

    @Test(arguments: [
        "Codex reset animation coming tomorrow.",
        "Codex quota reset button will arrive tomorrow.",
        "The Codex reset is not happening tomorrow.",
        "The Codex reset will not happen tomorrow.",
        "A Codex reset is unlikely tomorrow.",
        "We are considering a Codex reset tomorrow.",
        "Will Codex limits reset tomorrow?",
        "Should we reset Codex limits tomorrow?"
    ]) func unrelatedDeniedAndQuestionedActionsAreNotForecasts(_ text: String) {
        let engine = ResetNewsRuleEngine()
        #expect(engine.resetFactEvidence(in: text).isEmpty)
        #expect(engine.evaluate(source(text), now: now)?.facts.contains { $0.kind == .upcomingReset } != true)
    }

    @Test(arguments: [
        "Codex limits are getting 2 extra resets tomorrow.",
        "Codex quota gets a banked reset tomorrow.",
        "Every Plus account gets a full banked reset tomorrow.",
        "Codex limits get additional reset credits tomorrow."
    ]) func creditEntitlementsNeverEstablishQuotaReset(_ text: String) {
        let engine = ResetNewsRuleEngine()
        #expect(engine.resetFactEvidence(in: text).isEmpty)
        #expect(engine.evaluate(source(text), now: now)?.facts.contains { $0.kind == .upcomingReset } != true)
    }

    @Test(arguments: [
        "Codex limits will reset tomorrow.",
        "Global reset landing tomorrow 10am PST for all paid ChatGPT accounts.",
        "Full reset within the hour plus one additional banked reset.",
        "Codex reset will be completed tomorrow.",
        "Codex limits will have reset tomorrow."
    ]) func explicitFutureQuotaActionsRemainRecognized(_ text: String) {
        #expect(ResetNewsRuleEngine().resetFactEvidence(in: text).map(\.kind) == [.upcomingReset])
    }

    @Test(arguments: [
        "We reset Codex limits yesterday and a new model launches tomorrow.",
        "We reset Codex limits yesterday. A new model launches tomorrow.",
        "We reset Codex limits yesterday and the model will launch tomorrow.",
        "Full reset applied yesterday plus a new model landing tomorrow."
    ]) func completedQuotaResetKeepsItsOwnActionTime(_ text: String) {
        let engine = ResetNewsRuleEngine()
        #expect(engine.resetFactEvidence(in: text).map(\.kind) == [.resetAnnouncement])
        #expect(engine.evaluate(source(text), now: now)?.facts.contains { $0.kind == .upcomingReset } != true)
    }

    @Test func independentFutureResetAfterCompletionIsPreserved() throws {
        let text = "We reset Codex limits yesterday and Codex limits will reset tomorrow."
        let engine = ResetNewsRuleEngine()
        #expect(engine.resetFactEvidence(in: text).map(\.kind) == [.resetAnnouncement, .upcomingReset])
        let item = try #require(engine.evaluate(source(text), now: now))
        #expect(item.facts.contains { $0.kind == .upcomingReset && $0.timingText == "tomorrow" })
    }

    @Test func independentFutureResetAfterCancellationIsActive() throws {
        let text = "Codex limits reset is cancelled today. Global reset landing tomorrow."
        let engine = ResetNewsRuleEngine()
        #expect(engine.resetFactEvidence(in: text).map(\.kind) == [.resetAnnouncement, .upcomingReset])
        let item = try #require(engine.evaluate(source(text), now: now))
        #expect(item.status == .active)
        #expect(ResetForecastPolicy().retaining(item, now: now) != nil)
    }

    @Test func laterCancellationRetiresEarlierFutureReset() throws {
        let text = "Codex limits will reset tomorrow. The reset has been cancelled."
        let engine = ResetNewsRuleEngine()
        #expect(engine.resetFactEvidence(in: text).map(\.kind) == [.upcomingReset, .resetAnnouncement])
        let item = try #require(engine.evaluate(source(text), now: now))
        #expect(ResetForecastPolicy().retaining(item, now: now) == nil)
    }

    @Test(arguments: [
        "Codex limits will reset tomorrow. Codex limits will not reset tomorrow.",
        "Global reset landing tomorrow. We won't reset Codex limits tomorrow.",
        "Codex limits will reset tomorrow. We reset Codex limits today."
    ]) func lastTerminalActionRetiresEarlierPromise(_ text: String) {
        #expect(ResetNewsRuleEngine().lastResetActionIsTerminal(in: text))
    }

    @Test(arguments: [
        "Codex limits will not reset today. Codex limits will reset tomorrow.",
        "The reset has been cancelled. Global reset landing tomorrow.",
        "Codex limits will reset tomorrow. The reset is not cancelled.",
        "Codex limits will reset tomorrow. Will the reset be cancelled?",
        "Codex limits will reset tomorrow. We cancelled the banked reset credits."
    ]) func laterIndependentPromiseAndUnrelatedStatementsStayActive(_ text: String) {
        #expect(!ResetNewsRuleEngine().lastResetActionIsTerminal(in: text))
    }

    @Test func pureDenialIsTerminalEvidenceWithoutBecomingAResetFact() {
        let text = "Codex limits will not reset tomorrow."
        let engine = ResetNewsRuleEngine()
        #expect(engine.lastResetActionIsTerminal(in: text))
        #expect(engine.resetFactEvidence(in: text).isEmpty)
        #expect(engine.evaluate(source(text), now: now) == nil)
    }

    @Test func questionDoesNotEraseFollowingIndependentCommitment() {
        let text = "Will Codex limits reset today? Codex limits will reset tomorrow."
        let evidence = ResetNewsRuleEngine().resetFactEvidence(in: text)
        #expect(evidence.map(\.kind) == [.upcomingReset])
        #expect(evidence.first?.evidence.contains("tomorrow") == true)
    }

    @Test func planConjunctionDoesNotSplitEligibility() throws {
        let text = "Full reset tomorrow for Plus and Pro users."
        let engine = ResetNewsRuleEngine()
        let evidence = try #require(engine.resetFactEvidence(in: text).first)
        #expect(evidence.kind == .upcomingReset)
        #expect(engine.audience(in: evidence.evidence) == "plus,pro")
    }

    @Test func planNamesRequireEligibilityContext() {
        let engine = ResetNewsRuleEngine()
        #expect(engine.audience(in: "Full reset within the hour plus one additional banked reset.") == nil)
        #expect(engine.audience(in: "All paid users got a reset. Thanks to an incredible team.") == "paid")
        #expect(engine.audience(in: "We reset limits for everyone and the team will keep working.") == "all")
        #expect(engine.audience(in: "Codex changes give free improvements to performance.") == nil)
        #expect(engine.audience(in: "All paid plans reset ahead of the Plus 5h-limit return.") == "paid")
        #expect(engine.audience(in: "Global reset for all paid ChatGPT accounts, plus improved performance.") == "paid_chatgpt")
        #expect(engine.audience(in: "One banked reset loaded into every Plus, Pro and Business account.") == "business,plus,pro")
        #expect(engine.audience(in: "We reset rate limits for Plus & Pro.") == "plus,pro")
        #expect(engine.audience(in: "Re-opening the Pro $200 subscriptions.") == "pro")
    }

    @Test func historicalTuesdayPromiseStillMigratesTentatively() throws {
        let text = "We are almost Tuesday and I promised a reset for Tuesday."
        let legacy = [ResetNewsFact(kind: .resetAnnouncement, confidence: .tentative)]
        let item = try #require(ResetNewsRuleEngine().evaluate(source(text, facts: legacy), now: now))
        #expect(item.facts.map(\.kind) == [.upcomingReset])
        #expect(item.facts.first?.confidence == .tentative)
        #expect(item.facts.first?.timingText?.lowercased() == "tuesday")
    }

    @Test(arguments: ["Codex reset animation coming tomorrow.",
                      "Codex quota reset button will arrive tomorrow.",
                      "Codex limits are getting 2 extra resets tomorrow.",
                      "Will Codex limits reset tomorrow?"])
    func classifierPreviewCannotOverrideActionMeaning(_ text: String) throws {
        let record: [String: Any] = ["id": "100", "url": "https://x.com/thsottiaux/status/100", "summary": text,
                                    "group": "reset", "preview": true, "confidence": "high", "announced_at": now.timeIntervalSince1970]
        let decoded = try ResetNewsSourceDecoder().decode(JSONSerialization.data(withJSONObject: ["events": [record]]), source: .timeline)
        #expect(decoded.first?.structuredFacts?.contains { $0.kind == .upcomingReset } != true)
        #expect(ResetNewsReducer().reduce(previous: .init(), incoming: decoded, now: now).state.items.isEmpty)
    }
}
