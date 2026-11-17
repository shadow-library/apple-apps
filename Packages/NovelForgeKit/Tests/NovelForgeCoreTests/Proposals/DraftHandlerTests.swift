import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

typealias DraftApplyResult = Result<AppliedStep, ApplyError>

extension ChapterBook {
  func applyContext(_ intent: ApplyIntent = .apply) -> ApplyContext {
    ApplyContext(novel: novel, intent: intent, now: Date(timeIntervalSince1970: 1_700_000_000))
  }

  /// One call through the frame, in a write of its own; `faulted` writes past the projection faults a test planted.
  func perform(_ call: ContentCall, intent: ApplyIntent = .apply, faulted: Bool = false) async throws -> DraftApplyResult {
    let context = applyContext(intent)
    let write: BookWrite<DraftApplyResult> = { transaction in
      do throws(ApplyError) {
        return .success(try ApplyFrame.perform(call, context: context, in: &transaction))
      } catch {
        return .failure(error)
      }
    }
    return faulted ? try await store.write(write) : try await run(write)
  }

  /// An inverse written back through the frame, its refs named by the call it undoes.
  func undo(_ inverse: OrderedJSONObject?, of call: ContentCall) async throws -> DraftApplyResult {
    let context = applyContext(.undo)
    let inverse = try #require(inverse)
    return try await run { transaction in
      do throws(ApplyError) {
        let step = try ApplyFrame.perform(call, context: context, in: &transaction) { _, context, transaction throws(ApplyError) in
          try DraftHandlers.undo(inverse, context: context, in: &transaction)
        }
        return .success(step)
      } catch {
        return .failure(error)
      }
    }
  }

  func identity(_ chapter: Int) async throws -> String? {
    let novel = novel
    return try await store.read { try DraftIdentity.current(novel: novel, chapter: chapter, in: $0) }
  }

  func headSource(_ chapter: Int) async throws -> DraftSource? {
    try await draftContent(chapter)?.source.known
  }
}

func applyRefusal(_ result: DraftApplyResult) -> ApplyRefusal? {
  guard case .failure(.refused(let refusal)) = result else { return nil }
  return refusal
}

func draftCall(_ json: String) throws -> ContentCall {
  .op(try #require(try applyOps(json).first))
}

func draftState(_ step: AppliedStep, prior: Bool, chapter: Int) -> ArtifactState? {
  (prior ? step.priorState : step.postState)[JSString("draft:\(chapter)")]
}

/// Apply, undo, redo and undo again: each undo lands on the content the apply found, each redo on what the apply left.
func expectDraftRoundTrip(_ book: ChapterBook, _ call: ContentCall, sourceLocation: SourceLocation = #_sourceLocation) async throws {
  let applied = try await book.perform(call).get()
  #expect(applied.priorState != applied.postState, sourceLocation: sourceLocation)
  let undone = try await book.undo(applied.inverse, of: call).get()
  #expect(undone.priorState == applied.postState, sourceLocation: sourceLocation)
  #expect(undone.postState == applied.priorState, sourceLocation: sourceLocation)
  let redone = try await book.perform(call, intent: .redo).get()
  #expect(redone.postState == applied.postState, sourceLocation: sourceLocation)
  let again = try await book.undo(redone.inverse, of: call).get()
  #expect(again.postState == applied.priorState, sourceLocation: sourceLocation)
}

private func inverseJSON(_ text: String) throws -> OrderedJSONObject {
  try #require(try OrderedJSON(parsing: text).objectValue)
}

// apps/novel-forge-server/tests/refinement/proposal-draft-ops.spec.ts and apply/draft.handler.ts:37-108
@Suite("Draft handlers", .timeLimit(.minutes(3)))
struct DraftHandlerTests {
  // proposal-draft-ops.spec.ts:29, :62
  @Test func shouldWriteAChatEditAsAChatEditedRevisionKeepingTheFieldsItLeavesOut() async throws {
    let book = try await ChapterBook.make()
    try await book.draft(1, "The ferry waits.")
    let applied = try await book.perform(try draftCall(#"{"op":"draft.update","chapter":1,"title":"Slack Water"}"#)).get()
    let content = try #require(try await book.draftContent(1))
    #expect(content.title == "Slack Water")
    #expect(content.body == "The ferry waits.")
    #expect(content.summary == "It turns.")
    #expect(content.source.known == .chatEdited)
    #expect(try await book.revisionCount(1) == 2)
    let restore = #"{"op":"draft.update","chapter":1,"title":null,"body":"The ferry waits.","summary":"It turns.","isolated":false,"generator":"human"}"#
    #expect(applied.inverse == (try inverseJSON(restore)))
  }

  @Test func shouldNormalizeTheLineEndingsOfAChatWrittenBody() async throws {
    let book = try await ChapterBook.make()
    try await book.draft(1)
    _ = try await book.perform(try draftCall(#"{"op":"draft.update","chapter":1,"body":"One.\r\nTwo.\rThree."}"#)).get()
    #expect(try await book.draftContent(1)?.body == "One.\nTwo.\nThree.")
  }

  // draft.handler.ts:40, :44 and passage-rewrite.spec.ts:179
  @Test func shouldRefuseEveryWriteToAFinalChapter() async throws {
    let book = try await ChapterBook.make()
    try await book.finalized(through: 1)
    try await book.draft(2)
    let before = try await book.revisionCount(1)
    for json in [#"{"op":"draft.update","chapter":1,"body":"Again."}"#, #"{"op":"draft.update","chapter":1,"title":"T"}"#, #"{"op":"draft.remove","chapter":1}"#] {
      #expect(applyRefusal(try await book.perform(try draftCall(json))) == .locked, "\(json)")
    }
    #expect(try await book.revisionCount(1) == before)
  }

  // proposal-draft-ops.spec.ts:55
  @Test func shouldRefuseToRewriteAnIsolatedDraftsProseTheChatCouldNotRead() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    _ = try await book.run { try ChapterDrafts.importDraft(novel: novel, chapter: 1, DraftImport(prose: "Walled off.", isolated: true), base: nil, in: &$0) }
    let outcome = try await book.perform(try draftCall(#"{"op":"draft.update","chapter":1,"body":"A blind rewrite."}"#))
    #expect(applyRefusal(outcome) == .isolated)
    #expect(try await book.revisionCount(1) == 1)
  }

  // proposal-draft-ops.spec.ts:62, :73
  @Test(arguments: [#"{"op":"draft.update","chapter":1,"title":"Slack Water"}"#, #"{"op":"draft.update","chapter":1,"title":"Slack Water","body":"Walled off."}"#])
  func shouldStillLetATitleOrTheBodyItHoldsThroughOnAnIsolatedDraft(_ json: String) async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    _ = try await book.run { try ChapterDrafts.importDraft(novel: novel, chapter: 1, DraftImport(prose: "Walled off.", isolated: true), base: nil, in: &$0) }
    _ = try await book.perform(try draftCall(json)).get()
    let content = try #require(try await book.draftContent(1))
    #expect(content.title == "Slack Water")
    #expect(content.body == "Walled off.")
    #expect(content.isolated)
  }

  // proposal-draft-ops.spec.ts:135, :163
  @Test func shouldStartAChatWrittenDraftStandardAndOnlyAtTheNextWritableChapter() async throws {
    let book = try await ChapterBook.make()
    let ahead = try await book.perform(try draftCall(#"{"op":"draft.update","chapter":3,"body":"Written ahead of a gap."}"#))
    #expect(throws: ApplyError.domain(.notNextChapter(chapter: 3, next: 1))) { try ahead.get() }
    #expect(try await book.draftContent(3) == nil)
    let started = try await book.perform(try draftCall(#"{"op":"draft.update","chapter":1,"body":"A new chapter."}"#)).get()
    let content = try #require(try await book.draftContent(1))
    #expect(content.generator.known == .standard)
    #expect(!content.isolated)
    #expect(content.source.known == .chatEdited)
    #expect(content.title == nil)
    #expect(started.inverse == (try inverseJSON(#"{"op":"draft.remove","chapter":1}"#)))
  }

  // draft.handler.ts:45
  @Test func shouldRefuseToStartADraftWithoutABody() async throws {
    let book = try await ChapterBook.make()
    #expect(applyRefusal(try await book.perform(try draftCall(#"{"op":"draft.update","chapter":1,"title":"Only a title"}"#))) == .notAllowed)
  }

  // next-chapter.ts:18 inside one apply: the second start sees the first
  @Test func shouldStartChaptersInOrderWithinOneApply() async throws {
    let book = try await ChapterBook.make()
    let context = book.applyContext()
    let first = try draftCall(#"{"op":"draft.update","chapter":1,"body":"One."}"#)
    let second = try draftCall(#"{"op":"draft.update","chapter":2,"body":"Two."}"#)
    let skipped = try draftCall(#"{"op":"draft.update","chapter":4,"body":"Four."}"#)
    let refusal = try await book.run { transaction -> ApplyError? in
      _ = try ApplyFrame.perform(first, context: context, in: &transaction)
      _ = try ApplyFrame.perform(second, context: context, in: &transaction)
      do throws(ApplyError) {
        _ = try ApplyFrame.perform(skipped, context: context, in: &transaction)
        return nil
      } catch {
        return error
      }
    }
    #expect(refusal == .domain(.notNextChapter(chapter: 4, next: 3)))
    #expect(try await book.draftContent(2)?.body == "Two.")
  }

  // proposal-draft-ops.spec.ts:173 and draft.handler.ts:97
  @Test func shouldRefuseToRemoveAMissingDraft() async throws {
    let book = try await ChapterBook.make()
    let outcome = try await book.perform(try draftCall(#"{"op":"draft.remove","chapter":1}"#))
    #expect(throws: ApplyError.domain(.draftNotFound(1))) { try outcome.get() }
  }

  // proposal-draft-ops.spec.ts:147, :155
  @Test func shouldBringARemovedIsolatedDraftBackWithItsContainment() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.draft(1, "Walled off.")
    try await book.run { transaction in
      var content = try #require(try DraftRecord.read(try DraftRecord.ref(novel: novel, chapter: 1), in: transaction).entry?.record.content)
      content.isolated = true
      content.generator = .known(.unrestricted)
      _ = try DraftRecord.revise(try DraftRecord.ref(novel: novel, chapter: 1), content, in: &transaction)
    }
    let call = try draftCall(#"{"op":"draft.remove","chapter":1}"#)
    let removed = try await book.perform(call).get()
    let restore = #"{"op":"draft.update","chapter":1,"title":null,"body":"Walled off.","summary":"It turns.","isolated":true,"generator":"unrestricted"}"#
    #expect(removed.inverse == (try inverseJSON(restore)))
    #expect(try await book.draftContent(1) != nil)
    #expect(draftState(removed, prior: false, chapter: 1) == .missing)
    let undone = try await book.undo(removed.inverse, of: call).get()
    let content = try #require(try await book.draftContent(1))
    #expect(content.isolated)
    #expect(content.generator.known == .unrestricted)
    #expect(undone.postState == removed.priorState)
  }

  @Test func shouldClearATitleTheUndoneEditFilled() async throws {
    let book = try await ChapterBook.make()
    try await book.draft(1)
    let call = try draftCall(#"{"op":"draft.update","chapter":1,"title":"Slack Water"}"#)
    let applied = try await book.perform(call).get()
    _ = try await book.undo(applied.inverse, of: call).get()
    #expect(try await book.draftContent(1)?.title == nil)
    #expect(try await book.headSource(1) == .chatEdited)
  }

  @Test(arguments: [
    #"{"op":"draft.update","chapter":2,"title":"Slack Water","body":"The ferry leaves without its keeper.","summary":"Gone."}"#,
    #"{"op":"draft.update","chapter":3,"body":"A new chapter."}"#, #"{"op":"draft.remove","chapter":2}"#,
  ])
  func shouldPutTheContentBackOnEveryUndoAndForwardOnEveryRedo(_ json: String) async throws {
    let book = try await ChapterBook.make()
    try await book.draft(1)
    try await book.draft(2, "The ferry waits.")
    try await expectDraftRoundTrip(book, try draftCall(json))
  }

  @Test func shouldRefuseAnInverseItCannotRead() async throws {
    let book = try await ChapterBook.make()
    try await book.draft(1)
    let call = try draftCall(#"{"op":"draft.remove","chapter":1}"#)
    for inverse in [#"{"op":"draft.update","chapter":1}"#, #"{"op":"premise.update","chapter":1}"#, #"{"op":"draft.remove","chapter":0}"#] {
      #expect(applyRefusal(try await book.undo(try inverseJSON(inverse), of: call)) == .malformedInverse, "\(inverse)")
    }
    #expect(try await book.draftContent(1) != nil)
  }

  // proposal-draft-ops.spec.ts:94, :125: later chapters go stale through what their revisions rest on (D21), as after a hand edit
  @Test func shouldLeaveTheNextChapterStaleAfterAChatEditOrRemoval() async throws {
    let book = try await ChapterBook.make()
    try await book.draft(1)
    try await book.draft(2)
    #expect(try await book.lifecycle(2)?.stale == nil)
    _ = try await book.perform(try draftCall(#"{"op":"draft.update","chapter":1,"body":"The ferry leaves without its keeper."}"#)).get()
    #expect(try await book.lifecycle(2)?.stale != nil)

    let removal = try await ChapterBook.make()
    try await removal.draft(1)
    try await removal.draft(2)
    _ = try await removal.perform(try draftCall(#"{"op":"draft.remove","chapter":1}"#)).get()
    #expect(try await removal.lifecycle(2)?.stale != nil)
  }

  // RULES F11a (3): unreadable is never absent
  @Test func shouldRefuseADraftItCannotReadBeforeAnyWrite() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.draft(1)
    _ = try await book.store.write { transaction in
      _ = try transaction.revise(try DraftRecord.ref(novel: novel, chapter: 1), body: .object([:]))
    }
    let context = book.applyContext()
    let rewrite = try #require(DraftRewritePassage(OpFields(record: try inverseJSON(#"{"chapter":1,"passage":"a","replacement":"b"}"#))))
    let outcomes = try await book.store.write { transaction in
      var outcomes = [ApplyError?]()
      for operation in [ChangeOperation.draftUpdate(try #require(DraftUpdate(OpFields(record: try inverseJSON(#"{"chapter":1,"body":"x"}"#))))), .draftRewritePassage(rewrite)] {
        do throws(ApplyError) {
          _ = try DraftHandlers.apply(operation, context: context, in: &transaction)
          outcomes.append(nil)
        } catch {
          outcomes.append(error)
        }
      }
      do throws(ApplyError) {
        try DraftHandlers.settleWorkingCopies(chapters: [1], novel: novel, in: &transaction)
      } catch {
        outcomes.append(error)
      }
      #expect(transaction.changes.isEmpty)
      return outcomes
    }
    #expect(outcomes == [.unreadable(ref: "draft:1"), .unreadable(ref: "draft:1")])
  }
}

extension DraftHandlerTests {
  private static func fault(_ table: String) -> String {
    "INSERT INTO \(ProjectionFaults.table) (derivation, key, version, message) VALUES ('\(table)', '\(ProjectionFaults.wholeDerivation)', 1, 'probe')"
  }

  @Test func shouldRefuseEveryDraftWriteWhileTheLifecycleIsFaulted() async throws {
    let book = try await ChapterBook.make()
    try await book.draft(1)
    try await book.tamper(Self.fault(ChapterLifecycleEntry.databaseTableName))
    let record = try #require(try OrderedJSON(parsing: #"{"chapter":1,"passage":"a","replacement":"b"}"#).objectValue)
    let rewrite = try #require(DraftRewritePassage(OpFields(record: record)))
    let calls = [
      try draftCall(#"{"op":"draft.update","chapter":1,"body":"x"}"#), try draftCall(#"{"op":"draft.update","chapter":2,"body":"x"}"#), .passageRewrites(chapter: 1, [rewrite]),
    ]
    for (call, chapter) in zip(calls, [1, 2, 1]) {
      let outcome = try await book.perform(call, faulted: true)
      #expect(throws: ApplyError.domain(.lifecycleUnavailable(chapter))) { try outcome.get() }
    }
    #expect(try await book.revisionCount(1) == 1)
    #expect(try await book.draftContent(2) == nil)
  }

  @Test func shouldClearASummaryTheUndoneEditFilled() async throws {
    let book = try await ChapterBook.make()
    try await book.save(1, "The ferry waits.", base: nil)
    let call = try draftCall(#"{"op":"draft.update","chapter":1,"summary":"It waits."}"#)
    let applied = try await book.perform(call).get()
    #expect(try await book.draftContent(1)?.summary == "It waits.")
    _ = try await book.undo(applied.inverse, of: call).get()
    #expect(try await book.draftContent(1)?.summary == nil)
  }

  // next-chapter.ts:11 inside one apply: a chapter the apply removed is the next to write
  @Test func shouldRemoveAndRecreateAChapterWithinOneApply() async throws {
    let book = try await ChapterBook.make()
    try await book.draft(1)
    try await book.draft(2)
    let context = book.applyContext()
    let removal = try draftCall(#"{"op":"draft.remove","chapter":2}"#)
    let recreate = try draftCall(#"{"op":"draft.update","chapter":2,"body":"Again."}"#)
    try await book.run { transaction in
      _ = try ApplyFrame.perform(removal, context: context, in: &transaction)
      _ = try ApplyFrame.perform(recreate, context: context, in: &transaction)
    }
    let content = try #require(try await book.draftContent(2))
    #expect(content.body == "Again.")
    #expect(content.source.known == .chatEdited)
  }

  @Test func shouldClearTheRestoredVersionMarkOnAChatEdit() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    let first = try await book.draft(1, "A")
    let second = try await book.draft(1, "B")
    _ = try await book.run { try DraftVersions.restore(novel: novel, chapter: 1, revision: first, base: second, in: &$0) }
    #expect(try await book.draftContent(1)?.restoredFrom == first)
    _ = try await book.perform(try draftCall(#"{"op":"draft.update","chapter":1,"title":"T"}"#)).get()
    #expect(try await book.draftContent(1)?.restoredFrom == nil)
  }
}

// D23's working copy (nf_local_draft_working_copy) before a draft write: RULES F14 (e)
@Suite("Draft handlers and the working copy", .timeLimit(.minutes(3)))
struct DraftWorkingCopyTests {
  /// Chapter 1 committed as "A", with "AB unsynced" held over it on this device; returns the committed revision.
  private func held(_ book: ChapterBook) async throws -> String {
    let first = try await book.draft(1, "A")
    #expect(try await book.save(1, "AB unsynced", base: first) == .held(base: first))
    return first
  }

  @Test(arguments: [#"{"op":"draft.update","chapter":1,"body":"Chat."}"#, #"{"op":"draft.remove","chapter":1}"#])
  func shouldRefuseAWriteOverAnUnsettledWorkingCopy(_ json: String) async throws {
    let book = try await ChapterBook.make()
    _ = try await held(book)
    #expect(applyRefusal(try await book.perform(try draftCall(json))) == .unsettledWorkingCopy(chapter: 1))
    #expect(try await book.workingCopy(1)?.content.body == "AB unsynced")
    #expect(try await book.revisionCount(1) == 1)
    #expect(try await book.draftContent(1)?.body == "A")
  }

  @Test(arguments: [(#"{"op":"draft.update","chapter":1,"body":"Chat."}"#, "Chat."), (#"{"op":"draft.remove","chapter":1}"#, nil)])
  func shouldApplyOverTheWorkingCopyOnceSettledAndUndoToIt(_ json: String, _ body: String?) async throws {
    let book = try await ChapterBook.make()
    _ = try await held(book)
    let (novel, context, call) = (book.novel, book.applyContext(), try draftCall(json))
    let applied = try await book.run { transaction in
      try DraftHandlers.settleWorkingCopies(chapters: [1], novel: novel, in: &transaction)
      return try ApplyFrame.perform(call, context: context, in: &transaction)
    }
    #expect(draftState(applied, prior: false, chapter: 1)?.exists == (body != nil))
    if let body { #expect(try await book.draftContent(1)?.body == body) }
    #expect(try await book.workingCopy(1) == nil)
    let undone = try await book.undo(applied.inverse, of: call).get()
    #expect(undone.postState == applied.priorState)
    #expect(try await book.draftContent(1)?.body == "AB unsynced")
  }

  // a removal that synced in while this device held a copy over an older revision: settled, the copy is kept as a version beside the revision it
  // continued, and the removal can be undone
  @Test func shouldKeepACopyOverARemovedDraftAsAVersionSoTheRemovalCanBeUndone() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    let first = try await book.draft(1, "A")
    try await book.draft(1, "B")
    let call = try draftCall(#"{"op":"draft.remove","chapter":1}"#)
    let removed = try await book.perform(call).get()
    try await book.run { try ChapterDrafts.hold(novel: novel, chapter: 1, title: nil, body: "AB unsynced", base: first, in: &$0) }
    #expect(applyRefusal(try await book.undo(removed.inverse, of: call)) == .unsettledWorkingCopy(chapter: 1))
    try await book.run { try DraftHandlers.settleWorkingCopies(chapters: [1], novel: novel, in: &$0) }
    #expect(try await book.workingCopy(1) == nil)
    let undone = try await book.undo(removed.inverse, of: call).get()
    #expect(undone.postState == removed.priorState)
    #expect(try await book.draftContent(1)?.body == "B")
    let history = try #require(try await book.history(1))
    let kept = history.revisions.filter { $0.body.body?.body == "AB unsynced" }
    #expect(kept.map(\.parent) == [first])
    #expect(kept.first?.id != history.head)
  }

  @Test func shouldDropAWorkingCopyThatHoldsTheHeadsOwnText() async throws {
    let book = try await ChapterBook.make()
    let first = try await book.draft(1, "A")
    let novel = book.novel
    try await book.run { try ChapterDrafts.hold(novel: novel, chapter: 1, title: nil, body: "A", base: first, in: &$0) }
    _ = try await book.perform(try draftCall(#"{"op":"draft.update","chapter":1,"body":"Chat."}"#)).get()
    #expect(try await book.workingCopy(1) == nil)
    #expect(try await book.revisionCount(1) == 2)
  }

  @Test func shouldCommitTheWorkingCopyWhenAnApplySettlesIt() async throws {
    let book = try await ChapterBook.make()
    _ = try await held(book)
    let novel = book.novel
    try await book.run { try DraftHandlers.settleWorkingCopies(chapters: [1, 1, 2, 0], novel: novel, in: &$0) }
    #expect(try await book.draftContent(1)?.body == "AB unsynced")
    #expect(try await book.workingCopy(1) == nil)
  }

  @Test func shouldLeaveAFinalChaptersWorkingCopyToTheChapterEditor() async throws {
    let book = try await ChapterBook.make()
    try await book.finalized(through: 1)
    let novel = book.novel
    let head = try #require(try await book.head(1))
    try await book.run { try ChapterDrafts.hold(novel: novel, chapter: 1, title: nil, body: "Late.", base: head, in: &$0) }
    try await book.run { try DraftHandlers.settleWorkingCopies(chapters: [1], novel: novel, in: &$0) }
    #expect(try await book.workingCopy(1)?.content.body == "Late.")
    #expect(try await book.head(1) == head)
  }

  @Test func shouldNameTheChaptersADraftOpWrites() throws {
    let ops = try applyOps(
      #"{"op":"draft.update","chapter":2,"body":"x"},{"op":"draft.remove","chapter":4},{"op":"premise.update","premise":"P."},{"op":"draft.rewrite_passage","chapter":5,"passage":"a","replacement":"b"}"#
    )
    #expect(DraftHandlers.draftChapters(of: ops) == [2, 4, 5])
  }
}
