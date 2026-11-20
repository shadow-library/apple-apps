import Foundation
import GRDB
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

@Suite("Retrieval index", TestTimeLimit.standard)
struct RetrievalIndexTests {
  @Test func shouldFindFTS5WithDiacriticFoldingInTheStoresSQLite() async throws {
    let world = try RetrievalWorld()
    let compiled = try await world.store.read { transaction in
      try Bool.fetchOne(transaction.database, sql: "SELECT sqlite_compileoption_used('ENABLE_FTS5')") ?? false
    }
    #expect(compiled)
    try await world.finalize(1, "Mara drank at the Café Noir until the bells rang.")
    try await world.retrieval.catchUp(novel: world.novel)
    #expect(try await world.proseChapters("cafe noir") == [1])
    #expect(try await world.proseChapters("CAFÉ") == [1])
  }

  @Test func shouldIndexFinalProseEntitiesAndPagesWithTheReferenceKindsAndKeys() async throws {
    let world = try RetrievalWorld()
    try await world.finalize(1, "The lighthouse keeper counted gulls.")
    try await world.entity("mara", name: "Mara", notes: "A lighthouse keeper.", body: "Born on the salt flats.")
    try await world.page(.world, "harbour", "The harbour holds a lighthouse.")
    let outcome = try await world.retrieval.catchUp(novel: world.novel)
    #expect(outcome == RetrievalCatchUp(added: 3))

    let prose = try await world.retrieval.searchProse(novel: world.novel, query: "lighthouse")
    #expect(prose.map(\.origin) == [.prose(chapter: 1)])
    #expect(prose.first?.text == "The lighthouse keeper counted gulls.")
    let lore = try await world.retrieval.searchLore(novel: world.novel, query: "lighthouse")
    #expect(Set(lore.map(\.origin)) == [.lore(kind: "character", refKey: "mara"), .lore(kind: "bible_doc", refKey: "world/harbour")])
    #expect(lore.first { $0.origin == .lore(kind: "character", refKey: "mara") }?.text == "Mara\nA lighthouse keeper.\nBorn on the salt flats.")
    #expect(lore.allSatisfy { $0.score > 0 })
  }

  @Test func shouldLeaveOutEmptyTextsAndPlannerOnlyPages() async throws {
    let world = try RetrievalWorld()
    try await world.finalize(1, "")
    try await world.entity("blank", name: "")
    try await world.page(.world, "empty", "")
    try await world.page(.world, "none", nil)
    try await world.page(.project, "timeline", "The lighthouse falls in volume three.")
    try await world.page(.project, "open-questions", "Who lit the lighthouse?")
    let outcome = try await world.retrieval.catchUp(novel: world.novel)
    #expect(outcome == RetrievalCatchUp(confirmed: 6))
    #expect(try await world.loreKeys("lighthouse").isEmpty)
    #expect(try await world.rowCounts() == [RetrievalTables.source: 6, RetrievalTables.prose: 0, RetrievalTables.lore: 0])
    #expect(try await world.retrieval.catchUp(novel: world.novel).isEmpty)
  }

  @Test func shouldDoNothingWhenNothingChangedAndKeepRowsWhenOnlyUnindexedFieldsChanged() async throws {
    let world = try RetrievalWorld()
    try await world.finalize(1, "Tide over the flats.")
    try await world.entity("mara", name: "Mara", notes: "Keeper.")
    try await world.retrieval.catchUp(novel: world.novel)
    let before = try await world.dump()

    #expect(try await world.retrieval.catchUp(novel: world.novel).isEmpty)
    var edit = EntityEdit()
    edit.status = .set("alive")
    try await world.editEntity("mara", edit)
    #expect(try await world.retrieval.catchUp(novel: world.novel) == RetrievalCatchUp(confirmed: 1))
    let after = try await world.dump()
    #expect(after.filter { !$0.hasPrefix("source") } == before.filter { !$0.hasPrefix("source") })
    #expect(after != before)
    #expect(try await world.retrieval.catchUp(novel: world.novel).isEmpty)
  }

  @Test func shouldReplaceAnEditedEntityAndDropARemovedOne() async throws {
    let world = try RetrievalWorld()
    try await world.entity("mara", name: "Mara", notes: "Keeper of the old lamp.")
    try await world.entity("ivo", name: "Ivo", notes: "Ferryman.")
    try await world.retrieval.catchUp(novel: world.novel)

    var edit = EntityEdit()
    edit.notes = .set("Keeper of the new beacon.")
    try await world.editEntity("mara", edit)
    try await world.removeEntity("ivo")
    #expect(try await world.retrieval.catchUp(novel: world.novel) == RetrievalCatchUp(updated: 1, removed: 1))
    #expect(try await world.loreKeys("lamp").isEmpty)
    #expect(try await world.loreKeys("beacon") == ["character:mara"])
    #expect(try await world.loreKeys("ferryman").isEmpty)
    #expect(try await world.rowCounts()[RetrievalTables.source] == 1)
    try await world.checkSearchIntegrity()
  }

  @Test func shouldReplaceAmendedProseSoTheOldSentenceIsNeverFound() async throws {
    let world = try RetrievalWorld()
    let long = (0..<30).map { "Paragraph \($0) of the chapter, with the heron standing in the reeds." }.joined(separator: "\n\n")
    try await world.finalize(2, long + "\n\nThe silver key lay under the stair.")
    try await world.retrieval.catchUp(novel: world.novel)
    #expect(try await world.proseChapters("silver key") == [2])

    try await world.amend(2, "The heron left at dawn. Nothing lay under the stair.")
    #expect(try await world.retrieval.catchUp(novel: world.novel) == RetrievalCatchUp(updated: 1))
    #expect(try await world.proseChapters("silver").isEmpty)
    #expect(try await world.proseChapters("dawn") == [2])
    #expect(try await world.rowCounts()[RetrievalTables.prose] == 1)
    try await world.checkSearchIntegrity()
  }

  @Test func shouldExcludeIsolatedChaptersByTheirCurrentStateAtQueryTime() async throws {
    let world = try RetrievalWorld()
    try await world.finalize(1, "The orchard burned in the night.")
    try await world.finalize(2, "The orchard bloomed again in spring.", isolated: true)
    try await world.retrieval.catchUp(novel: world.novel)
    #expect(try await world.rowCounts()[RetrievalTables.prose] == 2)
    #expect(try await world.proseChapters("orchard") == [1])

    try await world.draft(1, isolated: true)
    #expect(try await world.proseChapters("orchard").isEmpty)
    try await world.draft(1, isolated: false)
    #expect(try await world.proseChapters("orchard") == [1])
    let both = try await world.retrieval.searchProseAndLore(novel: world.novel, query: "orchard")
    #expect(both.prose.map(\.origin) == [.prose(chapter: 1)])
  }

  @Test func shouldFillKFromTheChaptersLeftAfterIsolation() async throws {
    let world = try RetrievalWorld()
    try await world.finalize(1, "Rain on the quay.", isolated: true)
    try await world.finalize(2, "Rain on the quay and rain on the roofs, rain everywhere.", isolated: true)
    try await world.finalize(3, "Rain at last.")
    try await world.finalize(4, "Rain again.")
    try await world.retrieval.catchUp(novel: world.novel)
    #expect(Set(try await world.proseChapters("rain", k: 2)) == [3, 4])
    #expect(try await world.proseChapters("rain", k: 0).isEmpty)
  }

  @Test func shouldIndexRecordsThatArrivedByReplicaMerge() async throws {
    let author = try RetrievalWorld()
    let reader = try RetrievalWorld()
    try await author.finalize(1, "A comet crossed the harbour sky.")
    try await author.entity("comet", name: "The Comet", notes: "Seen every forty years.")
    try await reader.retrieval.catchUp(novel: reader.novel)

    _ = try await reader.store.applyRemote(try await author.store.pendingChanges(limit: .max).map(\.line))
    #expect(try await reader.retrieval.catchUp(novel: reader.novel) == RetrievalCatchUp(added: 2))
    #expect(try await reader.proseChapters("comet") == [1])
    #expect(try await reader.loreKeys("forty") == ["character:comet"])

    let sent = try await author.store.pendingChanges(limit: .max).count
    try await author.amend(1, "Clouds hid the harbour sky.")
    try await author.removeEntity("comet")
    let later = try await author.store.pendingChanges(limit: .max).map(\.line).dropFirst(sent)
    _ = try await reader.store.applyRemote(Array(later))
    #expect(try await reader.retrieval.catchUp(novel: reader.novel) == RetrievalCatchUp(updated: 1, removed: 1))
    #expect(try await reader.proseChapters("comet").isEmpty)
    #expect(try await reader.loreKeys("forty").isEmpty)
  }

  @Test func shouldDropASourceWhoseRecordLeftTheCorpus() async throws {
    let world = try RetrievalWorld()
    try await world.finalize(1, "Ash fell on the city.")
    try await world.retrieval.catchUp(novel: world.novel)
    let stale = try FinalChapterRecord.ref(novel: world.novel, chapter: 7)
    let novel = world.novel
    try await world.store.write { transaction in
      let database = transaction.database
      try database.execute(
        sql: "INSERT INTO \(RetrievalTables.source) (novel, record_kind, record_key, digest, content) VALUES (?, ?, ?, 'gone', 'gone')",
        arguments: [novel, stale.kind.rawValue, stale.key.rawValue])
      try database.execute(
        sql: "INSERT INTO \(RetrievalTables.prose) (source, novel, chapter, ordinal, text) VALUES (?, ?, 7, 0, 'Ash fell on chapter seven.')",
        arguments: [database.lastInsertedRowID, novel])
    }
    #expect(try await world.proseChapters("ash") == [1, 7])

    #expect(try await world.retrieval.catchUp(novel: world.novel) == RetrievalCatchUp(removed: 1))
    #expect(try await world.proseChapters("ash") == [1])
    try await world.checkSearchIntegrity()
  }

  @Test func shouldLeaveEachSourceWholeWhenItsTransactionFailsAndConvergeOnTheNextCatchUp() async throws {
    let world = try RetrievalWorld()
    try await world.entity("mara", name: "Mara", notes: "Keeps the lamp.")
    try await world.entity("ivo", name: "Ivo", notes: "Rows the ferry.")
    try await world.retrieval.catchUp(novel: world.novel)
    let before = try await world.dump()

    var mara = EntityEdit()
    mara.notes = .set("Keeps the beacon.")
    try await world.editEntity("mara", mara)
    var ivo = EntityEdit()
    ivo.notes = .set("Swims the strait.")
    try await world.editEntity("ivo", ivo)
    let novel = world.novel
    let pending = try await world.store.read { transaction in try RetrievalIndexer.pending(novel: novel, in: transaction) }
    #expect(pending.count == 2)

    await #expect(throws: StoreError.self) {
      try await world.store.write { transaction in
        _ = try RetrievalIndexer.refresh(pending, novel: novel, in: transaction.database)
        throw StoreError.invalidChange("the device stopped mid-write")
      }
    }
    #expect(try await world.dump() == before)

    let first = try #require(pending.first)
    _ = try await world.store.write { transaction in try RetrievalIndexer.refresh([first], novel: novel, in: transaction.database) }
    #expect(try await world.retrieval.catchUp(novel: world.novel) == RetrievalCatchUp(updated: 1))
    #expect(try await world.loreKeys("beacon") == ["character:mara"])
    #expect(try await world.loreKeys("strait") == ["character:ivo"])
    #expect(try await world.loreKeys("lamp ferry").isEmpty)
    try await world.checkSearchIntegrity()
  }

  @Test func shouldNotDuplicateAnythingWhenCatchUpsRunConcurrently() async throws {
    let world = try RetrievalWorld()
    for chapter in 1...12 { try await world.finalize(chapter, "Chapter \(chapter): the wolves ran along the ridge.") }
    for index in 0..<30 { try await world.entity("wolf-\(index)", name: "Wolf \(index)", notes: "Runs the ridge.") }
    let retrieval = world.retrieval
    let novel = world.novel
    async let first = retrieval.catchUp(novel: novel)
    async let second = retrieval.catchUp(novel: novel)
    async let third = retrieval.catchUp(novel: novel)
    let outcomes = try await [first, second, third]
    #expect(outcomes.map(\.added).reduce(0, +) == 42)
    #expect(try await world.rowCounts() == [RetrievalTables.source: 42, RetrievalTables.prose: 12, RetrievalTables.lore: 30])
    #expect(try await world.retrieval.catchUp(novel: novel).isEmpty)
    try await world.checkSearchIntegrity()
  }

  @Test func shouldRefuseToCatchUpAndChangeNothingWhileTheRecordIndexIsFaulted() async throws {
    let world = try RetrievalWorld()
    try await world.finalize(1, "Dust on the road.")
    try await world.retrieval.catchUp(novel: world.novel)
    let before = try await world.dump()
    try await world.finalize(2, "More dust.")
    try await world.store.write { transaction in
      try transaction.database.execute(
        sql: "INSERT INTO \(ProjectionFaults.table) (derivation, key, version, message) VALUES (?, ?, 1, 'stuck')",
        arguments: [IndexedRecord.databaseTableName, ProjectionFaults.wholeDerivation])
    }
    await #expect {
      try await world.retrieval.catchUp(novel: world.novel)
    } throws: { error in
      guard case .indexUnavailable(let faults) = error as? RetrievalError else { return false }
      return faults.map(\.message) == ["stuck"]
    }
    #expect(try await world.dump() == before)
  }

  @Test func shouldReadEverySourceAgainAndReplaceItsRowsWhenTheCorpusVersionChanges() async throws {
    let world = try RetrievalWorld()
    try await world.finalize(1, "The heron stood in the reeds.")
    try await world.entity("heron", name: "Heron", notes: "Grey.")
    try await world.page(.world, "marsh", "Reeds where the heron stands.")
    try await world.retrieval.catchUp(novel: world.novel)
    let novel = world.novel
    try await world.store.write { transaction in
      for table in [RetrievalTables.prose, RetrievalTables.lore] { try transaction.database.execute(sql: "UPDATE \(table) SET text = 'stale'") }
    }
    #expect(try await world.store.read { transaction in try RetrievalIndexer.pending(novel: novel, in: transaction) }.isEmpty)

    let next = RetrievalCorpus.version + 1
    let pending = try await world.store.read { transaction in try RetrievalIndexer.pending(novel: novel, version: next, in: transaction) }
    #expect(pending.count == 3)
    let outcome = try await world.store.write { transaction in try RetrievalIndexer.refresh(pending, novel: novel, version: next, in: transaction.database) }
    #expect(outcome == RetrievalCatchUp(updated: 3))
    #expect(try await world.proseChapters("stale").isEmpty)
    #expect(try await world.loreKeys("stale").isEmpty)
    #expect(Set(try await world.loreKeys("heron")) == ["character:heron", "bible_doc:world/marsh"])
    #expect(try await world.store.read { transaction in try RetrievalIndexer.pending(novel: novel, version: next, in: transaction) }.isEmpty)
    #expect(try await world.proseChapters("heron") == [1])
    try await world.checkSearchIntegrity()
  }

  @Test func shouldRefuseABatchWhoseRecordIndexFaultedAfterThePendingListWasRead() async throws {
    let world = try RetrievalWorld()
    try await world.entity("mara", name: "Mara", notes: "Keeper.")
    try await world.retrieval.catchUp(novel: world.novel)
    let before = try await world.dump()
    try await world.removeEntity("mara")
    let novel = world.novel
    let pending = try await world.store.read { transaction in try RetrievalIndexer.pending(novel: novel, in: transaction) }
    #expect(pending.count == 1)

    await #expect {
      try await world.store.write { transaction in
        try transaction.database.execute(
          sql: "INSERT INTO \(ProjectionFaults.table) (derivation, key, version, message) VALUES (?, ?, 1, 'stuck')",
          arguments: [IndexedRecord.databaseTableName, ProjectionFaults.wholeDerivation])
        _ = try RetrievalIndexer.refresh(pending, novel: novel, in: transaction.database)
      }
    } throws: { error in
      guard case .aborted(let cause) = error as? StoreError, case .indexUnavailable = cause as? RetrievalError else { return false }
      return true
    }
    #expect(try await world.dump() == before)
  }

  @Test func shouldStopACancelledCatchUpWithCancelledAndConvergeWhenRunAgain() async throws {
    let world = try RetrievalWorld()
    for index in 0..<40 { try await world.entity("gull-\(index)", name: "Gull \(index)") }
    let retrieval = world.retrieval
    let novel = world.novel
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await retrieval.catchUp(novel: novel)
    }
    await #expect {
      try await task.value
    } throws: { error in
      guard case .cancelled = error as? RetrievalError else { return false }
      return true
    }
    try await world.retrieval.catchUp(novel: novel)
    #expect(try await world.rowCounts()[RetrievalTables.lore] == 40)
    #expect(try await world.retrieval.catchUp(novel: novel).isEmpty)
  }

  @Test func shouldTreatFTSSyntaxInAQueryAsLiteralText() async throws {
    let world = try RetrievalWorld()
    try await world.finalize(1, "NEAR the AND gate stood an OR sign and a star.")
    try await world.finalize(2, "Silence in the valley.")
    try await world.entity("gate", name: "Gate", notes: "text: column filters are not syntax here")
    try await world.retrieval.catchUp(novel: world.novel)

    for attack in [#"NEAR(gate star, 1)"#, #""gate" OR *"#, "text:gate", "^gate", "gate*", "gate) OR (zebra", "\"\"gate\"\"", "{text}: gate", "- gate", "gate NOT star"] {
      let hits = try await world.retrieval.searchProse(novel: world.novel, query: attack)
      #expect(hits.map(\.origin) == [.prose(chapter: 1)], "\(attack)")
    }
    #expect(try await world.loreKeys("text: column") == ["character:gate"])
    for empty in ["", "   ", "!!! ???", "* ^ : ()", "😀"] {
      #expect(try await world.retrieval.searchProse(novel: world.novel, query: empty).isEmpty)
      #expect(try await world.retrieval.searchLore(novel: world.novel, query: empty).isEmpty)
    }
  }

  @Test func shouldFilterLoreByBoundKinds() async throws {
    let world = try RetrievalWorld()
    try await world.entity("tower", name: "The Tower", notes: "Black stone.")
    try await world.page(.world, "tower", "The tower is black stone.")
    try await world.retrieval.catchUp(novel: world.novel)
    #expect(try await world.loreKeys("stone", kinds: ["character"]) == ["character:tower"])
    #expect(try await world.loreKeys("stone", kinds: ["bible_doc"]) == ["bible_doc:world/tower"])
    #expect(Set(try await world.loreKeys("stone", kinds: [])) == ["character:tower", "bible_doc:world/tower"])
    #expect(Set(try await world.loreKeys("stone", kinds: ["character", "bible_doc", "character"])).count == 2)
    #expect(try await world.loreKeys("stone", kinds: ["faction"]).isEmpty)
    #expect(try await world.loreKeys("stone", kinds: ["character') OR 1=1 --"]).isEmpty)
  }

  @Test func shouldKeepNovelsApartAndClearANovelWithItsLocalCleanup() async throws {
    let world = try RetrievalWorld()
    try await world.finalize(1, "Snow over the pass.")
    try await world.entity("pass", name: "The Pass", notes: "Snow all year.")
    try await world.finalize(1, "Snow in the other book.", novel: RetrievalWorld.otherNovel)
    try await world.retrieval.catchUp(novel: world.novel)
    try await world.retrieval.catchUp(novel: RetrievalWorld.otherNovel)
    #expect(try await world.proseChapters("snow") == [1])
    #expect(try await world.rowCounts() == [RetrievalTables.source: 3, RetrievalTables.prose: 2, RetrievalTables.lore: 1])

    try await world.store.forgetLocalState(novel: world.novel)
    #expect(try await world.rowCounts() == [RetrievalTables.source: 1, RetrievalTables.prose: 1, RetrievalTables.lore: 0])
    #expect(try await world.proseChapters("snow").isEmpty)
    #expect(try await world.retrieval.searchProse(novel: RetrievalWorld.otherNovel, query: "snow").count == 1)
    try await world.checkSearchIntegrity()
  }

  @Test func shouldSearchNothingAndForgetNothingBeforeTheFirstCatchUp() async throws {
    let world = try RetrievalWorld()
    try await world.finalize(1, "Fog.")
    #expect(try await world.proseChapters("fog").isEmpty)
    #expect(try await world.loreKeys("fog").isEmpty)
    try await world.store.forgetLocalState(novel: world.novel)
    #expect(try await world.rowCounts().isEmpty)
  }

  @Test func shouldRankTheChapterHoldingThePhraseAboveUnrelatedOnes() async throws {
    let world = try RetrievalWorld()
    try await world.finalize(1, "They walked the market and bought bread and figs.")
    try await world.finalize(2, "At midnight the drowned bell of Saint Arno rang beneath the lagoon.")
    try await world.finalize(3, "The bell in the market tower rang at noon for the bakers.")
    try await world.finalize(4, "Rowers crossed the lagoon before the storm.")
    try await world.finalize(5, "A long letter about taxes, harvests and the price of salt.")
    try await world.retrieval.catchUp(novel: world.novel)
    let hits = try await world.retrieval.searchProse(novel: world.novel, query: "the drowned bell of Saint Arno")
    #expect(hits.first?.origin == .prose(chapter: 2))
    #expect(hits.dropFirst().allSatisfy { $0.score < hits[0].score })
    #expect(zip(hits, hits.dropFirst()).allSatisfy { $0.score >= $1.score })
  }
}
