import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

@Suite("Chapter summary", TestTimeLimit.standard)
struct ChapterSummaryTests {
  static let reply = ReviewWorld.reply(["summary": "Mara finds the torn logbook.", "state": ["lastBeat": "Mara stares at the torn page."]])

  @Test func shouldSaveTheSummaryOnTheDraftItWasWrittenFrom() async throws {
    let world = try await ReviewWorld(calls: [Self.reply])
    let engine = try world.engine()
    let before = try await world.draft(ReviewWorld.body)
    let result = try await engine.summarize(novel: world.novel, chapter: 1)
    #expect(result.saved && result.summary == "Mara finds the torn logbook." && result.state["lastBeat"] == "Mara stares at the torn page.")
    let novel = world.novel
    let head = try await world.store.read { transaction in try DraftRecord.read(try DraftRecord.ref(novel: novel, chapter: 1), in: transaction).entry?.record.content }
    #expect(head?.summary == "Mara finds the torn logbook." && head?.body == ReviewWorld.body)
    #expect(result.revision != nil && result.revision != before)
    #expect(world.provider.requests.first?.messages.last?.text == "Chapter prose:\n\n\(ReviewWorld.body)")
    #expect(try await world.base.ledgerIDs().count == 1)
  }

  @Test func shouldReturnAnIsolatedChaptersSummaryUnsaved() async throws {
    let world = try await ReviewWorld(calls: [Self.reply], isolated: true)
    let engine = try world.engine(unrestrictedAvailable: true)
    let result = try await engine.summarize(novel: world.novel, chapter: 1)
    #expect(!result.saved && result.revision == nil && result.summary == "Mara finds the torn logbook.")
    let novel = world.novel
    let head = try await world.store.read { transaction in try DraftRecord.read(try DraftRecord.ref(novel: novel, chapter: 1), in: transaction).entry?.record.content }
    #expect(head?.summary == nil)
    #expect(world.provider.requests.first?.model == CompactionWorld.unrestrictedModel)
  }

  @Test func shouldRefuseToSaveASummaryOverProseThatChanged() async throws {
    let world = try await ReviewWorld()
    let novel = world.novel
    let read = try await world.store.summaryRead { transaction throws(ChapterSummaryError) in
      try ChapterSummary.source(novel: novel, chapter: 1, at: Date(), in: transaction)
    }
    try await world.draft(ReviewWorld.body + " The lamp went out.")
    await #expect(throws: ChapterSummaryError.conflict(chapter: 1, attempted: "S")) {
      _ = try await world.store.summaryWrite { transaction throws(ChapterSummaryError) in try ChapterSummary.save("S", novel: novel, chapter: 1, over: read, in: &transaction) }
    }
  }

  @Test func shouldRefuseToSummarizeAChapterWithNoProse() async throws {
    let world = try await ReviewWorld(body: " ")
    let engine = try world.engine()
    do {
      _ = try await engine.summarize(novel: world.novel, chapter: 1)
      Issue.record("a blank chapter was summarized")
    } catch {
      #expect(error.code == "CHP_007")
    }
    #expect(world.provider.requests.isEmpty)
  }

  @Test func shouldRefuseASummaryOverATypedWorkingCopyAndKeepIt() async throws {
    let world = try await ReviewWorld()
    let novel = world.novel
    let head = try await world.draft(ReviewWorld.body)
    let read = try await world.store.summaryRead { transaction throws(ChapterSummaryError) in
      try ChapterSummary.source(novel: novel, chapter: 1, at: Date(), in: transaction)
    }
    try await world.store.writeDomain { transaction throws(DomainError) in
      try ChapterDrafts.hold(novel: novel, chapter: 1, title: nil, body: ReviewWorld.body + " Typed.", base: head, in: &transaction)
    }
    await #expect(throws: ChapterSummaryError.conflict(chapter: 1, attempted: "S")) {
      _ = try await world.store.summaryWrite { transaction throws(ChapterSummaryError) in try ChapterSummary.save("S", novel: novel, chapter: 1, over: read, in: &transaction) }
    }
    let copy = try await world.store.read { transaction in try DraftWorkingCopy.read(novel: novel, chapter: 1, in: transaction.database) }
    #expect(copy?.content.body == ReviewWorld.body + " Typed.")
  }

  @Test func shouldRefuseASummaryOverAFinalChapterAmendedSinceItWasRead() async throws {
    let world = try await ReviewWorld()
    let novel = world.novel
    try await world.store.write { transaction in try ChapterWrites.finalize(novel: novel, chapter: 1, in: &transaction) }
    let read = try await world.store.summaryRead { transaction throws(ChapterSummaryError) in
      try ChapterSummary.source(novel: novel, chapter: 1, at: Date(), in: transaction)
    }
    #expect(read.final && read.body == "Final 1.")
    try await world.store.writeDomain { transaction throws(DomainError) in
      try FinalChapters.amend(novel: novel, chapter: 1, ChapterAmendment(content: "Final 1, amended."), in: &transaction)
    }
    await #expect(throws: ChapterSummaryError.conflict(chapter: 1, attempted: "S")) {
      _ = try await world.store.summaryWrite { transaction throws(ChapterSummaryError) in try ChapterSummary.save("S", novel: novel, chapter: 1, over: read, in: &transaction) }
    }
  }
}
