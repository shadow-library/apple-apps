import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

@Suite("Retrieval upkeep", TestTimeLimit.standard)
struct RetrievalUpkeepTests {
  private static let (first, second) = (RetrievalWorld.novel, RetrievalWorld.otherNovel)

  private static func notes(_ text: String) -> EntityEdit {
    var edit = EntityEdit()
    edit.notes = .set(text)
    return edit
  }

  private struct Harness {
    let world: RetrievalWorld
    let work = RecordedUpkeepWork()
    let sleep = ManualSleep()
    let noticed = NoticedNovels()

    init(embedder: FakeEmbedder? = nil) throws {
      world = try RetrievalWorld(embedder: embedder)
    }

    func upkeep(work: RetrievalUpkeep.Work? = nil) -> RetrievalUpkeep {
      RetrievalUpkeep(store: world.store, work: work ?? self.work.work, sleep: sleep.sleep, noticed: noticed.hook)
    }

    /// Every change committed before this one has been seen once the upkeep notices this write to `novel`.
    func barrier(_ novel: UUID, key: String) async throws {
      let before = noticed.all.count
      try await world.entity(key, name: "Barrier \(key)", novel: novel)
      let noticed = noticed
      try await UpkeepWait.until("the upkeep notices \(key)") { noticed.all.count > before && noticed.all.last?.contains(novel) == true }
    }
  }

  @Test func shouldCatchEveryNovelUpAndEmbedItWhenStarted() async throws {
    let harness = try Harness()
    try await harness.world.entity("mara", name: "Mara")
    try await harness.world.finalize(1, "The tide came in.", novel: Self.second)
    let upkeep = harness.upkeep()
    await upkeep.start()
    let work = harness.work
    try await UpkeepWait.until("both novels are caught up and embedded") { work.calls.count == 4 }
    #expect(work.calls == [.catchUp(Self.first), .embed(Self.first), .catchUp(Self.second), .embed(Self.second)])
    #expect(harness.sleep.requested == 0)
    await upkeep.stop()
  }

  @Test func shouldCatchUpOnceTheWritesToANovelHaveBeenQuietAndNotBefore() async throws {
    let harness = try Harness()
    try await harness.world.entity("mara", name: "Mara")
    let upkeep = harness.upkeep()
    await upkeep.start()
    let work = harness.work
    try await UpkeepWait.until("the start's pass ends") { work.calls.count == 2 }
    for note in ["one", "two", "three"] { try await harness.world.editEntity("mara", Self.notes(note)) }
    try await harness.barrier(Self.second, key: "quiet")
    #expect(work.count(.catchUp(Self.first)) == 1)
    #expect(harness.sleep.waiting == 2)
    harness.sleep.advance()
    try await UpkeepWait.until("the quiet novels are caught up") { work.count(.catchUp(Self.first)) == 2 && work.count(.catchUp(Self.second)) == 1 }
    try await harness.barrier(Self.second, key: "settled")
    #expect(work.count(.catchUp(Self.first)) == 2)
    await upkeep.stop()
  }

  @Test func shouldNotWakeOnItsOwnIndexWritesNorOnWritesOutsideTheCorpus() async throws {
    let harness = try Harness(embedder: FakeEmbedder())
    try await harness.world.finalize(1, "The ship left in a storm.")
    try await harness.world.entity("mara", name: "Mara", notes: "Keeper of the boats.")
    let upkeep = harness.upkeep(work: .index(harness.world.retrieval))
    await upkeep.start()
    let world = harness.world
    try await UpkeepWait.until("the novel is indexed and embedded") {
      let (counts, unvectored, vectors) = (try await world.rowCounts(), try await world.unvectoredRows(), try await world.vectors())
      return counts[RetrievalTables.lore] == 1 && unvectored == 0 && !vectors.isEmpty
    }
    _ = try await world.store.write { transaction in
      try NotebookEntryRecord(novel: Self.first, entryKind: .known(.decision), topic: "tone", statement: "Keep it dry.").append(in: &transaction)
    }
    try await harness.barrier(Self.second, key: "after")
    #expect(harness.noticed.all == [[Self.first], [Self.second]])
    #expect(harness.sleep.requested == 1)
    #expect(try await world.proseChapters("vessel tempest") == [1])
    await upkeep.stop()
  }

  @Test func shouldNeverWorkOnANovelTwiceAtOnceNorAcrossARestart() async throws {
    let harness = try Harness()
    try await harness.world.entity("mara", name: "Mara")
    let work = harness.work
    work.hold(.catchUp(Self.first))
    let upkeep = harness.upkeep()
    await upkeep.start()
    try await UpkeepWait.until("the start's catch-up is held") { work.holding == 1 }
    try await harness.world.editEntity("mara", Self.notes("Changed meanwhile."))
    try await UpkeepWait.until("the change is noticed") { harness.sleep.waiting == 1 }
    harness.sleep.advance()
    try await Task.sleep(for: .milliseconds(200))
    #expect(work.count(.catchUp(Self.first)) == 1)

    work.hold(.embed(Self.first))
    work.open()
    try await UpkeepWait.until("the next unit is held") { work.holding == 1 }
    await upkeep.stop()
    await upkeep.start()
    try await Task.sleep(for: .milliseconds(200))
    #expect(work.mostAtOnce == 1)
    try await UpkeepWait.until("the restart catches up after the stopped pass ended") { work.count(.catchUp(Self.first)) == 2 }
    #expect(work.cancelled == [.embed(Self.first)])
    #expect(work.mostAtOnce == 1)
    await upkeep.stop()
  }

  @Test func shouldPutAWaitingCatchUpBeforeTheNextEmbeddingBatch() async throws {
    let harness = try Harness()
    try await harness.world.entity("mara", name: "Mara")
    try await harness.world.entity("tom", name: "Tom", novel: Self.second)
    let work = harness.work
    let partial = RetrievalEmbedding(model: "fake/a", embedded: RetrievalUpkeep.embeddingBatch, isComplete: false)
    work.embeddings(Self.first, [partial, partial])
    let upkeep = harness.upkeep()
    await upkeep.start()
    try await UpkeepWait.until("every unit ran") { work.calls.count == 6 }
    #expect(
      work.calls == [.catchUp(Self.first), .embed(Self.first), .catchUp(Self.second), .embed(Self.second), .embed(Self.first), .embed(Self.first)])
    await upkeep.stop()
  }

  @Test func shouldNotEmbedAgainWhenABatchMadeNoProgress() async throws {
    let harness = try Harness()
    try await harness.world.entity("mara", name: "Mara")
    let work = harness.work
    work.embeddings(Self.first, [RetrievalEmbedding(model: "fake/a", isComplete: false)])
    let upkeep = harness.upkeep()
    await upkeep.start()
    try await UpkeepWait.until("the start's pass ends") { work.calls.count == 2 }
    try await harness.barrier(Self.second, key: "after")
    #expect(work.count(.embed(Self.first)) == 1)
    await upkeep.stop()
  }

  @Test func shouldStopBetweenBatchesForgetWhatWaitedAndCatchUpAgainOnTheNextStart() async throws {
    let harness = try Harness()
    try await harness.world.entity("mara", name: "Mara")
    let work = harness.work
    work.hold(.embed(Self.first))
    let upkeep = harness.upkeep()
    await upkeep.start()
    try await UpkeepWait.until("the embedding is held") { work.holding == 1 }
    try await harness.world.editEntity("mara", Self.notes("Changed meanwhile."))
    try await UpkeepWait.until("the change is noticed") { harness.sleep.waiting == 1 }
    await upkeep.stop()
    #expect(await upkeep.isRunning == false)
    try await UpkeepWait.until("the held embedding ends cancelled") { work.cancelled == [.embed(Self.first)] }
    #expect(harness.sleep.waiting == 0)
    try await harness.world.editEntity("mara", Self.notes("Changed while stopped."))
    try await Task.sleep(for: .milliseconds(200))
    #expect(work.calls == [.catchUp(Self.first), .embed(Self.first)])

    await upkeep.start()
    try await UpkeepWait.until("the next start catches up again") { work.calls.count == 4 }
    #expect(work.calls.suffix(2) == [.catchUp(Self.first), .embed(Self.first)])
    await upkeep.stop()
  }

  @Test func shouldTryAFailedCatchUpAgainAfterAWaitThatDoublesWithEachFailure() async throws {
    let harness = try Harness()
    try await harness.world.entity("mara", name: "Mara")
    let work = harness.work
    work.fail(.catchUp(Self.first), times: 3)
    let upkeep = harness.upkeep()
    await upkeep.start()
    for attempt in 1...3 {
      try await UpkeepWait.until("failure \(attempt) waits for its retry") { work.count(.catchUp(Self.first)) == attempt && harness.sleep.waiting == 1 }
      #expect(work.count(.embed(Self.first)) == 0)
      harness.sleep.advance()
    }
    try await UpkeepWait.until("the fourth try catches up and embeds") { work.count(.embed(Self.first)) == 1 }
    #expect(work.count(.catchUp(Self.first)) == 4)
    #expect(harness.sleep.durations == [.seconds(30), .seconds(60), .seconds(120)])
    #expect(await upkeep.isRunning)
    await upkeep.stop()
  }

  @Test func shouldTryAFailedEmbeddingBatchAgainWithoutCatchingUpAgain() async throws {
    let harness = try Harness()
    try await harness.world.entity("mara", name: "Mara")
    let work = harness.work
    work.fail(.embed(Self.first))
    let upkeep = harness.upkeep()
    await upkeep.start()
    try await UpkeepWait.until("the failed batch waits for its retry") { work.count(.embed(Self.first)) == 1 && harness.sleep.waiting == 1 }
    harness.sleep.advance()
    try await UpkeepWait.until("the batch is tried again") { work.count(.embed(Self.first)) == 2 }
    #expect(work.count(.catchUp(Self.first)) == 1)
    await upkeep.stop()
  }

  @Test func shouldCatchUpAFailedNovelOnItsNextChangeTooAndResetTheWaitOnSuccess() async throws {
    let harness = try Harness()
    try await harness.world.entity("mara", name: "Mara")
    let work = harness.work
    work.fail(.catchUp(Self.first))
    let upkeep = harness.upkeep()
    await upkeep.start()
    try await UpkeepWait.until("the failure waits for its retry") { harness.sleep.waiting == 1 }
    try await harness.world.editEntity("mara", Self.notes("Again."))
    try await UpkeepWait.until("the change replaces the retry's wait") { harness.sleep.requested == 2 && harness.sleep.waiting == 1 }
    harness.sleep.advance()
    try await UpkeepWait.until("the change catches up and embeds") { work.count(.embed(Self.first)) == 1 }
    work.fail(.catchUp(Self.first))
    try await harness.world.editEntity("mara", Self.notes("Once more."))
    try await UpkeepWait.until("the change is noticed") { harness.sleep.waiting == 1 }
    harness.sleep.advance()
    try await UpkeepWait.until("the next failure waits") { work.count(.catchUp(Self.first)) == 3 && harness.sleep.waiting == 1 }
    #expect(harness.sleep.durations == [.seconds(30), RetrievalUpkeep.defaultDebounce, RetrievalUpkeep.defaultDebounce, .seconds(30)])
    await upkeep.stop()
  }

  @Test func shouldDropTheIndexOfANovelWhoseRecordsLeftEvenAfterItsLocalStateWasForgotten() async throws {
    let harness = try Harness(embedder: FakeEmbedder())
    try await harness.world.entity("mara", name: "Mara", notes: "Keeper of the boats.")
    try await harness.world.entity("tom", name: "Tom", novel: Self.second)
    let upkeep = harness.upkeep(work: .index(harness.world.retrieval))
    await upkeep.start()
    let world = harness.world
    try await UpkeepWait.until("both novels are indexed") {
      let (counts, unvectored) = (try await world.rowCounts(), try await world.unvectoredRows())
      return counts[RetrievalTables.lore] == 2 && unvectored == 0
    }
    try await world.removeEntity("mara")
    try await world.store.forgetLocalState(novel: Self.first)
    try await UpkeepWait.until("the change is noticed") { harness.sleep.waiting >= 1 }
    harness.sleep.advance()
    try await harness.barrier(Self.second, key: "after-removal")
    harness.sleep.advance()
    try await UpkeepWait.until("only the other novel stays indexed") {
      let (counts, mara) = (try await world.rowCounts(), try await world.loreKeys("Mara"))
      return counts[RetrievalTables.lore] == 2 && mara.isEmpty
    }
    #expect(await upkeep.isRunning)
    await upkeep.stop()
  }
}
