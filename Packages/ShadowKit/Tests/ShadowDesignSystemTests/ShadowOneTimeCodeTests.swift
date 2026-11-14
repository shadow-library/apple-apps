import Testing

@testable import ShadowDesignSystem

@Suite("One-time code")
struct ShadowOneTimeCodeTests {
  private let format = ShadowOneTimeCode()

  @Test(
    "should keep only digits and clamp to the length",
    arguments: [
      ("482913", "482913"),
      ("482 913", "482913"),
      ("482-913", "482913"),
      ("Your code is 482913. Don’t share it.", "482913"),
      ("48291377", "482913"),
      ("abc", ""),
      ("٤٨٢٩١٣", "482913"),
    ])
  func sanitizeDigits(input: String, expected: String) {
    #expect(format.sanitize(input) == expected)
  }

  @Test("should keep ASCII letters uppercased in alphanumeric codes")
  func sanitizeAlphanumeric() {
    let format = ShadowOneTimeCode(length: 6, characters: .alphanumeric)
    #expect(format.sanitize("ab-12 cd!") == "AB12CD")
    #expect(format.sanitize("éb12") == "B12")
  }

  @Test("should group six digits 3 + 3 by default and fall back to one group when the groups don't add up")
  func groups() {
    #expect(format.groups == [3, 3])
    #expect(format.groupRanges == [0..<3, 3..<6])
    #expect(ShadowOneTimeCode(length: 4).groups == [4])
    #expect(ShadowOneTimeCode(length: 8).groups == [4, 4])
    #expect(ShadowOneTimeCode(length: 6, groups: [2, 2]).groups == [6])
    #expect(ShadowOneTimeCode(length: 6, groups: [2, 2, 2]).groups == [2, 2, 2])
    #expect(ShadowOneTimeCode(length: 0).length == 1)
  }

  @Test("should report completion and the active box")
  func completion() {
    #expect(!format.isComplete("48291"))
    #expect(format.isComplete("482913"))
    #expect(format.activeIndex(in: "") == 0)
    #expect(format.activeIndex(in: "482") == 3)
    #expect(format.activeIndex(in: "482913") == 5)
    #expect(format.progress(of: "482").entered == 3)
    #expect(!format.progress(of: "482").isComplete)
  }

  @Test("should delete the last digit on Backspace")
  func backspace() {
    #expect(format.edit(from: "482", to: "48", replacingCurrent: false) == "48")
  }

  @Test("should fill every box from a pasted code")
  func paste() {
    #expect(format.edit(from: "", to: "482 913", replacingCurrent: false) == "482913")
    #expect(format.edit(from: "48", to: "48482913", replacingCurrent: false) == "484829")
  }

  @Test("should replace the whole code after an error instead of appending")
  func replaceAfterError() {
    #expect(format.edit(from: "482913", to: "4829137", replacingCurrent: true) == "7")
    #expect(format.edit(from: "482913", to: "482913551 004", replacingCurrent: true) == "551004")
    #expect(format.edit(from: "482913", to: "48291", replacingCurrent: true) == "")
    #expect(format.edit(from: "482913", to: "482913", replacingCurrent: true) == "482913")
  }

  @Test("should take a whole-text replacement as the new code even when it shares digits with the old one")
  func wholeReplacement() {
    #expect(format.edit(from: "482913", to: "482915", replacingCurrent: true) == "482915")
    #expect(format.edit(from: "482913", to: "182913", replacingCurrent: true) == "182913")
    #expect(format.edit(from: "482913", to: "551 004", replacingCurrent: true) == "551004")
    #expect(format.edit(from: "482913", to: "Code: 4829137", replacingCurrent: true) == "482913")
  }

  @Test("should fire completion once per completed code")
  func completesOnce() {
    var completion = ShadowOneTimeCodeCompletion(format: format, code: "")
    let fired = ["48291", "482913", "482913", "551004", "55100", "551004"].map { completion.update($0) }
    #expect(fired == [false, true, false, true, false, true])
  }

  @Test("should not fire for a code that was already complete when the field appeared")
  func prefilled() {
    var completion = ShadowOneTimeCodeCompletion(format: format, code: "482913")
    let fired = completion.update("482913")
    #expect(!fired)
  }
}
