import ShadowText
import Testing

@testable import NovelForgeCore

struct PassageAnchorSpecTests {
  private func anchor(_ body: String, _ start: Int, _ end: Int) -> PassageAnchor {
    let passage = body.jsSlice(start, end)
    let context = anchorContext(body, start: start, end: end)
    return PassageAnchor(start: start, end: end, passageHash: passageHash(passage), passage: passage, contextBefore: context.contextBefore, contextAfter: context.contextAfter)
  }

  @Test func shouldHashTheEmptyStringAsSha256DoesAndPadEveryByte() {
    #expect(passageHash("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(passageHash("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }

  @Test func shouldBeFreshWhereTheOffsetsStillHoldThePassage() {
    let body = "The lamp burned low. She walked on."
    #expect(locatePassage(body, anchor: anchor(body, 4, 19)) == .fresh(start: 4, end: 19))
  }

  @Test func shouldRelocateAPassageThatMovedCleanly() {
    let body = "The lamp burned low. She walked on."
    let moved = "Intro. " + body
    #expect(locatePassage(moved, anchor: anchor(body, 4, 19)) == .relocated(start: 11, end: 26))
  }

  @Test func shouldBeStaleWhenTheMovedPassageOccursTwice() {
    let bare = PassageAnchor(start: 2, end: 5, passageHash: passageHash("abc"), passage: "abc", contextBefore: "", contextAfter: "")
    #expect(locatePassage("abc abc", anchor: bare) == .stale)
    #expect(locatePassage("zabc", anchor: bare) == .relocated(start: 1, end: 4))
  }

  @Test func shouldBeStaleWhenThePassageWasEdited() {
    let body = "The lamp burned low."
    #expect(locatePassage("The lamp burned high.", anchor: anchor(body, 4, 19)) == .stale)
  }

  @Test func shouldBeStaleWhenTheAnchorHashDoesNotMatchItsPassage() {
    let body = "The lamp burned low."
    let tampered = PassageAnchor(start: 4, end: 8, passageHash: "00", passage: "lamp", contextBefore: "The ", contextAfter: " burned low.")
    #expect(locatePassage(body, anchor: tampered) == .stale)
  }

  @Test func shouldTreatAnEmptyNeedleAsAmbiguousLikeIndexOfDoes() {
    let empty = PassageAnchor(start: 0, end: 1, passageHash: passageHash(""), passage: "", contextBefore: "", contextAfter: "")
    #expect(locatePassage("abc", anchor: empty) == .stale)
    #expect(locatePassage("", anchor: PassageAnchor(start: 3, end: 3, passageHash: passageHash(""), passage: "", contextBefore: "x", contextAfter: "")) == .stale)
  }

  @Test func shouldReadNegativeAndReversedOffsetsAsSliceDoes() {
    let body = "abcdef"
    let reversed = PassageAnchor(start: 4, end: 2, passageHash: passageHash(""), passage: "", contextBefore: "", contextAfter: "")
    #expect(locatePassage(body, anchor: reversed) == .fresh(start: 4, end: 2))
    let pastEnd = PassageAnchor(start: 9, end: 9, passageHash: passageHash(""), passage: "", contextBefore: "", contextAfter: "")
    #expect(locatePassage("abc", anchor: pastEnd) == .fresh(start: 9, end: 9))
    let fromEnd = PassageAnchor(start: -2, end: 6, passageHash: passageHash("ef"), passage: "ef", contextBefore: "", contextAfter: "")
    #expect(locatePassage(body, anchor: fromEnd) == .relocated(start: 4, end: 6))
  }

  @Test func shouldNotTrapOnOffsetsAtTheIntegerLimits() {
    let anchor = PassageAnchor(start: Int.min, end: Int.max, passageHash: "", passage: "", contextBefore: "", contextAfter: "")
    #expect(locatePassage("abc", anchor: anchor) == .stale)
    #expect(anchorContext("abc", start: Int.min, end: Int.max).contextAfter == "")
  }

  @Test func shouldTakeAtMostThirtyTwoUnitsOfContextEitherSide() {
    let body = String(repeating: "a", count: 40) + "X" + String(repeating: "b", count: 40)
    let context = anchorContext(body, start: 40, end: 41)
    #expect(context.contextBefore == String(repeating: "a", count: 32))
    #expect(context.contextAfter == String(repeating: "b", count: 32))
  }

  @Test func shouldDropTheHalfPairThatAContextCutsThroughWhichAStringCannotHold() {
    #expect(anchorContext("😀", start: 1, end: 1).contextBefore == "")
    #expect(anchorContext("😀", start: 1, end: 1).contextAfter == "")
  }

  @Test func shouldHashALoneSurrogateSliceAsNodeDoesAsReplacementCharacter() {
    let body = "😀"
    let halfHash = passageHash("\u{FFFD}")
    let half = PassageAnchor(start: 0, end: 1, passageHash: halfHash, passage: "", contextBefore: "", contextAfter: "")
    #expect(locatePassage(body, anchor: half) == .fresh(start: 0, end: 1))
    let fresh = PassageAnchor(start: 0, end: 1, passageHash: halfHash, passage: "\u{FFFD}", contextBefore: "", contextAfter: "")
    #expect(locatePassage(body, anchor: fresh) == .fresh(start: 0, end: 1))
  }

  @Test func shouldKeepThePassagesOwnWhitespaceAroundTheReplacement() {
    #expect(fitReplacement("\n\nold text\n", "  new  ") == "\n\nnew\n")
    #expect(fitReplacement("\u{00A0}x\u{2028}", "\u{FEFF}y\u{FEFF}") == "\u{00A0}y\u{2028}")
    #expect(fitReplacement("", "  y ") == "y")
  }

  @Test func shouldSpliceAReplacementByCodeUnitOffsets() {
    #expect(replacePassage("a😀b", start: 1, end: 3, replacement: "X") == "aXb")
    #expect(replacePassage("abc", start: -2, end: 99, replacement: "X") == "aX")
    #expect(replacePassage("abc", start: 2, end: 1, replacement: "X") == "abXbc")
  }

  @Test func shouldPublishTheReferenceLimits() {
    #expect(maxPassageChars == 6000)
    #expect(anchorContextChars == 32)
  }
}
