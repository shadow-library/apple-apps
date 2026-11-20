import Foundation
import GRDB
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

@Suite("Retrieval embeddings", TestTimeLimit.standard)
struct RetrievalEmbeddingTests {
  private static func unit(_ values: [Float], dimension: Int = 16) -> [Float] {
    values + Array(repeating: 0, count: dimension - values.count)
  }

  @Test func shouldEncodeVectorsAsLittleEndianFloat32AndRejectBlobsOfAnotherLength() {
    let encoded = RetrievalVectors.encode([1, -2])
    #expect(Array(encoded) == [0x00, 0x00, 0x80, 0x3F, 0x00, 0x00, 0x00, 0xC0])
    var buffer = [Float](repeating: 0, count: 2)
    #expect(RetrievalVectors.decode(encoded, into: &buffer))
    #expect(buffer == [1, -2])
    var wider = [Float](repeating: 0, count: 3)
    #expect(!RetrievalVectors.decode(encoded, into: &wider))
    #expect(!RetrievalVectors.decode(encoded.dropLast(), into: &buffer))
    #expect(RetrievalVectors.unit([3, 4], dimension: 2) == [0.6, 0.8])
    #expect(RetrievalVectors.unit([0, 0], dimension: 2) == nil)
    #expect(RetrievalVectors.unit([.infinity, 0], dimension: 2) == nil)
    #expect(RetrievalVectors.unit([1, 1, 1], dimension: 2) == nil)
  }

  @Test func shouldStoreOneUnitVectorPerRowWithItsModelAndEmbedNothingTwice() async throws {
    let embedder = FakeEmbedder()
    let world = try RetrievalWorld(embedder: embedder)
    try await world.finalize(1, "The ship left the harbour.")
    try await world.entity("mara", name: "Mara", notes: "Keeps the lamp.")
    try await world.page(.world, "harbour", "Boats and nets.")
    try await world.retrieval.catchUp(novel: world.novel)

    let outcome = try await world.retrieval.embedPending(novel: world.novel)
    #expect(outcome == RetrievalEmbedding(model: "fake/a", embedded: 3))
    let stored = try await world.vectors()
    #expect(stored.count == 3)
    for row in stored {
      #expect(row.model == "fake/a" && row.novel == world.novel)
      let blob = try #require(row.vector)
      var values = [Float](repeating: 0, count: embedder.dimension)
      #expect(RetrievalVectors.decode(blob, into: &values))
      #expect(abs(values.reduce(0) { $0 + $1 * $1 } - 1) < 1e-5)
    }

    let calls = await embedder.calls.count
    #expect(try await world.retrieval.embedPending(novel: world.novel) == RetrievalEmbedding(model: "fake/a"))
    #expect(await embedder.calls.count == calls)
  }

  @Test func shouldEmbedTheQueryWithTheStoredModelWithoutReadingASampleAgain() async throws {
    let embedders = FakeEmbedders(embedder: FakeEmbedder())
    let world = try RetrievalWorld()
    let retrieval = NovelRetrieval(store: world.store, embedders: embedders)
    try await world.finalize(1, "The tempest broke the mast.")
    try await retrieval.catchUp(novel: world.novel)
    #expect(try await retrieval.searchProse(novel: world.novel, query: "storm").isEmpty)
    #expect(embedders.sampleRequests == 0)

    try await retrieval.embedPending(novel: world.novel)
    #expect(embedders.sampleRequests == 1)
    #expect(try await retrieval.searchProse(novel: world.novel, query: "storm").map(\.origin) == [.prose(chapter: 1)])
    #expect(try await retrieval.searchProseAndLore(novel: world.novel, query: "gale").prose.count == 1)
    #expect(embedders.sampleRequests == 1)

    let stale = NovelRetrieval(store: world.store, embedders: FakeEmbedders(embedder: FakeEmbedder(model: "fake/a2")))
    #expect(try await stale.searchProse(novel: world.novel, query: "storm").isEmpty)
  }

  @Test func shouldDoNothingWithoutAModelOrBeforeTheFirstCatchUp() async throws {
    let plain = try RetrievalWorld()
    try await plain.finalize(1, "Fog on the moor.")
    try await plain.retrieval.catchUp(novel: plain.novel)
    #expect(try await plain.retrieval.embedPending(novel: plain.novel) == RetrievalEmbedding(model: nil))
    #expect(try await plain.vectors().isEmpty)

    let embedder = FakeEmbedder()
    let early = try RetrievalWorld(embedder: embedder)
    try await early.finalize(1, "Fog on the moor.")
    #expect(try await early.retrieval.embedPending(novel: early.novel) == RetrievalEmbedding(model: "fake/a"))
    #expect(try await early.rowCounts().isEmpty)
    #expect(await embedder.calls.isEmpty)
  }

  @Test func shouldRemoveVectorsWithTheirRowsOnAmendRemovalAndForget() async throws {
    let world = try RetrievalWorld(embedder: FakeEmbedder())
    let long = (0..<60).map { "Paragraph \($0) of the chapter, with the heron standing in the reeds." }.joined(separator: "\n\n")
    try await world.finalize(1, long)
    try await world.entity("mara", name: "Mara", notes: "Keeper.")
    try await world.entity("ivo", name: "Ivo", notes: "Ferryman.")
    try await world.finalize(1, "Snow in the other book.", novel: RetrievalWorld.otherNovel)
    try await world.retrieval.catchUp(novel: world.novel)
    try await world.retrieval.catchUp(novel: RetrievalWorld.otherNovel)
    try await world.retrieval.embedPending(novel: world.novel)
    try await world.retrieval.embedPending(novel: RetrievalWorld.otherNovel)
    let chunks = try #require(try await world.rowCounts()[RetrievalTables.prose])
    #expect(chunks > 2)
    #expect(try await world.vectors().count == chunks + 2)

    try await world.amend(1, "The heron left at dawn.")
    try await world.removeEntity("ivo")
    try await world.retrieval.catchUp(novel: world.novel)
    #expect(try await world.vectors().count == 2)
    #expect(try await world.unvectoredRows() == 1)
    #expect(try await world.retrieval.embedPending(novel: world.novel) == RetrievalEmbedding(model: "fake/a", embedded: 1))
    #expect(try await world.unvectoredRows() == 0)

    try await world.store.forgetLocalState(novel: world.novel)
    #expect(try await world.vectors().map(\.novel) == [RetrievalWorld.otherNovel])
    try await world.checkSearchIntegrity()
  }

  @Test func shouldReembedEverythingAndNeverMixVectorsWhenTheModelChanges() async throws {
    let first = try RetrievalWorld(embedder: FakeEmbedder(model: "fake/a"))
    for chapter in 1...3 { try await first.finalize(chapter, "Chapter \(chapter): the gale tore at the boats.") }
    try await first.entity("mara", name: "Mara", notes: "Sails a vessel.")
    try await first.retrieval.catchUp(novel: first.novel)
    try await first.retrieval.embedPending(novel: first.novel)
    #expect(try await first.vectors().map(\.model) == Array(repeating: "fake/a", count: 4))

    let second = try RetrievalWorld(store: first.store, embedder: FakeEmbedder(model: "fake/b", dimension: 24))
    let plain = try RetrievalWorld(store: first.store)
    for query in ["gale", "vessel storm"] {
      #expect(try await second.retrieval.searchProseAndLore(novel: second.novel, query: query) == plain.retrieval.searchProseAndLore(novel: plain.novel, query: query))
    }

    let partial = try await second.retrieval.embedPending(novel: second.novel, limit: 1)
    #expect(partial == RetrievalEmbedding(model: "fake/b", embedded: 1, isComplete: false))
    #expect(try await second.vectors().map(\.model) == ["fake/b"])
    #expect(try await second.retrieval.embedPending(novel: second.novel) == RetrievalEmbedding(model: "fake/b", embedded: 3))
    let rebuilt = try await second.vectors()
    #expect(rebuilt.count == 4)
    #expect(rebuilt.allSatisfy { $0.model == "fake/b" && $0.vector?.count == 24 * 4 })
  }

  @Test func shouldMarkTextsThatCannotBeEmbeddedAndNotTryThemAgainUntilTheyChange() async throws {
    let embedder = FakeEmbedder()
    let world = try RetrievalWorld(embedder: embedder)
    try await world.entity("fail", name: "Broken", notes: FakeEmbedder.failing)
    try await world.entity("zero", name: FakeEmbedder.zero)
    try await world.entity("nan", name: FakeEmbedder.notANumber)
    try await world.entity("short", name: FakeEmbedder.short)
    try await world.entity("fine", name: "Fine")
    try await world.retrieval.catchUp(novel: world.novel)
    #expect(try await world.retrieval.embedPending(novel: world.novel) == RetrievalEmbedding(model: "fake/a", embedded: 1, failed: 4))
    #expect(try await world.vectors().filter { $0.vector == nil }.count == 4)

    let calls = await embedder.calls.count
    #expect(try await world.retrieval.embedPending(novel: world.novel) == RetrievalEmbedding(model: "fake/a"))
    #expect(await embedder.calls.count == calls)
    #expect(try await world.loreKeys("vessel") == ["character:fine"])

    var edit = EntityEdit()
    edit.notes = .set("Mended.")
    try await world.editEntity("fail", edit)
    try await world.retrieval.catchUp(novel: world.novel)
    #expect(try await world.retrieval.embedPending(novel: world.novel) == RetrievalEmbedding(model: "fake/a", embedded: 1))
    #expect(await embedder.embeddedTexts.last == "Broken\nMended.")
  }

  @Test func shouldTreatAVectorOfTheWrongLengthAsPendingAndEmbedItAgain() async throws {
    let world = try RetrievalWorld(embedder: FakeEmbedder())
    try await world.finalize(1, "The boat drifted.")
    try await world.finalize(2, "The army waited.")
    try await world.retrieval.catchUp(novel: world.novel)
    try await world.retrieval.embedPending(novel: world.novel)
    try await world.store.write { transaction in
      try transaction.database.execute(sql: "UPDATE \(RetrievalTables.vector) SET vector = x'0000803F' WHERE item = (SELECT MIN(item) FROM \(RetrievalTables.vector))")
    }
    #expect(try await world.proseChapters("vessel").isEmpty)
    #expect(try await world.retrieval.embedPending(novel: world.novel) == RetrievalEmbedding(model: "fake/a", embedded: 1))
    #expect(try await world.proseChapters("vessel") == [1, 2])
  }

  @Test func shouldFindByMeaningAQueryThatSharesNoWordWithTheText() async throws {
    let world = try RetrievalWorld(embedder: FakeEmbedder())
    try await world.finalize(1, "Fresh loaves cooled on the sill.")
    try await world.finalize(2, "The tempest broke the mast.")
    try await world.finalize(3, "Soldiers marched to the fortress.")
    try await world.retrieval.catchUp(novel: world.novel)
    #expect(try await world.proseChapters("storm").isEmpty)
    try await world.retrieval.embedPending(novel: world.novel)
    #expect(try await world.proseChapters("storm", k: 1) == [2])
    #expect(try await world.proseChapters("army castle", k: 1) == [3])
    #expect(try await world.proseChapters("!!! ???").isEmpty)
  }

  @Test func shouldKeepChaptersIsolatedNowOutOfTheVectorCandidates() async throws {
    let world = try RetrievalWorld(embedder: FakeEmbedder())
    try await world.finalize(1, "The vessel left at dawn.", isolated: true)
    try await world.finalize(2, "Loaves cooled on the sill.")
    try await world.finalize(3, "A boat came back.")
    try await world.retrieval.catchUp(novel: world.novel)
    try await world.retrieval.embedPending(novel: world.novel)
    #expect(try await world.proseChapters("ship", k: 1) == [3])
    #expect(!(try await world.proseChapters("ship")).contains(1))

    try await world.draft(3, isolated: true)
    #expect(try await world.proseChapters("ship") == [2])
    try await world.draft(3, isolated: false)
    #expect(try await world.proseChapters("ship", k: 1) == [3])
  }

  @Test func shouldKeepAnIsolatedChapterThatMatchesByFTSOutOfFusedResults() async throws {
    let world = try RetrievalWorld(embedder: FakeEmbedder())
    try await world.finalize(1, "harbour harbour boat", isolated: true)
    try await world.finalize(2, "The harbour wall at dusk.")
    try await world.finalize(3, "A vessel rocked.")
    try await world.retrieval.catchUp(novel: world.novel)
    try await world.retrieval.embedPending(novel: world.novel)
    #expect(try await world.proseChapters("harbour boat", k: 1) == [2])
    let all = try await world.proseChapters("harbour boat")
    #expect(!all.contains(1))
    #expect(Set(all) == [2, 3])
  }

  @Test func shouldRespectBoundKindsForVectorCandidates() async throws {
    let world = try RetrievalWorld(embedder: FakeEmbedder())
    try await world.entity("guard", name: "Guard", notes: "Soldiers of the north.")
    try await world.page(.world, "inn", "Bread and ale.")
    try await world.retrieval.catchUp(novel: world.novel)
    try await world.retrieval.embedPending(novel: world.novel)
    #expect(try await world.loreKeys("army").first == "character:guard")
    #expect(try await world.loreKeys("army", kinds: ["bible_doc"]) == ["bible_doc:world/inn"])
    #expect(try await world.loreKeys("army", kinds: ["character"]) == ["character:guard"])
    #expect(try await world.loreKeys("army", kinds: ["faction"]).isEmpty)
    #expect(try await world.loreKeys("army", kinds: ["character') OR 1=1 --"]).isEmpty)
  }

  @Test func shouldFuseRankingsThatDisagreeByReciprocalRank() async throws {
    let texts = [
      1: "harbour harbour harbour",
      2: "The harbour at dusk, gulls over the long grey water and nets drying on the stones by the sea wall.",
      3: "Boats rocked at their moorings.",
      4: "Bread in the oven.",
    ]
    let embedder = FakeEmbedder(vectors: [
      "harbour": Self.unit([1]),
      texts[1, default: ""]: Self.unit([0.2, 0.98]),
      texts[2, default: ""]: Self.unit([0.9, 0.436]),
      texts[3, default: ""]: Self.unit([0.5, 0.866]),
      texts[4, default: ""]: Self.unit([-0.5, 0.866]),
    ])
    let world = try RetrievalWorld(embedder: embedder)
    let plain = try RetrievalWorld(store: world.store)
    for (chapter, text) in texts { try await world.finalize(chapter, text) }
    try await world.retrieval.catchUp(novel: world.novel)
    #expect(try await world.proseChapters("harbour") == [1, 2])

    #expect(try await world.retrieval.embedPending(novel: world.novel, limit: 2).isComplete == false)
    for query in ["harbour", "boats harbour"] {
      #expect(try await world.retrieval.searchProseAndLore(novel: world.novel, query: query) == plain.retrieval.searchProseAndLore(novel: world.novel, query: query))
      #expect(try await world.retrieval.searchProse(novel: world.novel, query: query, k: 10) == plain.retrieval.searchProse(novel: world.novel, query: query, k: 10))
    }

    try await world.retrieval.embedPending(novel: world.novel)
    let hits = try await world.retrieval.searchProse(novel: world.novel, query: "harbour", k: 3)
    #expect(hits.map(\.origin) == [.prose(chapter: 2), .prose(chapter: 1), .prose(chapter: 3)])
    let expected = [1 / 62.0 + 1 / 61.0, 1 / 61.0 + 1 / 63.0, 1 / 62.0]
    for (hit, score) in zip(hits, expected) { #expect(abs(hit.score - score) < 1e-12) }
    #expect(try await world.proseChapters("harbour", k: 10) == [2, 1, 3, 4])
  }

  @Test func shouldBreakAFusedTieInFavourOfTheLexicalList() {
    let lexical: [Int64] = [1]
    let semantic: [Int64] = [2, 3, 4]
    let fused = RetrievalFusion.fuse(lexical: lexical, semantic: semantic, id: \.self, limit: 3)
    #expect(fused.map(\.item) == [1, 2, 3])
    #expect(fused[0].score == fused[1].score)
    #expect(RetrievalFusion.fuse(lexical: semantic, semantic: lexical, id: \.self, limit: 2).map(\.item) == [2, 1])
    #expect(RetrievalFusion.fuse(lexical: [], semantic: semantic, id: \.self, limit: 0).isEmpty)
  }

  @Test func shouldRankByFTSAloneExactlyAsWithoutEmbeddingsWhenNoVectorCanBeCompared() async throws {
    let plain = try RetrievalWorld()
    try await plain.finalize(1, "The lighthouse keeper counted gulls over the harbour.")
    try await plain.finalize(2, "A storm reached the lighthouse at night.", isolated: true)
    try await plain.finalize(3, "Gulls and storms and the long harbour wall.")
    try await plain.entity("mara", name: "Mara", notes: "A lighthouse keeper.")
    try await plain.page(.world, "harbour", "The harbour holds a lighthouse and gulls.")
    try await plain.retrieval.catchUp(novel: plain.novel)

    let unavailable = NovelRetrieval(store: plain.store, embedders: FakeEmbedders(embedder: nil))
    let notYetEmbedded = try RetrievalWorld(store: plain.store, embedder: FakeEmbedder())
    let otherModel = try RetrievalWorld(store: plain.store, embedder: FakeEmbedder(model: "fake/b"))
    try await otherModel.retrieval.embedPending(novel: plain.novel)
    let queryFails = try RetrievalWorld(store: plain.store, embedder: FakeEmbedder(model: "fake/b"))

    for query in ["lighthouse", "gulls harbour", "storm keeper \(FakeEmbedder.failing)", "nothing matches"] {
      let expected = try await plain.retrieval.searchProseAndLore(novel: plain.novel, query: query)
      let expectedLore = try await plain.retrieval.searchLore(novel: plain.novel, query: query, kinds: ["bible_doc"])
      let lone = query.contains(FakeEmbedder.failing) ? [unavailable, notYetEmbedded.retrieval, queryFails.retrieval] : [unavailable, notYetEmbedded.retrieval]
      for retrieval in lone {
        #expect(try await retrieval.searchProseAndLore(novel: plain.novel, query: query) == expected, "\(query)")
        #expect(try await retrieval.searchProse(novel: plain.novel, query: query) == expected.prose, "\(query)")
        #expect(try await retrieval.searchLore(novel: plain.novel, query: query, kinds: ["bible_doc"]) == expectedLore, "\(query)")
      }
    }
  }

  @Test func shouldStopBetweenBatchesWhenCancelledAndConvergeWhenRunAgain() async throws {
    let world = try RetrievalWorld(embedder: FakeEmbedder(cancelOnCall: 2))
    for index in 0..<40 { try await world.entity("gull-\(index)", name: "Gull \(index)") }
    try await world.retrieval.catchUp(novel: world.novel)
    let retrieval = world.retrieval
    let novel = world.novel
    await #expect {
      try await Task { try await retrieval.embedPending(novel: novel) }.value
    } throws: { error in
      guard case .cancelled = error as? RetrievalError else { return false }
      return true
    }
    #expect(try await world.vectors().count == RetrievalVectors.batchSize)

    #expect(try await world.retrieval.embedPending(novel: novel) == RetrievalEmbedding(model: "fake/a", embedded: 40 - RetrievalVectors.batchSize))
    #expect(try await world.unvectoredRows() == 0)
  }

  @Test func shouldEmbedEachRowOnceWhenPassesRunConcurrently() async throws {
    let world = try RetrievalWorld(embedder: FakeEmbedder())
    for chapter in 1...12 { try await world.finalize(chapter, "Chapter \(chapter): the wolves ran along the ridge.") }
    for index in 0..<30 { try await world.entity("wolf-\(index)", name: "Wolf \(index)", notes: "Runs the ridge.") }
    try await world.retrieval.catchUp(novel: world.novel)
    let retrieval = world.retrieval
    let novel = world.novel
    async let first = retrieval.embedPending(novel: novel)
    async let second = retrieval.embedPending(novel: novel)
    async let third = retrieval.embedPending(novel: novel)
    let outcomes = try await [first, second, third]
    #expect(outcomes.map(\.embedded).reduce(0, +) == 42)
    #expect(outcomes.allSatisfy { $0.isComplete })
    #expect(try await world.vectors().count == 42)
    #expect(try await world.unvectoredRows() == 0)
  }

  @Test func shouldNotStoreAVectorForARowWhoseTextChangedWhileItWasEmbedded() async throws {
    let world = try RetrievalWorld(embedder: FakeEmbedder())
    try await world.entity("mara", name: "Mara", notes: "Keeper.")
    try await world.retrieval.catchUp(novel: world.novel)
    let novel = world.novel
    let item = try await world.store.read { transaction in try Int64.fetchOne(transaction.database, sql: "SELECT id FROM \(RetrievalTables.lore)") }
    let stale = RetrievalVectors.Pending(corpus: .lore, item: try #require(item), text: "Mara\nOld notes.")
    let stored = try await world.store.write { transaction in
      try RetrievalVectors.store([stale], vectors: [Self.unit([1])], novel: novel, model: "fake/a", dimension: 16, in: transaction.database)
    }
    #expect(stored.embedded == 0 && stored.failed == 0)
    #expect(try await world.vectors().isEmpty)
  }
}
