import Foundation
import GRDB
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowText
import Testing

@testable import NovelForgeCore

private let unoffered = ["get_world_facts", "get_character_timeline", "get_review", "search_web", "fetch_page"]

private func call(_ tool: String, _ json: String? = nil) throws -> ChatLookupCall {
  ChatLookupCall(tool: tool, args: try parsedArguments(json))
}

private func run(_ store: VaultStore, _ calls: ChatLookupCall..., now: Date = Date(), counts: ChatLookupCounts = ChatLookupCounts()) async throws -> ChatLookupRound {
  var counts = counts
  return try await ChatLookupService(store: store, novel: readNovel, now: { now }).execute(calls, counts: &counts)
}

private struct UsageSeed: Sendable {
  let task: ModelTask
  let ago: Int64
  let outcome: ShadowAI.LedgerOutcome
  let cost: Cost?
  let source: LedgerCostSource
  let tokens: Int
}

private func richStore(allowingFaults: Bool = false) async throws -> VaultStore {
  try await ChatLookupWorlds.store(try #require(try ChatLookupFixture.load().worlds["rich"]), allowingFaults: allowingFaults)
}

@Suite("Chat lookups", TestTimeLimit.standard)
struct ChatLookupSpecTests {
  @Test(arguments: unoffered) func shouldRefuseALookupThisBuildDoesNotAnswer(_ tool: String) async throws {
    let round = try await run(try await richStore(), try call(tool, #"{"query":"x","chapter":1,"entityKey":"mara","category":"c","url":"https://example.com"}"#))
    #expect(round.text == "### \(tool)\nerror: unknown tool '\(tool)'")
    #expect(round.outcomes.first?.trace.audit == .invalidArgs)
    #expect(round.outcomes.first?.trace.status == .error)
  }

  @Test func shouldAdvertiseOnlyLookupsItAnswers() {
    let advertised = Set(chatScopeInstructions(ChatLookups.tools).jsMatchAll(ProseRegex.literal(#"\b(?:get|search)_[a-z_]+\b"#, "g")).map(\.text))
    let answered = Set(ChatLookupName.allCases.map(\.rawValue))
    #expect(advertised.isSubset(of: answered), "advertised but unanswered: \(advertised.subtracting(answered).sorted())")
    #expect(answered.isSubset(of: advertised.union(["get_plot_threads", "get_chapter_summaries", "get_usage"])))
    #expect(Set(ChatLookups.tools.map(\.name)) == answered)
  }

  @Test func shouldKeepCallBudgetsAcrossRoundsOfATurn() async throws {
    let store = try await richStore()
    var counts = ChatLookupCounts()
    let service = ChatLookupService(store: store, novel: readNovel)
    let first = try await service.execute([try call("get_draft", #"{"chapter":1}"#), try call("get_draft", #"{"chapter":1}"#)], counts: &counts)
    #expect(first.outcomes.map(\.trace.audit) == [.ok, .ok])
    let second = try await service.execute([try call("get_draft", #"{"chapter":1}"#), try call("get_volume", #"{"volumeKey":"one"}"#)], counts: &counts)
    #expect(second.outcomes.map(\.trace.audit) == [.budgetExceeded, .ok])
    #expect(second.text.hasPrefix("### get_draft\nerror: tool 'get_draft' has exceeded its call budget for this turn"))
  }

  @Test func shouldCountARefusedCallAgainstItsToolsBudget() async throws {
    let store = try await richStore()
    var counts = ChatLookupCounts()
    let service = ChatLookupService(store: store, novel: readNovel)
    _ = try await service.execute([try call("get_draft", #"{"chapter":0}"#), try call("get_draft", nil)], counts: &counts)
    let round = try await service.execute([try call("get_draft", #"{"chapter":1}"#)], counts: &counts)
    #expect(round.outcomes.map(\.trace.audit) == [.budgetExceeded])
  }

  @Test func shouldReadAbsentArgumentsAsAnEmptyObject() async throws {
    let round = try await run(try await richStore(), try call("get_plot_threads"), try call("get_brief"))
    #expect(round.outcomes.map(\.trace.audit) == [.ok, .invalidArgs])
    #expect(round.text.hasSuffix("### get_brief\nerror: chapter: Required"))
  }

  @Test func shouldMarkPlannerOnlyReadsOnlyForNotesAndPlannerPages() async throws {
    let store = try await richStore()
    #expect(try await run(store, try call("get_notes")).readsPlannerOnly)
    #expect(try await run(store, try call("get_bible_document", #"{"section":"project","slug":"timeline"}"#)).readsPlannerOnly)
    #expect(try await run(store, try call("get_bible_document", #"{"section":"project","slug":"open-questions"}"#)).readsPlannerOnly)
    #expect(try await !run(store, try call("get_bible_document", #"{"section":"project","slug":"overview"}"#)).readsPlannerOnly)
    #expect(try await !run(store, try call("get_brief", #"{"chapter":1}"#), try call("get_notes", #"{"from":0}"#)).readsPlannerOnly)
    #expect(try await !run(store, try call("get_draft", #"{"chapter":1}"#)).readsPlannerOnly)
  }

  @Test func shouldTraceWhatAnswerWasGivenAndHowLargeWithoutTheResult() async throws {
    let round = try await run(
      try await richStore(), try call("get_draft", #"{"chapter":11}"#), try call("get_volume", #"{"volumeKey":"one"}"#), try call("get_volume", #"{"volumeKey":"x","extra":1}"#))
    let trace = round.outcomes.map(\.trace)
    #expect(trace[0].truncated)
    #expect(trace[0].resultCharacters == 10_000 * 4 + "\n...[truncated]".count)
    #expect(trace[0].args["chapter"] == .count(11))
    #expect(!trace[1].truncated)
    #expect(trace[1].args["volumeKey"] == .text("one"))
    #expect(trace[2].args["extra"] == nil)
  }

  @Test func shouldReadAnUndisclosedSecretAsLockedWhenTheDisclosureIsFaulted() async throws {
    let store = try await richStore(allowingFaults: true)
    let before = try await run(store, try call("get_canon_facts", #"{"keys":["heir"]}"#))
    #expect(before.text.contains("Reader knows since ch 1"))
    try await ReadWorld.insertFault(ReaderDisclosureEntry.databaseTableName, key: ProjectionFaults.wholeDerivation, in: store)
    let after = try await run(store, try call("get_canon_facts", #"{"keys":["heir"]}"#))
    #expect(!after.text.contains("Reader knows since"))
    #expect(after.text.contains("Unlocks: chapter 4 or later"))
    #expect(after.outcomes.map(\.trace.audit) == [.ok])
  }

  @Test func shouldSayThePlannedRevealIsUnavailableWhenThePlanWorldIsFaulted() async throws {
    let store = try await richStore(allowingFaults: true)
    try await ReadWorld.insertFault(PlanWorldEntry.databaseTableName, key: ProjectionFaults.wholeDerivation, in: store)
    let round = try await run(store, try call("get_canon_facts", #"{"keys":["heir","secret_a"]}"#))
    #expect(round.text.contains("Planned reveal: (not available)"))
    #expect(!round.text.contains("Planned reveal: ch"))
  }

  @Test func shouldSayTheReviewIsUnavailableWhenTheChapterLifecycleIsFaulted() async throws {
    let store = try await richStore(allowingFaults: true)
    try await ReadWorld.insertFault(ChapterLifecycleEntry.databaseTableName, key: ProjectionFaults.wholeDerivation, in: store)
    let round = try await run(store, try call("get_draft", #"{"chapter":8}"#))
    #expect(round.text.hasPrefix("### get_draft\n**Chapter 8**: (untitled) ((not available), rev 8, review: (not available))\nWords: "))
    #expect(round.outcomes.map(\.trace.audit) == [.ok])
  }

  @Test func shouldFailOnlyTheLookupWhoseReadIsFaulted() async throws {
    let store = try await richStore(allowingFaults: true)
    try await ReadWorld.insertFault(IndexedRecord.databaseTableName, key: ProjectionFaults.wholeDerivation, in: store)
    let round = try await run(store, try call("get_plot_threads"), try call("get_volume", #"{"volumeKey":"one"}"#))
    #expect(round.text.hasPrefix("### get_plot_threads\nerror: lookup failed\n\n### get_volume\n**one**:"))
    #expect(round.outcomes.map(\.trace.audit) == [.handlerError, .ok])
    #expect(round.outcomes.map(\.trace.status) == [.error, .ok])
  }

  @Test func shouldFailTheLookupOfARecordThisVersionCannotRead() async throws {
    let store = try await richStore()
    let volume = VolumeRecord(novel: readNovel, volume: "broken", ordinal: 1)
    var members = volume.storedMembers
    members["ordinal"] = .string("one")
    try await SchemaFixture.set(volume.ref, members, in: store)
    let round = try await run(store, try call("get_volume", #"{"volumeKey":"broken"}"#), try call("get_volume", #"{"volumeKey":"one"}"#))
    #expect(round.outcomes.map(\.trace.audit) == [.handlerError, .ok])
    #expect(round.text.hasPrefix("### get_volume\nerror: lookup failed"))
  }

  @Test func shouldReadRemovedRecordsAsMissing() async throws {
    let store = try await richStore()
    try await ReadWorld.write(store) { transaction in
      _ = try PageRecord.remove(novel: readNovel, section: .world, slug: "places", in: &transaction)
      _ = try EntityRecord.remove(novel: readNovel, entity: "mara", in: &transaction)
      _ = try SecretRecord.remove(novel: readNovel, secret: "heir", in: &transaction)
    }
    let round = try await run(
      store, try call("get_bible_document", #"{"section":"world","slug":"places"}"#), try call("get_entity", #"{"entityKey":"mara"}"#),
      try call("get_canon_facts", #"{"keys":["heir"]}"#))
    #expect(round.text.contains("Bible document not found: world/places"))
    #expect(round.text.contains("Entity not found: mara"))
    #expect(round.text.hasSuffix("Not found: heir"))
  }

  @Test func shouldFindARecordByEitherNormalisationOfItsKey() async throws {
    let store = try await richStore()
    let decomposed = "ünï".precomposedStringWithCanonicalMapping.decomposedStringWithCanonicalMapping
    let round = try await run(store, try call("get_entity", #"{"entityKey":"\#(decomposed)"}"#))
    #expect(round.text.contains("**Ünï** (faction, active)"))
  }

  @Test func shouldCutAResultOnAUTF16CountAndNeverSplitASurrogatePair() async throws {
    let round = try await run(try await richStore(), try call("get_bible_document", #"{"section":"lore","slug":"huge"}"#))
    let result = try #require(round.outcomes.first?.result)
    #expect(result.hasSuffix("\n...[truncated]"))
    #expect(result.jsLength == 6_000 * 4 - 1 + "\n...[truncated]".jsLength)
  }

  @Test func shouldReportUsageFromTheLedgerWithoutWhatItDoesNotRecord() async throws {
    let store = try ReadWorld.store()
    let now = Date(timeIntervalSince1970: 1_000_000)
    let hour: Int64 = 3_600_000
    let started = Int64(now.timeIntervalSince1970 * 1_000)
    try await ReadWorld.write(store) { transaction in
      let entries = [
        UsageSeed(task: .writing, ago: 2 * hour, outcome: .finished, cost: Cost(nanoUSD: 2_000_000_000), source: .reported, tokens: 1_000),
        UsageSeed(task: .chat, ago: 30 * hour, outcome: .finished, cost: Cost(nanoUSD: 40_000_000), source: .computed, tokens: 2_000),
        UsageSeed(task: .chat, ago: 10 * 24 * hour, outcome: .finished, cost: nil, source: .pending, tokens: 3_000),
        UsageSeed(task: .review, ago: 40 * 24 * hour, outcome: .failed, cost: Cost.zero, source: .computed, tokens: 0),
      ]
      for seed in entries {
        let entry = ModelCallEntry(
          id: UUID(), provider: "api.anthropic.com", model: "m", task: seed.task, pace: nil, startedMillis: started - seed.ago, outcome: seed.outcome,
          usage: TokenUsage(input: seed.tokens, output: seed.tokens / 10), cost: seed.cost, costSource: seed.source)
        try Ledger.open(entry, in: &transaction)
      }
    }
    let today = try await run(store, try call("get_usage", #"{"period":"today"}"#), now: now)
    #expect(today.text == "### get_usage\nUsage for the last 24 hours: 1 calls, 1,100 tokens (1,000 in / 100 out), $2.00.\nFully recorded — no estimate involved.")
    let week = try await run(store, try call("get_usage", #"{"period":"week"}"#), now: now)
    #expect(week.text.contains("2 calls, 3,300 tokens (3,000 in / 300 out), $2.04."))
    #expect(week.text.contains("Some of this figure is estimated"))
    #expect(week.text.hasSuffix("By role:\n- writing: 1 calls, $2.00\n- chat: 1 calls, $0.04"))
    let month = try await run(store, try call("get_usage", #"{"period":"month"}"#), now: now)
    #expect(month.text.contains("3 calls"))
    #expect(month.text.contains("Some of this figure is estimated"))
    let all = try await run(store, try call("get_usage"), now: now)
    #expect(all.text.contains("4 calls"))
    #expect(all.text.contains("- chat: 2 calls, $0.04"))
  }

  @Test(arguments: [0, 1]) func shouldCutOnlyAResultLongerThanTheBudget(_ extra: Int) async throws {
    let store = try ReadWorld.store()
    let header = "**v**: (untitled) (ordinal 1)\n"
    let body = String(repeating: "a", count: 2_000 * 4 - header.jsLength + extra)
    try await ReadWorld.write(store) { transaction in _ = try VolumeRecord(novel: readNovel, volume: "v", ordinal: 1, body: body).create(in: &transaction) }
    let outcome = try #require(try await run(store, try call("get_volume", #"{"volumeKey":"v"}"#)).outcomes.first)
    #expect(outcome.trace.truncated == (extra == 1))
    #expect(outcome.result.hasSuffix("\n...[truncated]") == (extra == 1))
    #expect(outcome.trace.resultCharacters == (extra == 0 ? 8_000 : 8_000 + "\n...[truncated]".jsLength))
  }

  @Test func shouldSayWhatTheLedgerCannotScope() async throws {
    let store = try ReadWorld.store()
    let round = try await run(store, try call("get_usage", #"{"chapter":3}"#), try call("get_usage", #"{"last_run":true}"#), try call("get_usage", #"{"last_run":false}"#))
    #expect(round.outcomes.map(\.trace.audit) == [.ok, .ok, .ok])
    #expect(round.text.contains("records no chapter, so usage cannot be scoped to chapter 3."))
    #expect(round.text.contains("does not group calls into runs"))
    #expect(round.text.hasSuffix("### get_usage\nNo usage recorded for all time."))
  }

  @Test func shouldPublishAJSONSchemaWhosePropertiesAreTheArguments() throws {
    for definition in ChatLookups.definitions {
      let properties = try #require(definition.schema.objectValue?["properties"]?.objectValue).keys
      #expect(properties == (definition.arguments ?? ["from", "to"]))
      #expect(definition.schema.objectValue?["type"]?.stringValue == "object")
    }
  }
}
