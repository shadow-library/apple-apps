import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

// apps/novel-forge-server/tests/refinement/passage-rewrite.spec.ts:24-34
private let body = [
  "The salle smelled of chalk. Again, the light came in bars.", "Corin flexed his right hand until the knuckles stopped aching.", "“Again,” Mara said.",
  "He was afraid of her, and he knew it.",
].joined(separator: "\n\n")
private let wrist = "flexed his right hand until the knuckles stopped aching."
private let wristRewrite = "worked his right wrist in slow circles until the old break stopped grinding."
private let fear = "He was afraid of her, and he knew it."
private let fearRewrite = "His grip had gone damp inside the glove."

private func replacingFirst(_ text: String, _ target: String, _ replacement: String) -> String {
  guard let range = text.range(of: target) else { return text }
  return text.replacingCharacters(in: range, with: replacement)
}

private let rewritten = replacingFirst(replacingFirst(body, wrist, wristRewrite), fear, fearRewrite)

/// A rewrite of chapter 3 anchored, as staging anchors it, to the first occurrence of `passage` in `text` (passage-rewrite.ts:114-122).
private func stamped(_ passage: String, _ replacement: String, in text: String = body, draft identity: String, label: String? = nil) throws -> DraftRewritePassage {
  let start = text.jsIndexOf(passage)
  try #require(start >= 0)
  let end = start + passage.jsLength
  let leading = passage.jsLength - passage.jsTrimStart().jsLength
  let context = anchorContext(text, start: start, end: end)
  let anchor: OrderedJSON = jsonObject([
    ("draftId", .string(identity)), ("revision", .int(1)), ("saveSeq", .int(0)), ("start", .int(Int64(start))), ("end", .int(Int64(end))),
    ("passageHash", .string(passageHash(passage))), ("paragraph", .int(Int64(paragraphAt(text, offset: start + leading)))),
    ("contextBefore", .string(context.contextBefore)), ("contextAfter", .string(context.contextAfter)),
  ])
  var pairs: [(key: String, value: OrderedJSON)] = [("chapter", .int(3)), ("passage", .string(passage)), ("replacement", .string(replacement))]
  if let label { pairs.append(("label", .string(label))) }
  pairs.append(("anchor", anchor))
  return try #require(DraftRewritePassage(OpFields(record: OrderedJSONObject(pairs))))
}

private func refusal(_ body: () throws(ApplyRefusal) -> String) -> ApplyRefusal? {
  do throws(ApplyRefusal) {
    _ = try body()
    return nil
  } catch {
    return error
  }
}

// passage-rewrite.spec.ts:283-345
@Suite("Rewritten body")
struct DraftRewrittenBodyTests {
  private func written(_ rewrites: [DraftRewritePassage], in text: String = body, draftId: String = "3") throws(ApplyRefusal) -> String {
    try PassageRewrite.rewrittenBody(text, draftId: draftId, chapter: 3, rewrites)
  }

  @Test func shouldWriteEveryRewriteFromTheEndOfTheTextBackSoEachAnchorStillHolds() throws {
    let rewrites = [try stamped(wrist, wristRewrite, draft: "3"), try stamped(fear, fearRewrite, draft: "3")]
    #expect(try written(rewrites) == rewritten)
  }

  @Test func shouldWriteRewritesThatOnlyTouchEndToStart() throws {
    let rewrites = [try stamped("Corin flexed", "Corin rolled", draft: "3"), try stamped(" his right hand", " his wrist", draft: "3")]
    #expect(try written(rewrites).contains("Corin rolled his wrist until"))
  }

  @Test func shouldRefuseTwoRewritesOfTheSameWords() throws {
    let rewrites = [try stamped("flexed his right hand", "rolled his wrist", draft: "3"), try stamped("his right hand until", "his hand till", draft: "3")]
    #expect(refusal { () throws(ApplyRefusal) in try written(rewrites) } == .overlapping(chapter: 3))
    let twice = try stamped(fear, fearRewrite, draft: "3")
    #expect(refusal { () throws(ApplyRefusal) in try written([twice, twice]) } == .overlapping(chapter: 3))
  }

  @Test func shouldWriteEachRewriteWhereAnEditElsewhereInTheChapterMovedIt() throws {
    let rewrites = [try stamped(wrist, wristRewrite, draft: "3"), try stamped(fear, fearRewrite, draft: "3")]
    #expect(try written(rewrites, in: "Dawn.\n\n\(body)") == "Dawn.\n\n\(rewritten)")
  }

  @Test(arguments: [
    replacingFirst(body, "knuckles stopped", "knuckles finally stopped"), replacingFirst(body, "Corin flexed", "Corin slowly flexed"), "Dawn.\n\n\(body)\n\n\(body)",
  ])
  func shouldRefuseARewriteNamingItWhenItNoLongerStands(_ edited: String) throws {
    let rewrite = try stamped(wrist, wristRewrite, draft: "3", label: "  the wrist injury ")
    let refused = refusal { () throws(ApplyRefusal) in try written([rewrite], in: edited) }
    #expect(refused == .stale(passage: "“the wrist injury”", chapter: 3))
    #expect(refused?.errorDescription?.contains("“the wrist injury” in chapter 3") == true)
  }

  @Test func shouldNameAnUnlabelledRewriteByItsParagraphAndRefuseOneWhoseDraftWasReplaced() throws {
    let rewrite = try stamped(wrist, wristRewrite, draft: "3", label: " ")
    let refused = refusal { () throws(ApplyRefusal) in try written([rewrite], draftId: "30") }
    #expect(refused?.errorDescription?.contains("¶2 in chapter 3") == true)
  }

  // RULES F14 (a): passage-rewrite.ts:71 (`!anchor`)
  @Test func shouldRefuseARewriteWithNoAnchorAsNoLongerStanding() throws {
    var rewrite = try stamped(wrist, wristRewrite, draft: "3")
    rewrite.anchor = nil
    #expect(refusal { () throws(ApplyRefusal) in try written([rewrite]) } == .stale(passage: "a passage", chapter: 3))
  }

  @Test func shouldLeaveARewriteInPlaceWhenOnlyACopyOfItsWordsAppearsElsewhere() throws {
    let rewrite = try stamped(wrist, wristRewrite, draft: "3")
    #expect(try written([rewrite], in: "\(body)\n\n\(wrist)") == "\(replacingFirst(body, wrist, wristRewrite))\n\n\(wrist)")
  }

  @Test func shouldReportTheFirstStaleRewriteBeforeAnyOverlap() throws {
    let first = try stamped("flexed his right hand", "rolled", draft: "3", label: "one")
    let second = try stamped("his right hand until", "hand till", draft: "3", label: "two")
    var gone = try stamped(fear, fearRewrite, draft: "3", label: "three")
    gone.anchor = nil
    #expect(refusal { () throws(ApplyRefusal) in try written([first, second, gone]) } == .stale(passage: "“three”", chapter: 3))
  }
}

/// Chapters 1 and 2 final, so the story cursor stands at 2; chapter 3 holds `body` as a draft (passage-rewrite.spec.ts:57-69).
private func workspace() async throws -> ChapterBook {
  let book = try await ChapterBook.make()
  try await book.finalized(through: 2)
  try await book.draft(3, body)
  return book
}

private func both(_ book: ChapterBook) async throws -> [DraftRewritePassage] {
  let identity = try #require(try await book.identity(3))
  return [try stamped(wrist, wristRewrite, draft: identity, label: "the wrist injury"), try stamped(fear, fearRewrite, draft: identity, label: "show the fear")]
}

// passage-rewrite.spec.ts:388-554 (ProposalApplyService passage rewrites), through the frame
@Suite("Passage rewrites applied", TestTimeLimit.standard)
struct DraftPassageRewriteTests {
  @Test func shouldWriteEverySelectedRewriteOfAChapterAsOnePassageRewrittenRevision() async throws {
    let book = try await workspace()
    let before = try await book.revisionCount(3)
    _ = try await book.perform(.passageRewrites(chapter: 3, try await both(book))).get()
    let content = try #require(try await book.draftContent(3))
    #expect(content.body == rewritten)
    #expect(content.summary == "It turns.")
    #expect(content.source.known == .passageRewritten)
    #expect(try await book.revisionCount(3) == before + 1)
  }

  @Test func shouldWriteOnlyTheRewritesTheAuthorKept() async throws {
    let book = try await workspace()
    _ = try await book.perform(.passageRewrites(chapter: 3, [try await both(book)[1]])).get()
    #expect(try await book.draftContent(3)?.body == replacingFirst(body, fear, fearRewrite))
  }

  @Test func shouldApplyALoneRewriteOpAsACallOfOne() async throws {
    let book = try await workspace()
    let rewrite = try await both(book)[0]
    _ = try await book.perform(.op(ChangeOp(operation: .draftRewritePassage(rewrite), metadata: OpMetadata(OpFields(record: OrderedJSONObject([])))))).get()
    #expect(try await book.draftContent(3)?.body == replacingFirst(body, wrist, wristRewrite))
  }

  @Test func shouldRefuseTwoSelectedRewritesOfTheSameWordsWritingNothing() async throws {
    let book = try await workspace()
    let identity = try #require(try await book.identity(3))
    let rewrites = [try stamped("flexed his right hand", "rolled his wrist", draft: identity), try stamped("his right hand until", "his hand till", draft: identity)]
    let before = try await book.revisionCount(3)
    #expect(applyRefusal(try await book.perform(.passageRewrites(chapter: 3, rewrites))) == .overlapping(chapter: 3))
    #expect(try await book.revisionCount(3) == before)
  }

  // RULES F14 (b): the body comes from the head this transaction reads
  @Test func shouldApplyAtTheShiftedOffsetsAfterAHandEditElsewhereInTheChapter() async throws {
    let book = try await workspace()
    let rewrites = try await both(book)
    try await book.save(3, "Dawn.\n\n\(body)", base: nil)
    _ = try await book.perform(.passageRewrites(chapter: 3, rewrites)).get()
    #expect(try await book.draftContent(3)?.body == "Dawn.\n\n\(rewritten)")
  }

  @Test func shouldApplyAfterASaveThatChangedOnlyTheSummary() async throws {
    let book = try await workspace()
    let rewrites = try await both(book)
    try await book.save(3, body, summary: "Corin loses the first touch.", base: nil)
    _ = try await book.perform(.passageRewrites(chapter: 3, rewrites)).get()
    let content = try #require(try await book.draftContent(3))
    #expect(content.body == rewritten)
    #expect(content.summary == "Corin loses the first touch.")
  }

  @Test func shouldRefuseARewriteWhosePassageWasEditedSoTheOthersStillApply() async throws {
    let book = try await workspace()
    let rewrites = try await both(book)
    let edited = replacingFirst(body, "knuckles stopped", "knuckles finally stopped")
    try await book.save(3, edited, base: nil)
    #expect(applyRefusal(try await book.perform(.passageRewrites(chapter: 3, rewrites))) == .stale(passage: "“the wrist injury”", chapter: 3))
    #expect(try await book.draftContent(3)?.body == edited)
    _ = try await book.perform(.passageRewrites(chapter: 3, [rewrites[1]])).get()
    #expect(try await book.draftContent(3)?.body == replacingFirst(edited, fear, fearRewrite))
  }

  // passage-rewrite.spec.ts:476 and RULES F14 (d)
  @Test func shouldRefuseAFinalChapterAndAnIsolatedDraft() async throws {
    let book = try await workspace()
    let rewrite = try stamped("tide", "sea", in: "The tide turns.", draft: try #require(try await book.identity(2)))
    #expect(applyRefusal(try await book.perform(.passageRewrites(chapter: 2, [rewrite]))) == .locked)

    let isolated = try await ChapterBook.make()
    let novel = isolated.novel
    _ = try await isolated.run { try ChapterDrafts.importDraft(novel: novel, chapter: 1, DraftImport(prose: body, isolated: true), base: nil, in: &$0) }
    let walled = try stamped(wrist, wristRewrite, draft: try #require(try await isolated.identity(1)))
    #expect(applyRefusal(try await isolated.perform(.passageRewrites(chapter: 1, [walled]))) == .isolated)
    #expect(try await isolated.draftContent(1)?.body == body)
  }

  @Test func shouldRefuseAChapterWithNoDraftAndWriteNothingForNoRewrites() async throws {
    let book = try await workspace()
    let rewrite = try stamped(wrist, wristRewrite, draft: "none")
    let missing = try await book.perform(.passageRewrites(chapter: 4, [rewrite]))
    #expect(throws: ApplyError.domain(.draftNotFound(4))) { try missing.get() }
    let nothing = try await book.perform(.passageRewrites(chapter: 3, [])).get()
    #expect(nothing.inverse == nil)
    #expect(nothing.priorState == nothing.postState)
  }

  // RULES F14 (c): a draft removed and brought back is another draft, so an anchor on the old one no longer holds
  @Test func shouldRefuseARewriteOfADraftThatWasRemovedAndRecreated() async throws {
    let book = try await workspace()
    let rewrites = try await both(book)
    let removal = try draftCall(#"{"op":"draft.remove","chapter":3}"#)
    let removed = try await book.perform(removal).get()
    _ = try await book.undo(removed.inverse, of: removal).get()
    #expect(try await book.draftContent(3)?.body == body)
    #expect(applyRefusal(try await book.perform(.passageRewrites(chapter: 3, rewrites))) == .stale(passage: "“the wrist injury”", chapter: 3))
  }

  // passage-rewrite.spec.ts:494
  @Test func shouldPutThePriorBodyBackWhenTheRewritesAreUndone() async throws {
    let book = try await workspace()
    let call = ContentCall.passageRewrites(chapter: 3, try await both(book))
    try await expectDraftRoundTrip(book, call)
    #expect(try await book.draftContent(3)?.body == body)
    #expect(try await book.headSource(3) == .chatEdited)
  }

  // passage-rewrite.spec.ts:504
  @Test func shouldPutBackTheBodyAsItStoodBeforeARelocatedApplyTheEditElsewhereIncluded() async throws {
    let book = try await workspace()
    let call = ContentCall.passageRewrites(chapter: 3, try await both(book))
    try await book.save(3, "Dawn.\n\n\(body)", base: nil)
    let applied = try await book.perform(call).get()
    _ = try await book.undo(applied.inverse, of: call).get()
    #expect(try await book.draftContent(3)?.body == "Dawn.\n\n\(body)")
  }

  // passage-rewrite.spec.ts:514: the working copy is this port's autosave; settled before the apply, it is what the undo keeps
  @Test func shouldKeepAnAutosaveSettledBeforeTheApplyWhenTheRewritesAreUndone() async throws {
    let book = try await workspace()
    let novel = book.novel
    let call = ContentCall.passageRewrites(chapter: 3, try await both(book))
    let head = try #require(try await book.head(3))
    try await book.run { try ChapterDrafts.hold(novel: novel, chapter: 3, title: nil, body: "Dawn.\n\n\(body)", base: head, in: &$0) }
    let context = book.applyContext()
    let applied = try await book.run { transaction in
      try DraftHandlers.settleWorkingCopies(chapters: [3], novel: novel, in: &transaction)
      return try ApplyFrame.perform(call, context: context, in: &transaction)
    }
    #expect(try await book.draftContent(3)?.body == "Dawn.\n\n\(rewritten)")
    _ = try await book.undo(applied.inverse, of: call).get()
    #expect(try await book.draftContent(3)?.body == "Dawn.\n\n\(body)")
  }

  @Test func shouldRefuseToRewriteOverAnUnsettledWorkingCopy() async throws {
    let book = try await workspace()
    let novel = book.novel
    let head = try #require(try await book.head(3))
    try await book.run { try ChapterDrafts.hold(novel: novel, chapter: 3, title: nil, body: "Dawn.\n\n\(body)", base: head, in: &$0) }
    #expect(applyRefusal(try await book.perform(.passageRewrites(chapter: 3, try await both(book)))) == .unsettledWorkingCopy(chapter: 3))
    #expect(try await book.draftContent(3)?.body == body)
    #expect(try await book.workingCopy(3)?.content.body == "Dawn.\n\n\(body)")
  }

  // saveHandWrittenDraft normalizes the body it writes (draft-save.ts:56)
  @Test func shouldNormalizeTheLineEndingsAReplacementBrings() async throws {
    let book = try await workspace()
    let rewrite = try stamped(fear, "Damp.\r\nCold.\rStill.", draft: try #require(try await book.identity(3)))
    _ = try await book.perform(.passageRewrites(chapter: 3, [rewrite])).get()
    #expect(try await book.draftContent(3)?.body == replacingFirst(body, fear, "Damp.\nCold.\nStill."))
  }

  @Test func shouldClearTheRestoredVersionMarkOnARewrite() async throws {
    let book = try await workspace()
    let novel = book.novel
    let first = try #require(try await book.head(3))
    let second = try await book.draft(3, "Other.")
    _ = try await book.run { try DraftVersions.restore(novel: novel, chapter: 3, revision: first, base: second, in: &$0) }
    #expect(try await book.draftContent(3)?.restoredFrom == first)
    _ = try await book.perform(.passageRewrites(chapter: 3, [try await both(book)[1]])).get()
    #expect(try await book.draftContent(3)?.restoredFrom == nil)
  }
}
