import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import MemoirCore
@testable import ShadowJobs

@Suite("Insight engine", TestTimeLimit.standard)
struct InsightEngineTests {
  private static let night = InsightHarness.day("2026-11-21")
  private static let afterTwo = ZonedFields(date: night, minuteOfDay: 130, second: 0)
  private static let question = "why do I keep missing evening quests?"
  private static let setBeforeTwo = ZonedFields(date: night, minuteOfDay: 60, second: 0)

  private func scheduled(_ harness: InsightHarness, question: String = question, at local: ZonedFields = setBeforeTwo) async throws {
    try await harness.stores.main.write { transaction in try InsightSchedules.set(InsightScheduleRecord(question: question, setAt: local), in: &transaction) }
  }

  private func settled(_ due: InsightDue) async throws -> AttemptResult {
    let handle = try #require(due.handle, "expected a started attempt, got \(due.label)")
    return await handle.result
  }

  @Test func shouldWaitForTheCallConsentBeforeRequestingTheNightlyJob() async throws {
    let harness = try InsightHarness()
    try await scheduled(harness)
    let due = try await harness.engine.runDue(at: Self.afterTwo)
    guard case .waitingForConsent(let request) = due else { throw MemoirFixtureError(description: "expected to wait, got \(due.label)") }
    #expect(request.dataClass == InsightConsent.call.dataClass)
    #expect(request.host == InsightHarness.host)
    let jobs = try await harness.stores.main.read { transaction in try transaction.states(ofKind: JobSchema.jobKind, scope: .vault).count }
    #expect(jobs == 0)
    #expect(harness.provider.requests.isEmpty)
  }

  @Test func shouldRunTheNightOnceKeepOnlyApplicableSuggestionsAndIssueNoCommand() async throws {
    let harness = try InsightHarness(replay: StubReplay(try InsightHarness.replayState()))
    try await harness.seed()
    try await harness.grant()
    try await scheduled(harness)
    let quest = InsightHarness.quest.lowercasedString
    harness.provider.enqueueReply(
      InsightHarness.reply(suggestions: [
        ["kind": "shift_time", "questId": quest, "text": "Try the run 45 minutes earlier."],
        ["kind": "grant_xp", "questId": quest, "text": "Give yourself 100 XP."],
        ["kind": "pause_quest", "questId": "0190f3a0-0000-7000-8000-0000000000ff", "text": "Pause it."],
      ]))

    #expect(try await settled(try await harness.engine.runDue(at: Self.afterTwo)) == .settled(.succeeded))
    let results = try await harness.results()
    let result = try #require(results.first)
    #expect(results.count == 1)
    #expect(result.syncClass == .general)
    #expect(result.question == Self.question)
    #expect(result.suggestions == [InsightSuggestion(kind: .known(.shiftTime), quest: InsightHarness.quest, text: "Try the run 45 minutes earlier.")])
    #expect(result.citations.contains(.known(.quests)))
    #expect(try await harness.commandCount() == 0)

    let key = try InsightJobAddress.key(.scheduled, target: .night(Self.night))
    #expect(key.target == "date:2026-11-21")
    let snapshot = try #require(try await harness.snapshot(key.ref))
    #expect(snapshot.job.request.origin == ["source": "scheduled", "date": "2026-11-21"])
    #expect(snapshot.job.request.payload == ["question": .string(Self.question)])
    #expect(snapshot.attempts.first?.calls.count == 1)

    let again = try await harness.engine.runDue(at: ZonedFields(date: Self.night, minuteOfDay: 900, second: 0))
    #expect(again.label == "succeeded")
    #expect(harness.provider.requests.count == 1)
  }

  @Test func shouldFailABlockedAnswerForGoodAndStoreNothing() async throws {
    let harness = try InsightHarness()
    try await harness.grant()
    try await scheduled(harness)
    harness.provider.enqueueReply(InsightHarness.reply(answer: "You are lazy about evenings."))
    let result = try await settled(try await harness.engine.runDue(at: Self.afterTwo))
    guard case .settled(.failed(let failure)) = result else { throw MemoirFixtureError(description: "expected a failure, got \(result)") }
    #expect(failure.code == "insight.guardrail_blocked")
    #expect(failure.message.contains("identity_assertion"))
    #expect(!failure.message.contains("lazy"))
    #expect(try await harness.results().isEmpty)
    #expect(try await harness.engine.runDue(at: Self.afterTwo).label == "failed:insight.guardrail_blocked")
    #expect(harness.provider.requests.count == 1)
  }

  @Test func shouldStoreTheCrisisHandoffInPlaceOfTheAnswerWithoutMarkingIt() async throws {
    let harness = try InsightHarness()
    try await harness.grant()
    try await scheduled(harness, question: "I want to die when I miss my quests, what should I change?")
    harness.provider.enqueueReply(InsightHarness.reply(suggestions: [["kind": "shift_time", "questId": "x", "text": "Move it."]], note: "Thin data."))
    #expect(try await settled(try await harness.engine.runDue(at: Self.afterTwo)) == .settled(.succeeded))
    let result = try #require(try await harness.results().first)
    #expect(result.answer == InsightGuardrails.crisisResponseAnswer)
    #expect(result.patterns.isEmpty)
    #expect(result.suggestions.isEmpty)
    #expect(result.limitationNote == nil)
    let fields = try await harness.stores.main.read { transaction in
      try transaction.states(ofKind: MemoirKind.generalInsight.entityKind, scope: .vault).first.map { item -> [String] in
        guard case .record(let record) = item.state else { return [] }
        return record.fields.keys.map(\.value)
      }
    }
    #expect(Set(try #require(fields)) == Set(InsightField.allCases.map(\.rawValue) + ["removed"]).subtracting(["limitation_note"]))
  }

  @Test func shouldNotRetryARefusal() async throws {
    let harness = try InsightHarness()
    try await harness.grant()
    try await scheduled(harness)
    harness.provider.enqueueReply("", stop: .refusal(category: nil))
    let result = try await settled(try await harness.engine.runDue(at: Self.afterTwo))
    guard case .settled(.failed(let failure)) = result else { throw MemoirFixtureError(description: "expected a failure, got \(result)") }
    #expect(failure.code == "insight.refused")
    #expect(try await harness.engine.runDue(at: Self.afterTwo).label == "failed:insight.refused")
  }

  @Test func shouldRetryAnAnswerOffTheContractUpToTheAttemptLimit() async throws {
    let harness = try InsightHarness()
    try await harness.grant()
    try await scheduled(harness)
    for attempt in 1...InsightEngine.maximumAttempts {
      harness.provider.enqueueReply(#"{"patterns":[]}"#)
      harness.provider.enqueueReply("still no JSON here")
      let result = try await settled(try await harness.engine.runDue(at: Self.afterTwo))
      guard case .settled(.failed(let failure)) = result else { throw MemoirFixtureError(description: "attempt \(attempt): \(result)") }
      #expect(failure.code == "insight.unusable_answer")
    }
    #expect(try await harness.engine.runDue(at: Self.afterTwo).label == "failed:insight.unusable_answer")
    #expect(harness.provider.requests.count == 2 * InsightEngine.maximumAttempts)
  }

  @Test func shouldKeepAResultBuiltFromHealthDataInTheRestrictedStore() async throws {
    let harness = try InsightHarness(replay: StubReplay(try InsightHarness.replayState()))
    try await harness.seed()
    try await harness.grant([.health])
    try await scheduled(harness)
    harness.provider.enqueueReply(InsightHarness.reply())
    #expect(try await settled(try await harness.engine.runDue(at: Self.afterTwo)) == .settled(.succeeded))
    let prompt = try #require(harness.sentPrompts.first)
    #expect(prompt.contains(#""kg":"72.4""#))
    #expect(!prompt.contains(InsightHarness.journalText))
    #expect(try await harness.results().map(\.syncClass) == [.health])
    let general = try await harness.stores.main.read { transaction in try transaction.states(ofKind: MemoirKind.generalInsight.entityKind, scope: .vault).count }
    #expect(general == 0)
  }

  @Test func shouldGatherAgainWithoutAClassWithdrawnWhileGathering() async throws {
    let revoked = RevokeOnce()
    let replay = StubReplay(try InsightHarness.replayState()) { includingText in await revoked.run(includingText) }
    let harness = try InsightHarness(replay: replay)
    await revoked.set(harness)
    try await harness.seed()
    try await harness.grant([.journalReflectionReason])
    try await scheduled(harness)
    harness.provider.enqueueReply(InsightHarness.reply())
    #expect(try await settled(try await harness.engine.runDue(at: Self.afterTwo)) == .settled(.succeeded))
    #expect(replay.includingText == [true, false])
    let prompt = try #require(harness.sentPrompts.first)
    #expect(!prompt.contains(InsightHarness.journalText))
    #expect(!prompt.contains(InsightHarness.reasonNote))
  }

  @Test func shouldAnswerAnAdHocQuestionAndRefuseAQuestionOutOfLength() async throws {
    let harness = try InsightHarness()
    try await harness.grant()
    harness.provider.enqueueReply(InsightHarness.reply())
    let id = MemoirStoreFixture.commandID(77)
    #expect(try await settled(try await harness.engine.ask("how was my week?", id: id)) == .settled(.succeeded))
    #expect(try await harness.engine.ask("how was my week?", id: id).label == "succeeded")
    let key = try InsightJobAddress.key(.adhoc, target: .question(id))
    #expect(try await harness.snapshot(key.ref)?.job.request.origin == ["source": "adhoc", "question": .string(id.lowercasedString)])
    await #expect(throws: InsightError.self) { _ = try await harness.engine.ask("", id: MemoirStoreFixture.commandID(78)) }
    await #expect(throws: InsightError.self) { _ = try await harness.engine.ask(String(repeating: "é", count: 2001), id: MemoirStoreFixture.commandID(79)) }
    #expect(try await harness.engine.ask(String(repeating: "😀", count: 2000), id: MemoirStoreFixture.commandID(80)).label == "started")
  }

  @Test func shouldPickTheLatestNightWhoseMinuteHasPassed() throws {
    let schedule = InsightScheduleRecord(question: Self.question, minuteOfDay: 120, setAt: ZonedFields(date: Self.night.adding(days: -3) ?? Self.night, minuteOfDay: 0, second: 0))
    #expect(InsightSchedules.dueNight(of: schedule, at: ZonedFields(date: Self.night, minuteOfDay: 120, second: 0)) == Self.night)
    #expect(InsightSchedules.dueNight(of: schedule, at: ZonedFields(date: Self.night, minuteOfDay: 119, second: 59)) == Self.night.adding(days: -1))
    var paused = schedule
    paused.active = false
    #expect(InsightSchedules.dueNight(of: paused, at: Self.afterTwo) == nil)
  }

  @Test func shouldNeverRunANightWhoseMinuteHadPassedWhenTheScheduleWasSet() throws {
    let lateInTheDay = InsightScheduleRecord(question: Self.question, minuteOfDay: 120, setAt: ZonedFields(date: Self.night, minuteOfDay: 900, second: 0))
    #expect(InsightSchedules.dueNight(of: lateInTheDay, at: ZonedFields(date: Self.night, minuteOfDay: 960, second: 0)) == nil)
    #expect(InsightSchedules.dueNight(of: lateInTheDay, at: ZonedFields(date: Self.night.adding(days: 1) ?? Self.night, minuteOfDay: 119, second: 0)) == nil)
    #expect(InsightSchedules.dueNight(of: lateInTheDay, at: ZonedFields(date: Self.night.adding(days: 1) ?? Self.night, minuteOfDay: 120, second: 0)) == Self.night.adding(days: 1))
    let early = InsightScheduleRecord(question: Self.question, minuteOfDay: 120, setAt: ZonedFields(date: Self.night, minuteOfDay: 120, second: 0))
    #expect(InsightSchedules.dueNight(of: early, at: ZonedFields(date: Self.night, minuteOfDay: 120, second: 0)) == Self.night)
  }

  @Test func shouldRunNothingWhenTheScheduleIsSetAfterTonightsMinute() async throws {
    let harness = try InsightHarness()
    try await harness.grant()
    try await scheduled(harness, at: ZonedFields(date: Self.night, minuteOfDay: 900, second: 0))
    #expect(try await harness.engine.runDue(at: ZonedFields(date: Self.night, minuteOfDay: 901, second: 0)).label == "notScheduled")
    harness.provider.enqueueReply(InsightHarness.reply())
    let tomorrow = ZonedFields(date: Self.night.adding(days: 1) ?? Self.night, minuteOfDay: 125, second: 0)
    #expect(try await settled(try await harness.engine.runDue(at: tomorrow)) == .settled(.succeeded))
    #expect(harness.provider.requests.count == 1)
  }

  @Test func shouldWaitForTheSpendCapWithoutSpendingAnAttempt() async throws {
    let harness = try InsightHarness(limits: SpendLimits(daily: .zero))
    try await harness.grant()
    try await scheduled(harness)
    #expect(try await harness.engine.runDue(at: Self.afterTwo).label == "waitingForSpend")
    #expect(try await harness.engine.ask("how was my week?", id: MemoirStoreFixture.commandID(90)).label == "waitingForSpend")
    let jobs = try await harness.stores.main.read { transaction in try transaction.states(ofKind: JobSchema.jobKind, scope: .vault).count }
    #expect(jobs == 0)
    #expect(harness.provider.requests.isEmpty)
  }

  @Test func shouldWaitForTheCallConsentBeforeAnsweringAnAdHocQuestion() async throws {
    let harness = try InsightHarness()
    #expect(try await harness.engine.ask("how was my week?", id: MemoirStoreFixture.commandID(91)).label == "waitingForConsent")
    #expect(harness.provider.requests.isEmpty)
  }

  @Test func shouldRetryARoutingHoldWithoutCountingItTowardsTheLimit() async throws {
    let harness = try InsightHarness()
    try await harness.grant()
    try await scheduled(harness)
    let standing = InsightHarness.router(InsightHarness.origin, provider: harness.provider, store: harness.stores.main)
    let unconsented = InsightHarness.router(InsightHarness.otherOrigin, provider: harness.provider, store: harness.stores.main)
    for attempt in 1...(InsightEngine.maximumAttempts + 1) {
      harness.routers.enqueue([standing, unconsented])
      let result = try await settled(try await harness.engine.runDue(at: Self.afterTwo))
      guard case .settled(.failed(let failure)) = result else { throw MemoirFixtureError(description: "attempt \(attempt): \(result)") }
      #expect(failure.code == "routing.consent_required")
    }
    harness.provider.enqueueReply(InsightHarness.reply())
    #expect(try await settled(try await harness.engine.runDue(at: Self.afterTwo)) == .settled(.succeeded))
    #expect(harness.provider.requests.count == 1)
    #expect(try await harness.results().count == 1)
  }

  @Test func shouldEndAnAttemptWithoutACallWhenItsResultIsAlreadyStored() async throws {
    let harness = try InsightHarness()
    try await harness.grant()
    try await scheduled(harness)
    let job = try InsightJobAddress.key(.scheduled, target: .night(Self.night)).ref
    let stored = InsightRecord<HealthMetric>(
      id: InsightRecord<HealthMetric>.id(forJob: job), job: job.key.rawValue, question: Self.question, answer: "Stored before the crash.", patterns: [], suggestions: [],
      limitationNote: nil, citations: [.known(.health)], model: "model", promptVersion: InsightPrompt.version, createdMillis: 1)
    try await harness.stores.restricted.write { transaction in try stored.create(in: &transaction) }
    #expect(try await settled(try await harness.engine.runDue(at: Self.afterTwo)) == .settled(.succeeded))
    #expect(harness.provider.requests.isEmpty)
    #expect(try await harness.results().map(\.answer) == ["Stored before the crash."])
  }

  @Test func shouldResumeAnAttemptKilledAfterStoringItsResultWithoutAnotherCall() async throws {
    let harness = try InsightHarness(faults: crashing(once: .beforeCommit(step: 0)))
    try await harness.grant()
    try await scheduled(harness)
    harness.provider.enqueueReply(InsightHarness.reply())
    #expect(try await settled(try await harness.engine.runDue(at: Self.afterTwo)) == .interrupted)
    let resumed = try await harness.relaunched().resumeInterrupted()
    #expect(resumed.count == 1)
    for handle in resumed { #expect(await handle.result == .settled(.succeeded)) }
    #expect(harness.provider.requests.count == 1)
    #expect(try await harness.results().count == 1)
  }

  @Test func shouldResumeAnAttemptKilledDuringItsCallToExactlyOneResult() async throws {
    let harness = try InsightHarness(faults: crashing(once: .call(step: 0)))
    try await harness.grant()
    try await scheduled(harness)
    harness.provider.enqueueReply(InsightHarness.reply(answer: "First answer."))
    harness.provider.enqueueReply(InsightHarness.reply(answer: "Second answer."))
    #expect(try await settled(try await harness.engine.runDue(at: Self.afterTwo)) == .interrupted)
    let resumed = try await harness.relaunched().resumeInterrupted()
    for handle in resumed { #expect(await handle.result == .settled(.succeeded)) }
    #expect(resumed.count == 1)
    let results = try await harness.results()
    #expect(results.count == 1)
    #expect(results.first?.answer == "Second answer." || results.first?.answer == "First answer.")
    #expect((1...2).contains(harness.provider.requests.count))
  }

  @Test func shouldReadOnlyKeysTheAddressWrites() throws {
    let night = try InsightJobAddress.key(.scheduled, target: .night(Self.night))
    #expect(InsightJobAddress.kind(of: night) == .scheduled)
    #expect(InsightJobAddress.target(of: night) == .night(Self.night))
    #expect(night.scope == InsightJobAddress.scope && night.fingerprint == InsightPrompt.version)
    for target in ["date:2026-02-30", "date:2026-11-21 ", "question:0190F3A0-0000-7000-8000-0000000000C1", "chapter:3"] {
      #expect(InsightJobAddress.target(of: try JobKey(scope: InsightJobAddress.scope, kind: "insight_scheduled", target: target, fingerprint: "v1", run: 1)) == nil)
    }
    #expect(InsightJobAddress.kind(of: try JobKey(scope: "other", kind: "insight_scheduled", target: "date:2026-11-21", fingerprint: "v1", run: 1)) == nil)
  }

  @Test func shouldReplaceTheStandingQuestionAndRefuseAMinuteOutsideTheDay() async throws {
    let harness = try InsightHarness()
    try await scheduled(harness)
    try await scheduled(harness, question: "what changed this month?")
    let stored = try await harness.stores.main.read { transaction in try InsightScheduleRecord.read(key: .insightSchedule, in: transaction).entry?.record }
    #expect(stored == InsightScheduleRecord(question: "what changed this month?", setAt: Self.setBeforeTwo))
    for minute in [-1, 1440] {
      do {
        try await harness.stores.main.write { transaction in
          try InsightSchedules.set(InsightScheduleRecord(question: Self.question, minuteOfDay: minute, setAt: Self.setBeforeTwo), in: &transaction)
        }
        Issue.record("minute \(minute) was accepted")
      } catch {
        #expect(InsightError.converting(error).code == "insight.schedule_minute_out_of_range")
      }
    }
  }
}

actor RevokeOnce {
  private var harness: InsightHarness?
  private var done = false

  func set(_ harness: InsightHarness) {
    self.harness = harness
  }

  func run(_ includingText: Bool) async {
    guard includingText, !done, let harness else { return }
    done = true
    try? await harness.revoke(.journalReflectionReason)
  }
}
