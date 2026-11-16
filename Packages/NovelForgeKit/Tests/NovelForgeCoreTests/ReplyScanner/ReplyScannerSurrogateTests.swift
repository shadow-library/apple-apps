import Testing

@testable import NovelForgeCore

private func units(_ text: String) -> [UInt16] {
  Array(text.utf16)
}

struct ReplyScannerSurrogateTests {
  @Test func shouldJoinARawPairSplitAcrossChunks() {
    let high: UInt16 = 0xD83D
    let low: UInt16 = 0xDE00
    var scanner = ReplyScanner()
    let first = scanner.consume(utf16: units(#"{"reply":"a"#) + [high])
    #expect(first == [.reply("a")])
    let second = scanner.consume(utf16: [low] + units(#"b"}"#))
    #expect(second == [.reply("😀b")])
  }

  @Test func shouldJoinAPairWrittenAsTwoEscapesSplitAcrossChunks() {
    var scanner = ReplyScanner()
    #expect(scanner.consume(#"{"reply":"a\ud83d"#) == [.reply("a")])
    #expect(scanner.consume(#"\ude00b"}"#) == [.reply("😀b")])
    #expect(scanner.state == .completed)
  }

  @Test func shouldJoinAPairWrittenAsTwoEscapesSplitInsideTheSecondEscape() {
    let result = scan(chunks: [units(#"{"reply":"x\ud83d\ud"#), units(#"e00"}"#)])
    #expect(result.reply == "x😀")
  }

  @Test func shouldReplaceALoneHighSurrogateAtTheEndOfTheReplyWithTheReplacementCharacter() {
    var scanner = ReplyScanner()
    #expect(scanner.consume(#"{"reply":"a\ud83d"}"#) == [.reply("a\u{FFFD}")])
    #expect(scanner.state == .completed)
  }

  @Test func shouldReplaceAHighSurrogateTheStreamNeverCompletesWhenFinishing() {
    var scanner = ReplyScanner()
    #expect(scanner.consume(#"{"reply":"a\ud83d"#) == [.reply("a")])
    #expect(scanner.finish() == [.reply("\u{FFFD}")])
    #expect(scanner.finish() == [])
    #expect(scanner.state == .replyFound)
  }

  @Test func shouldReplaceALoneLowSurrogate() {
    #expect(scan(#"{"reply":"a\ude00b"}"#).reply == "a\u{FFFD}b")
  }

  @Test func shouldReplaceAHighSurrogateFollowedByANonLowUnit() {
    #expect(scan(#"{"reply":"a\ud83d\u0041"}"#).reply == "a\u{FFFD}A")
    #expect(scan(#"{"reply":"a\ud83dB"}"#).reply == "a\u{FFFD}B")
  }

  @Test func shouldKeepTheLastHighSurrogateOfARunOfHighSurrogatesForItsPartner() {
    #expect(scan(#"{"reply":"\ud83d\ud83d\ude00"}"#).reply == "\u{FFFD}😀")
  }

  @Test func shouldReplaceALowSurrogateFollowedByAHighSurrogate() {
    #expect(scan(#"{"reply":"\ude00\ud83d\ude00"}"#).reply == "\u{FFFD}😀")
  }

  @Test func shouldReplaceRawLoneSurrogatesDeliveredAsCodeUnits() {
    let result = scan(chunks: [units(#"{"reply":"x"#) + [0xD83D, 0x0041, 0xDE00] + units(#"y"}"#)])
    #expect(result.reply == "x\u{FFFD}A\u{FFFD}y")
  }

  @Test func shouldNeverEmitAPieceEndingInAnUnpairedHighSurrogateWhileTheStreamIsStillOpen() {
    let result = scan(chunks: units(#"{"reply":"é😀\ud83d\ude00z"}"#).map { [$0] })
    #expect(result.reply == "é😀😀z")
    #expect(!result.replyPieces.contains { $0.contains("\u{FFFD}") })
  }
}
