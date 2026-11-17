import Testing

@testable import NovelForgeCore

private let body = "The keeper counts the ships at the harbour wall.\n\nThe tide turns late tonight. The ferry waits by the empty pier.\n\nGulls cry over the water."
private let quote = "The tide turns late tonight."
private let start = body.jsIndexOf(quote)
private let prefix = "Night falls.\n\n"

private func draft(revision: Int = 5, saveSeq: Int = 9, id: String = "41", body: String = body, isolated: Bool = false) -> PassageDraft {
  PassageDraft(id: id, chapter: 3, revision: revision, saveSeq: saveSeq, body: body, isolated: isolated)
}

private func input(quote: String = quote, start: Int? = nil, end: Int? = nil, hash: String? = nil, comment: String = "  Make this tenser.\n") -> PassageContextInput {
  let from = start ?? body.jsIndexOf(quote)
  return PassageContextInput(
    chapter: 3, draftId: "41", revision: 5, saveSeq: 9, start: from, end: end ?? from + quote.jsLength, passageHash: hash ?? passageHash(quote), quote: quote, comment: comment)
}

private func context(
  revision: Int = 5, start: Int = start, end: Int = start + quote.jsLength, quote: String = quote, comment: String = "Make this tenser.", first: Int = 2, last: Int = 2
) -> ChatPassageContext {
  ChatPassageContext(
    chapter: 3, draftId: "41", revision: revision, saveSeq: 9, start: start, end: end, passageHash: passageHash(quote), quote: quote, comment: comment, firstParagraph: first,
    lastParagraph: last)
}

private final class Snapshots: @unchecked Sendable {
  var reads = 0
  let bodies: [Int: String]

  init(_ bodies: [Int: String] = [:]) { self.bodies = bodies }

  func read(_ draftId: String, _ revision: Int) -> String? {
    reads += 1
    return draftId == "41" ? bodies[revision] : nil
  }
}

private func resolve(_ inputs: [PassageContextInput], _ drafts: [PassageDraft], _ snapshots: Snapshots = Snapshots()) throws(PassageContextError) -> [ChatPassageContext] {
  try resolvePassageContexts(inputs, drafts: drafts, snapshot: snapshots.read)
}

private func refusal(_ inputs: [PassageContextInput], _ drafts: [PassageDraft], _ snapshots: Snapshots = Snapshots()) -> String? {
  do throws(PassageContextError) {
    _ = try resolve(inputs, drafts, snapshots)
    return nil
  } catch {
    return error.code
  }
}

// apps/novel-forge-server/tests/refinement/passage-context.spec.ts:111
struct PassageResolveSpecTests {
  @Test func shouldKeepAPassageThatStillStandsWhereItWasSelected() throws {
    #expect(try resolve([input()], [draft()]) == [context()])
  }

  @Test func shouldReAnchorAPassageTheDraftHasMovedSince() throws {
    let resolved = try #require(try resolve([input()], [draft(revision: 6, saveSeq: 12, body: prefix + body)]).first)
    #expect(
      resolved
        == ChatPassageContext(
          chapter: 3, draftId: "41", revision: 6, saveSeq: 12, start: start + prefix.jsLength, end: start + prefix.jsLength + quote.jsLength, passageHash: passageHash(quote),
          quote: quote,
          comment: "Make this tenser.", firstParagraph: 3, lastParagraph: 3))
  }

  @Test func shouldTellCopiesApartByTheWordsAroundThemInTheRevisionTheAuthorRead() throws {
    let snapshots = Snapshots([5: body])
    let resolved = try resolve([input()], [draft(revision: 6, body: prefix + body + "\n\n" + quote)], snapshots)
    #expect(resolved.first?.start == start + prefix.jsLength)
    #expect(snapshots.reads == 1)
  }

  @Test func shouldNotReadASnapshotForAPassageStillInPlace() throws {
    let snapshots = Snapshots([5: body])
    _ = try resolve([input()], [draft(revision: 6, body: body + " More.")], snapshots)
    #expect(snapshots.reads == 0)
  }

  @Test func shouldRefuseAPassageCutFromItsParagraphAndWrittenIntoAnother() {
    let moved = body.jsSplit(quote + " ").joined() + "\n\nAt last the bell rings. " + quote
    let snapshots = Snapshots([5: body])
    #expect(refusal([input()], [draft(revision: 6, body: moved)], snapshots) == "CHT_009")
    #expect(snapshots.reads == 1)
  }

  @Test func shouldTakeTheQuotesOneOccurrenceWhenNoEarlierRevisionCanShowWhatSurroundedIt() throws {
    let moved = body.jsSplit(quote + " ").joined() + "\n\nAt last the bell rings. " + quote
    let resolved = try resolve([input()], [draft(saveSeq: 10, body: moved)])
    #expect(resolved.first?.start == moved.jsIndexOf(quote))
  }

  @Test(arguments: [
    (
      "its words were edited",
      draft(revision: 6, body: "The keeper counts the ships at the harbour wall.\n\nThe tide turns early tonight. The ferry waits by the empty pier.\n\nGulls cry over the water.")
    ),
    ("it moved and now has copies the draft cannot tell apart", draft(saveSeq: 10, body: prefix + body + "\n\n" + quote)),
    ("the chapters draft was replaced", draft(id: "52")),
  ])
  func shouldRefuseAPassageThatChanged(_ name: String, _ row: PassageDraft) {
    #expect(refusal([input()], [row]) == "CHT_009", Comment(rawValue: name))
  }

  @Test func shouldRefuseAPassageFromAChapterWithNoDraft() {
    #expect(refusal([input()], []) == "CHT_009")
  }

  @Test(arguments: [
    ("a hash of other words", input(hash: passageHash("Something else."))),
    ("offsets of another length", input(end: start + quote.jsLength + 3)),
    ("a blank selection", input(quote: "\n\n", start: body.jsIndexOf("\n\n"))),
    ("half of a surrogate pair", input(quote: "Tide " + JSText.string(fromCodeUnits: [0xD83C] as [UInt16]), start: -1, end: 5)),
  ])
  func shouldRefuseAMalformedQuote(_ name: String, _ malformed: PassageContextInput) {
    #expect(refusal([malformed], [draft()]) == "CHT_010", Comment(rawValue: name))
  }

  @Test func shouldRefuseAnIsolatedChaptersPassage() {
    #expect(refusal([input()], [draft(isolated: true)]) == "CHT_011")
  }

  @Test func shouldNumberAPassageAcrossParagraphsAndNotCountATrailingBlankLine() throws {
    let across = "The ferry waits by the empty pier.\n\nGulls cry"
    let trailing = "The ferry waits by the empty pier.\n\n"
    let resolved = try resolve([input(quote: across), input(quote: trailing)], [draft()])
    #expect(resolved.map { [$0.firstParagraph, $0.lastParagraph] } == [[2, 3], [2, 2]])
  }

  @Test func shouldNotRefuseAStringCommentThatLostHalfOfASurrogatePairBecauseASwiftStringCannotHoldIt() throws {
    let lossy = JSText.string(fromCodeUnits: [0x68, 0xD83D] as [UInt16])
    #expect(lossy.jsLength == 1)
    #expect(try resolve([input(comment: lossy)], [draft()]).first?.comment == "h")
  }

  @Test func shouldRefuseNonSafeOffsetsAsMalformed() {
    #expect(refusal([input(start: Int.min, end: Int.min + quote.jsLength)], [draft()]) == "CHT_010")
    #expect(refusal([input(start: 0, end: Int.max)], [draft()]) == "CHT_010")
  }

  @Test func shouldReportTheFirstMalformedPassageBeforeAnyDraftIsRead() {
    let missing = PassageContextInput(chapter: 9, draftId: "1", revision: 1, saveSeq: nil, start: 0, end: 1, passageHash: "x", quote: "a", comment: "")
    #expect(refusal([missing, input(hash: "bad")], [draft()]) == "CHT_010")
  }
}

// apps/novel-forge-server/tests/refinement/passage-context.spec.ts:178
struct TurnContentSpecTests {
  @Test func shouldLeaveAMessageWithoutPassageCommentsAsItIs() {
    #expect(renderTurnContent("Tighten chapter 3.", contexts: nil) == "Tighten chapter 3.")
    #expect(renderTurnContent("Tighten chapter 3.", contexts: []) == "Tighten chapter 3.")
  }

  @Test func shouldListEachPassageAfterTheMessage() {
    let second = context(quote: "A \"pier\".\n\nGulls", comment: "", first: 2, last: 3)
    let range = "(chars \(start)–\(start + quote.jsLength))"
    #expect(
      renderTurnContent("Two things.", contexts: [context(), second])
        == [
          "Two things.", "", "Passage comments:", "1. Chapter 3, revision 5, ¶2 \(range)", "   Quote: \"The tide turns late tonight.\"", "   Comment: Make this tenser.",
          "2. Chapter 3, revision 5, ¶2–3 \(range)", "   Quote: \"A \"pier\".", "   ", "   Gulls\"", "   Comment: (none)",
        ].joined(separator: "\n"))
  }

  @Test func shouldSendTheCommentsAloneWhenTheMessageIsEmpty() {
    #expect(renderTurnContent("  ", contexts: [context()]).hasPrefix("Passage comments:\n1. Chapter 3"))
  }

  @Test func shouldKeepAQuotesLineBreaksAndNameEachScreenedPart() {
    let screens = turnScreens("Look.", contexts: [context(quote: "The keeper waits.\nword is the word.")])
    #expect(screens.map(\.source) == ["Your message", "The passage you quoted from chapter 3", "Your comment on chapter 3"])
    #expect(renderTurnContent("Look.", contexts: [context(quote: "a\nb")]).contains("Quote: \"a\n   b\""))
  }

  @Test func shouldReadTheMessageAndTheCommentsNeverTheQuotedChapterText() {
    #expect(authorWords("Two things.", contexts: [context(), context(comment: "")]) == "Two things.\n\nMake this tenser.")
    #expect(authorWords("", contexts: [context()]) == "Make this tenser.")
  }
}
