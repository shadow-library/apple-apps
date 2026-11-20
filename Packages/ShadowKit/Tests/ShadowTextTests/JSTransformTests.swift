import ShadowTestSupport
import Testing

@testable import ShadowText

struct JSTransformTests {
  private let iterations = 300

  @Test func shouldTrimLikeJavaScript() throws {
    let oracle = try JSOracle()
    try forAll(iterations: iterations, seed: 0xD03_0101) { random in
      let text = random.jsText()
      try expectExactlySame(text.jsTrim(), oracle.call("s => s.trim()", .string(text)), describe(text))
      try expectExactlySame(text.jsTrimStart(), oracle.call("s => s.trimStart()", .string(text)), describe(text))
      try expectExactlySame(text.jsTrimEnd(), oracle.call("s => s.trimEnd()", .string(text)), describe(text))
    }
  }

  @Test func shouldClassifyEveryCodePointAsJavaScriptWhitespaceExactly() throws {
    let oracle = try JSOracle()
    let source = """
      () => { const found = []; for (let c = 0; c <= 0x10FFFF; c++) { if (c >= 0xD800 && c <= 0xDFFF) continue; if (String.fromCodePoint(c).trim() === '') found.push(c); } return found; }
      """
    let swift = (0...0x10FFFF).compactMap(Unicode.Scalar.init).filter(JSText.isWhitespace).map { Int($0.value) }
    try expectExactlySame(swift, oracle.call(source), "every code point")
  }

  @Test func shouldLowercaseLikeJavaScript() throws {
    let oracle = try JSOracle()
    try forAll(iterations: iterations, seed: 0xD03_0102) { random in
      let text = random.jsText()
      try expectExactlySame(text.jsToLowerCase(), oracle.call("s => s.toLowerCase()", .string(text)), describe(text))
    }
  }

  @Test func shouldNormalizeLikeJavaScript() throws {
    let oracle = try JSOracle()
    let forms: [(JSNormalizationForm, String)] = [(.nfc, "NFC"), (.nfd, "NFD"), (.nfkc, "NFKC"), (.nfkd, "NFKD")]
    try forAll(iterations: iterations, seed: 0xD03_0103) { random in
      let text = random.jsText()
      for (form, name) in forms {
        try expectExactlySame(text.jsNormalize(form), oracle.call("(s, f) => s.normalize(f)", .string(text), .string(name)), "\(name) of \(describe(text))")
      }
    }
  }

  @Test func shouldSplitByAStringLikeJavaScript() throws {
    let oracle = try JSOracle()
    try forAll(iterations: iterations, seed: 0xD03_0104) { random in
      let text = random.jsText()
      let separator = random.chance(0.15) ? "" : random.jsNeedle(in: text)
      let limit: Int? = random.chance(0.5) ? nil : random.pick(from: [0, 1, 2, 3, -1, -4_294_967_295, 4_294_967_297])
      let javaScript = try oracle.call("(s, t, n) => s.split(t, n)", .string(text), .string(separator), limit.map { .number(Double($0)) } ?? .undefined)
      try expectSame(text.jsSplit(separator, limit: limit), javaScript, "\(describe(text)).split(\(describe(separator)), \(String(describing: limit)))")
    }
  }
}
