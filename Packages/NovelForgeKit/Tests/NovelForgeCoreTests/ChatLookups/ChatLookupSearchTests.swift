import Foundation
import ShadowStore
import Testing

@testable import NovelForgeCore

private func call(_ tool: String, _ json: String? = nil) throws -> ChatLookupCall {
  ChatLookupCall(tool: tool, args: try parsedArguments(json))
}

private func lookups(_ world: RetrievalWorld, embedders: (any EmbedderProvider)? = nil) -> ChatLookupService {
  ChatLookupService(store: world.store, novel: world.novel, embedders: embedders)
}

private func run(_ world: RetrievalWorld, _ calls: ChatLookupCall..., counts: ChatLookupCounts = ChatLookupCounts()) async throws -> ChatLookupRound {
  var counts = counts
  return try await lookups(world).execute(calls, counts: &counts)
}

private func errors(_ name: ChatLookupName, _ json: String) throws -> String {
  let arguments = try #require(try parsedArguments(json))
  do throws(ChatLookupArgumentError) {
    _ = try name.parse(arguments)
    return ""
  } catch {
    return error.text
  }
}

@Suite("Chat lookup arguments for search_lore and search_prose", TestTimeLimit.quick)
struct ChatLookupSearchArgumentTests {
  @Test func shouldReadAQueryAloneAndStripUnknownKeys() throws {
    #expect(try ChatLookupName.searchLore.parse(try #require(try parsedArguments(#"{"query":"x","extra":1}"#))) == .searchLore(query: "x", kinds: nil))
    #expect(try ChatLookupName.searchProse.parse(try #require(try parsedArguments(#"{"query":"x","extra":1}"#))) == .searchProse(query: "x", k: nil))
    #expect(try ChatLookupName.searchLore.parse(try #require(try parsedArguments(#"{"query":""}"#))) == .searchLore(query: "", kinds: nil))
  }

  @Test(arguments: [
    (#"{}"#, "error: query: Required"),
    (#"{"query":5}"#, "error: query: Expected string, received number"),
    (#"{"query":null}"#, "error: query: Expected string, received null"),
    (#"{"query":"x","kinds":"character"}"#, "error: kinds: Expected array, received string"),
    (#"{"query":"x","kinds":null}"#, "error: kinds: Expected array, received null"),
    (#"{"query":"x","kinds":["character",7]}"#, "error: kinds.1: Expected string, received number"),
    (#"{"query":"x","kinds":["bible doc"]}"#, "error: kinds.0: Invalid"),
    (#"{"query":"x","kinds":[""]}"#, "error: kinds.0: Invalid"),
    (#"{"query":"x","kinds":["a-b","ok","é"]}"#, "error: kinds.0: Invalid; kinds.2: Invalid"),
    (#"{"query":"x","kinds":["character\n"]}"#, "error: kinds.0: Invalid"),
    (#"{"kinds":["no way"]}"#, "error: kinds.0: Invalid; query: Required"),
  ]) func shouldRefuseBadSearchLoreArgumentsAsTheSchemaDoes(_ json: String, _ expected: String) throws {
    #expect(try errors(.searchLore, json) == expected)
  }

  @Test func shouldTakeKindsOfAnyCaseUpToSixtyFourCharactersAndNoMoreThanSixteenOfThem() throws {
    let longest = String(repeating: "a", count: 64)
    #expect(try errors(.searchLore, #"{"query":"x","kinds":["Character_1","BIBLE_DOC","\#(longest)"]}"#) == "")
    #expect(try errors(.searchLore, #"{"query":"x","kinds":["\#(longest)a"]}"#) == "error: kinds.0: Invalid")
    #expect(try errors(.searchLore, #"{"query":"x","kinds":[]}"#) == "")
    let sixteen = (0..<16).map { "\"k\($0)\"" }.joined(separator: ",")
    #expect(try errors(.searchLore, #"{"query":"x","kinds":[\#(sixteen)]}"#) == "")
    #expect(try errors(.searchLore, #"{"query":"x","kinds":[\#(sixteen),"k16"]}"#) == "error: kinds: Array must contain at most 16 element(s)")
  }

  @Test(arguments: [
    (#"{"query":"x","k":0}"#, "error: k: Number must be greater than or equal to 1"),
    (#"{"query":"x","k":9}"#, "error: k: Number must be less than or equal to 8"),
    (#"{"query":"x","k":1.5}"#, "error: k: Expected integer, received float"),
    (#"{"query":"x","k":0.5}"#, "error: k: Expected integer, received float; k: Number must be greater than or equal to 1"),
    (#"{"query":"x","k":8.5}"#, "error: k: Expected integer, received float; k: Number must be less than or equal to 8"),
    (#"{"query":"x","k":"3"}"#, "error: k: Expected number, received string"),
    (#"{"query":"x","k":null}"#, "error: k: Expected number, received null"),
    (#"{"k":-1}"#, "error: k: Number must be greater than or equal to 1; query: Required"),
  ]) func shouldRefuseBadSearchProseArgumentsAsTheSchemaDoes(_ json: String, _ expected: String) throws {
    #expect(try errors(.searchProse, json) == expected)
  }

  @Test(arguments: [1, 5, 8]) func shouldTakeAnyKFromOneToEight(_ k: Int) throws {
    #expect(try ChatLookupName.searchProse.parse(try #require(try parsedArguments(#"{"query":"x","k":\#(k)}"#))) == .searchProse(query: "x", k: k))
    #expect(try ChatLookupName.searchProse.parse(try #require(try parsedArguments(#"{"query":"x","k":\#(k).0}"#))) == .searchProse(query: "x", k: k))
  }
}

@Suite("Chat lookups search_lore and search_prose", TestTimeLimit.standard)
struct ChatLookupSearchTests {
  @Test func shouldAnswerLoreAsKindRefKeyAndTextLines() async throws {
    let world = try RetrievalWorld()
    try await world.entity("mara", name: "Mara", notes: "A thief on the Saltgate docks.")
    try await world.page(.world, "saltgate", "Saltgate is the harbour where thieves meet.")
    let round = try await run(world, try call("search_lore", #"{"query":"thieves docks"}"#))
    #expect(round.outcomes.map(\.trace.audit) == [.ok])
    #expect(round.text == "### search_lore\nbible_doc:world/saltgate — Saltgate is the harbour where thieves meet.\ncharacter:mara — Mara\nA thief on the Saltgate docks.")
  }

  @Test func shouldFilterLoreByKindsAndMatchTheirCaseExactlyAsTheReferenceDoes() async throws {
    let world = try RetrievalWorld()
    try await world.entity("mara", name: "Mara", notes: "A thief on the docks.")
    try await world.page(.world, "docks", "The docks are loud.")
    let characters = try await run(world, try call("search_lore", #"{"query":"docks","kinds":["character"]}"#))
    #expect(characters.text == "### search_lore\ncharacter:mara — Mara\nA thief on the docks.")
    let both = try await run(world, try call("search_lore", #"{"query":"docks","kinds":[]}"#))
    #expect(both.text.contains("character:mara") && both.text.contains("bible_doc:world/docks"))
    let upper = try await run(world, try call("search_lore", #"{"query":"docks","kinds":["CHARACTER"]}"#))
    #expect(upper.text == "### search_lore\nNo lore found.")
  }

  @Test func shouldSayNoLoreWasFoundWhenNothingMatchesOrTheQueryHasNoTerms() async throws {
    let world = try RetrievalWorld()
    try await world.entity("mara", name: "Mara", notes: "A thief.")
    let round = try await run(world, try call("search_lore", #"{"query":"submarine"}"#), try call("search_lore", #"{"query":"  "}"#), try call("search_lore", #"{"query":""}"#))
    #expect(round.text == "### search_lore\nNo lore found.\n\n### search_lore\nNo lore found.\n\n### search_lore\nNo lore found.")
    #expect(round.outcomes.map(\.trace.audit) == [.ok, .ok, .ok])
  }

  @Test func shouldReturnAtMostSixLoreHits() async throws {
    let world = try RetrievalWorld()
    for index in 0..<9 { try await world.entity("sailor\(index)", name: "Sailor \(index)", notes: "Sails the northern sea.") }
    let round = try await run(world, try call("search_lore", #"{"query":"sea"}"#))
    #expect(round.text.jsSplit("\n").count == 1 + 6 * 2)
  }

  @Test func shouldAnswerProseAsChapterTaggedPassagesJoinedByRules() async throws {
    let world = try RetrievalWorld()
    try await world.finalize(1, "The lantern burned red over the harbour.")
    try await world.finalize(2, "A red lantern hung from the mast.")
    let round = try await run(world, try call("search_prose", #"{"query":"red lantern"}"#))
    let blocks = round.text.jsSplit("\n---\n")
    #expect(blocks.count == 2)
    #expect(blocks.first?.hasPrefix("### search_prose\n[Ch ") == true)
    #expect(Set(blocks.map { $0.jsSplit("]")[0].jsSplit("[Ch ").last ?? "" }) == ["1", "2"])
    #expect(blocks.last?.hasPrefix("[Ch ") == true)
  }

  @Test func shouldSayNoProseWasFoundWhenNothingMatches() async throws {
    let world = try RetrievalWorld()
    try await world.finalize(1, "The lantern burned.")
    let round = try await run(world, try call("search_prose", #"{"query":"submarine"}"#), try call("search_prose", #"{"query":"%%%"}"#))
    #expect(round.text == "### search_prose\nNo prose found.\n\n### search_prose\nNo prose found.")
  }

  @Test func shouldAnswerFiveProsePassagesByDefaultAndTheRequestedNumberUpToEight() async throws {
    let world = try RetrievalWorld()
    for chapter in 1...9 { try await world.finalize(chapter, "The beacon of chapter \(chapter) burned over the cliffs.") }
    let defaulted = try await run(world, try call("search_prose", #"{"query":"beacon"}"#))
    let two = try await run(world, try call("search_prose", #"{"query":"beacon","k":2}"#))
    let eight = try await run(world, try call("search_prose", #"{"query":"beacon","k":8}"#))
    #expect([defaulted, two, eight].map { $0.text.jsSplit("\n---\n").count } == [5, 2, 8])
  }

  @Test func shouldNotFindASentenceAnAmendRemovedBecauseItCatchesUpFirst() async throws {
    let world = try RetrievalWorld()
    try await world.finalize(1, "The lantern burned red. A heron called from the reeds.")
    let service = lookups(world)
    var counts = ChatLookupCounts()
    let before = try await service.execute([try call("search_prose", #"{"query":"heron reeds"}"#)], counts: &counts)
    #expect(before.text.contains("heron"))
    try await world.amend(1, "The lantern burned red.")
    let after = try await service.execute([try call("search_prose", #"{"query":"heron reeds"}"#)], counts: &counts)
    #expect(after.text == "### search_prose\nNo prose found.")
  }

  @Test func shouldNotFindLoreOfARemovedEntityOrAnEditedPage() async throws {
    let world = try RetrievalWorld()
    try await world.entity("mara", name: "Mara", notes: "A thief.")
    try await world.page(.world, "docks", "The docks are loud.")
    let service = lookups(world)
    var counts = ChatLookupCounts()
    #expect(try await service.execute([try call("search_lore", #"{"query":"thief loud"}"#)], counts: &counts).text.contains("character:mara"))
    try await world.removeEntity("mara")
    try await world.page(.world, "docks", "The docks are quiet.")
    let after = try await service.execute([try call("search_lore", #"{"query":"thief loud"}"#)], counts: &counts)
    #expect(after.text == "### search_lore\nNo lore found.")
  }

  @Test func shouldNeverReturnTheProseOfAnIsolatedChapterOrOfOneIsolatedAfterItWasIndexed() async throws {
    let world = try RetrievalWorld()
    try await world.finalize(1, "The comet crossed the open sky.")
    try await world.finalize(2, "The comet crossed the walled sky.", isolated: true)
    try await world.finalize(3, "The comet crossed the late sky.")
    let service = lookups(world)
    var counts = ChatLookupCounts()
    let first = try await service.execute([try call("search_prose", #"{"query":"comet sky","k":8}"#)], counts: &counts)
    #expect(first.text.contains("open sky") && first.text.contains("late sky") && !first.text.contains("walled"))
    try await world.draft(3, isolated: true)
    let second = try await service.execute([try call("search_prose", #"{"query":"comet sky","k":8}"#)], counts: &counts)
    #expect(second.text.contains("open sky") && !second.text.contains("late sky") && !second.text.contains("walled"))
  }

  @Test func shouldFindByMeaningWhenTheInjectedEmbedderHasVectorsAndOnlyByWordsWithoutOne() async throws {
    let world = try RetrievalWorld(embedder: FakeEmbedder())
    try await world.finalize(1, "The ship left the harbour at dawn.")
    try await world.retrieval.catchUp(novel: world.novel)
    try await world.retrieval.embedPending(novel: world.novel)
    var counts = ChatLookupCounts()
    let semantic = try await lookups(world, embedders: world.embedders).execute([try call("search_prose", #"{"query":"vessel"}"#)], counts: &counts)
    #expect(semantic.text == "### search_prose\n[Ch 1] The ship left the harbour at dawn.")
    let lexical = try await lookups(world, embedders: nil).execute([try call("search_prose", #"{"query":"vessel"}"#)], counts: &counts)
    #expect(lexical.text == "### search_prose\nNo prose found.")
  }

  @Test func shouldAnswerNoResultsWhenTheRecordIndexIsFaultedAndTheIndexCannotBeCaughtUp() async throws {
    let world = try RetrievalWorld()
    try await world.finalize(1, "Dust on the road.")
    try await world.retrieval.catchUp(novel: world.novel)
    try await world.finalize(2, "More dust.")
    try await ReadWorld.insertFault(IndexedRecord.databaseTableName, key: ProjectionFaults.wholeDerivation, in: world.store)
    let round = try await run(world, try call("search_prose", #"{"query":"dust"}"#), try call("search_lore", #"{"query":"dust"}"#))
    #expect(round.text == "### search_prose\nNo prose found.\n\n### search_lore\nNo lore found.")
    #expect(round.outcomes.map(\.trace.audit) == [.ok, .ok])
  }

  @Test func shouldPropagateACancelledTurnInsteadOfAnsweringNothingFound() async throws {
    let world = try RetrievalWorld()
    try await world.finalize(1, "Dust on the road.")
    let service = lookups(world)
    let call = try call("search_prose", #"{"query":"dust"}"#)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      var counts = ChatLookupCounts()
      return try await service.execute([call], counts: &counts)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  @Test func shouldRefuseBadArgumentsWithTheSchemaIssues() async throws {
    let world = try RetrievalWorld()
    let round = try await run(world, try call("search_lore", #"{"kinds":["no way"]}"#), try call("search_prose", #"{"query":"x","k":99}"#), try call("search_prose"))
    #expect(
      round.text
        == "### search_lore\nerror: kinds.0: Invalid; query: Required\n\n### search_prose\nerror: k: Number must be less than or equal to 8\n\n### search_prose\nerror: query: Required"
    )
    #expect(round.outcomes.map(\.trace.audit) == [.invalidArgs, .invalidArgs, .invalidArgs])
    #expect(round.outcomes.map(\.trace.status) == [.error, .error, .error])
  }

  @Test func shouldCountARefusedSearchAgainstItsBudget() async throws {
    let world = try RetrievalWorld()
    var counts = ChatLookupCounts()
    let service = lookups(world)
    let refused = try await service.execute(Array(repeating: try call("search_prose"), count: 8), counts: &counts)
    #expect(refused.outcomes.allSatisfy { $0.trace.audit == .invalidArgs })
    let valid = try await service.execute([try call("search_prose", #"{"query":"x"}"#)], counts: &counts)
    #expect(valid.outcomes.map(\.trace.audit) == [.budgetExceeded])
  }

  @Test func shouldHoldTheCallBudgetsOfTheReferenceAcrossRounds() async throws {
    let world = try RetrievalWorld()
    try await world.finalize(1, "Dust on the road.")
    let service = lookups(world)
    var counts = ChatLookupCounts()
    let lore = try call("search_lore", #"{"query":"dust"}"#)
    let prose = try call("search_prose", #"{"query":"dust"}"#)
    let first = try await service.execute(Array(repeating: lore, count: 10) + Array(repeating: prose, count: 8), counts: &counts)
    #expect(first.outcomes.allSatisfy { $0.trace.audit == .ok })
    let second = try await service.execute([lore, prose], counts: &counts)
    #expect(second.outcomes.map(\.trace.audit) == [.budgetExceeded, .budgetExceeded])
    #expect(
      second.text
        == "### search_lore\nerror: tool 'search_lore' has exceeded its call budget for this turn\n\n### search_prose\nerror: tool 'search_prose' has exceeded its call budget for this turn"
    )
  }

  @Test func shouldTruncateAnAnswerAtTheTokenBudgetAndSayHowLargeItWas() async throws {
    let world = try RetrievalWorld()
    try await world.entity("saga", name: "Saga", body: "epic " + String(repeating: "word ", count: 6_000))
    let round = try await run(world, try call("search_lore", #"{"query":"epic"}"#))
    let trace = try #require(round.outcomes.first?.trace)
    #expect(trace.truncated && trace.audit == .ok)
    #expect(round.text.hasSuffix("\n...[truncated]"))
    #expect(trace.resultCharacters == 4_000 * 4 + "\n...[truncated]".count)
  }

  @Test func shouldTraceTheQueryAndNothingOfTheResult() async throws {
    let world = try RetrievalWorld()
    try await world.finalize(1, "Dust on the road.")
    let round = try await run(world, try call("search_lore", #"{"query":"  dust  ","kinds":["character"]}"#), try call("search_prose", #"{"query":"road","k":3}"#))
    #expect(round.outcomes.map(\.trace.args.entries.count) == [1, 1])
    #expect(round.outcomes[0].trace.args["query"] == .text("dust"))
    #expect(round.outcomes[1].trace.args["query"] == .text("road"))
    #expect(round.outcomes.map(\.readsPlannerOnly) == [false, false])
  }

  @Test func shouldAnswerALookupRoundOfSearchesAndOtherLookupsInTheModelsOrder() async throws {
    let world = try RetrievalWorld()
    try await world.entity("mara", name: "Mara", notes: "A thief.")
    let round = try await run(world, try call("get_entity", #"{"entityKey":"mara"}"#), try call("search_lore", #"{"query":"thief"}"#), try call("nope"))
    #expect(round.outcomes.map(\.trace.tool) == ["get_entity", "search_lore", "nope"])
    #expect(round.text.hasPrefix("### get_entity\n**Mara**"))
    #expect(round.text.contains("### search_lore\ncharacter:mara — Mara\nA thief."))
    #expect(round.text.hasSuffix("### nope\nerror: unknown tool 'nope'"))
  }
}
