import Foundation
import Testing

@testable import NovelForgeCore

struct SwiftDefaultsTests {
  @Test func shouldCountCodeUnitsWhereSwiftCountsGraphemes() {
    #expect("👍🏽".count == 1)
    #expect("👍🏽".jsLength == 4)
    #expect(Array("e\u{301}").count == 1)
    #expect("e\u{301}".jsCodePoints.count == 2)
  }

  @Test func shouldKeepCanonicallyEquivalentStringsApart() {
    #expect("é" == "e\u{301}")
    #expect(!"é".jsEquals("e\u{301}"))
    #expect(Set(["é", "e\u{301}"]).count == 1)
    #expect(Set([JSString("é"), JSString("e\u{301}")]).count == 2)
    #expect(["é", "e\u{301}"].jsUnique().count == 2)
  }

  @Test func shouldSearchByCodeUnitsWhereSwiftSearchesByCharacters() {
    #expect(!"abc".contains(""))
    #expect("abc".jsIncludes(""))
    #expect(!"e\u{301}".hasPrefix("e"))
    #expect("e\u{301}".jsStartsWith("e"))
    #expect(!"e\u{301}x".contains("e"))
    #expect("e\u{301}x".jsIndexOf("e") == 0)
    #expect("café".hasSuffix("e\u{301}"))
    #expect(!"café".jsEndsWith("e\u{301}"))
  }

  @Test func shouldOrderByCodeUnitsWhereSwiftOrdersByScalars() {
    #expect("\u{E000}" < "😀")
    #expect(!JSText.codeUnitPrecedes("\u{E000}", "😀"))
    #expect(["\u{E000}", "😀"].jsSorted() == ["😀", "\u{E000}"])
  }

  @Test func shouldLowercaseAFinalSigmaWhereSwiftDoesNot() {
    #expect("ΟΔΟΣ".lowercased() == "οδοσ")
    #expect("ΟΔΟΣ".jsToLowerCase() == "οδος")
    #expect("ΟΔΟΣ'Α".jsToLowerCase() == "οδοσ'α")
    #expect("Σ".jsToLowerCase() == "σ")
    #expect("İ".jsToLowerCase().unicodeScalars.map(\.value) == [0x69, 0x307])
  }

  @Test func shouldTrimTheECMAScriptWhitespaceSet() {
    let text = "\u{FEFF}\u{85}x\u{180E}\u{200B}\u{3000}"
    #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) != text.jsTrim())
    #expect(text.jsTrim() == "\u{85}x\u{180E}\u{200B}")
    #expect(("\u{85}" as Character).isWhitespace)
    #expect(!("\u{FEFF}" as Character).isWhitespace)
  }

  @Test func shouldKeepTrailingEmptyPiecesWhenSplitting() {
    #expect("a,b,".split(separator: ",").count == 2)
    #expect("a,b,".jsSplit(",") == ["a", "b", ""])
    #expect(",a".jsSplit(",") == ["", "a"])
    #expect("a,b,c".jsSplit(",", limit: 2) == ["a", "b"])
    #expect("a,b".jsSplit(",", limit: -1) == ["a", "b"])
    #expect("".jsSplit("") == [])
    #expect("".jsSplit(",") == [""])
  }

  @Test func shouldRoundHalvesTowardsPositiveInfinity() {
    #expect((-2.5).rounded() == -3)
    #expect(JSMath.round(-2.5) == -2)
    #expect(JSMath.round(2.5) == 3)
    #expect(JSMath.round(-0.4).sign == .minus)
    #expect(JSMath.round(0.49999999999999994) == 0)
  }

  @Test func shouldFormatFixedDigitsFromTheExactValueWithTiesAwayFromZero() {
    #expect(String(format: "%.2f", 0.125) == "0.12")
    #expect(0.125.jsToFixed(2) == "0.13")
    #expect(String(format: "%.0f", 2.5) == "2")
    #expect(2.5.jsToFixed(0) == "3")
    #expect((-2.5).jsToFixed(0) == "-3")
    #expect(1.005.jsToFixed(2) == "1.00")
    #expect((-0.04).jsToFixed(1) == "-0.0")
    #expect((-0.0).jsToFixed(1) == "0.0")
    #expect(1e21.jsToFixed(1) == "1e+21")
    #expect(12.0.jsToFixed(1) == "12.0")
    #expect(0.5.jsToFixed(-3) == "1")
    #expect(0.5.jsToFixed(500) == "0.50000000000000000000")
  }

  @Test func shouldWriteNumbersLikeJavaScript() {
    #expect("\(5.0)" == "5.0")
    #expect(5.0.jsString == "5")
    #expect("\(1e-7)" == "1e-07")
    #expect(1e-7.jsString == "1e-7")
    #expect(1e21.jsString == "1e+21")
    #expect(123_456_789_012_345_680_000.0.jsString == "123456789012345680000")
    #expect((-0.0).jsString == "0")
    #expect(0.000001.jsString == "0.000001")
  }

  @Test func shouldParseNumbersLikeTheNumberFunction() {
    #expect(Double(" 5") == nil)
    #expect(JSNumber.from(" 5\u{FEFF}") == 5)
    #expect(Double("") == nil)
    #expect(JSNumber.from("") == 0)
    #expect(Double("inf") == .infinity)
    #expect(JSNumber.from("inf").isNaN)
    #expect(Int("5.") == nil)
    #expect(JSNumber.from("5.") == 5)
    #expect(JSNumber.from("0x1F") == 31)
    #expect(JSNumber.from("-0x1F").isNaN)
    #expect(JSNumber.from("1_000").isNaN)
    #expect(JSNumber.from("٣").isNaN)
    #expect(JSNumber.from("-0").sign == .minus)
  }
}
