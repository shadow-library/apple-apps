/// Scripts.txt of Unicode 17.0 as bun 1.4 reports it; `JSRegexBunFixtureTests` checks every code point against `Fixtures/regex/cases.json`.
enum JSRegexScript: Sendable {
  case han
  case hiragana
  case katakana
  case thai

  init?(name: String) {
    switch name {
    case "Han", "Hani": self = .han
    case "Hiragana", "Hira": self = .hiragana
    case "Katakana", "Kana": self = .katakana
    case "Thai": self = .thai
    default: return nil
    }
  }

  func contains(_ value: UInt32) -> Bool {
    ranges.contains { $0.contains(value) }
  }

  private var ranges: [ClosedRange<UInt32>] {
    switch self {
    case .han: Self.hanRanges
    case .hiragana: Self.hiraganaRanges
    case .katakana: Self.katakanaRanges
    case .thai: Self.thaiRanges
    }
  }

  private static let hanRanges: [ClosedRange<UInt32>] = [
    0x2E80...0x2E99, 0x2E9B...0x2EF3, 0x2F00...0x2FD5, 0x3005...0x3005, 0x3007...0x3007, 0x3021...0x3029, 0x3038...0x303B, 0x3400...0x4DBF, 0x4E00...0x9FFF,
    0xF900...0xFA6D, 0xFA70...0xFAD9, 0x1_6FE2...0x1_6FE3, 0x1_6FF0...0x1_6FF6, 0x2_0000...0x2_A6DF, 0x2_A700...0x2_B81D, 0x2_B820...0x2_CEAD, 0x2_CEB0...0x2_EBE0,
    0x2_EBF0...0x2_EE5D, 0x2_F800...0x2_FA1D, 0x3_0000...0x3_134A, 0x3_1350...0x3_3479,
  ]
  private static let hiraganaRanges: [ClosedRange<UInt32>] = [0x3041...0x3096, 0x309D...0x309F, 0x1_B001...0x1_B11F, 0x1_B132...0x1_B132, 0x1_B150...0x1_B152, 0x1_F200...0x1_F200]
  private static let katakanaRanges: [ClosedRange<UInt32>] = [
    0x30A1...0x30FA, 0x30FD...0x30FF, 0x31F0...0x31FF, 0x32D0...0x32FE, 0x3300...0x3357, 0xFF66...0xFF6F, 0xFF71...0xFF9D, 0x1_AFF0...0x1_AFF3, 0x1_AFF5...0x1_AFFB,
    0x1_AFFD...0x1_AFFE, 0x1_B000...0x1_B000, 0x1_B120...0x1_B122, 0x1_B155...0x1_B155, 0x1_B164...0x1_B167,
  ]
  private static let thaiRanges: [ClosedRange<UInt32>] = [0x0E01...0x0E3A, 0x0E40...0x0E5B]
}

enum JSRegexProperty: Sendable {
  case letter
  case number
  case uppercaseLetter
  case script(JSRegexScript)

  init?(expression: String) {
    let parts = expression.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    if parts.count == 2 {
      switch parts[0] {
      case "Script", "sc":
        guard let script = JSRegexScript(name: parts[1]) else { return nil }
        self = .script(script)
      case "General_Category", "gc": self.init(category: parts[1])
      default: return nil
      }
      return
    }
    self.init(category: expression)
  }

  private init?(category: String) {
    switch category {
    case "L", "Letter": self = .letter
    case "N", "Number": self = .number
    case "Lu", "Uppercase_Letter": self = .uppercaseLetter
    default: return nil
    }
  }

  func contains(_ value: UInt32) -> Bool {
    guard let scalar = Unicode.Scalar(value) else { return false }
    switch (self, scalar.properties.generalCategory) {
    case (.letter, .uppercaseLetter), (.letter, .lowercaseLetter), (.letter, .titlecaseLetter), (.letter, .modifierLetter), (.letter, .otherLetter): return true
    case (.number, .decimalNumber), (.number, .letterNumber), (.number, .otherNumber): return true
    case (.uppercaseLetter, .uppercaseLetter): return true
    case (.script(let script), _): return script.contains(value)
    default: return false
    }
  }
}

enum JSRegexClassItem: Sendable {
  case range(UInt32, UInt32)
  case digit(negated: Bool)
  case space(negated: Bool)
  case word(negated: Bool)
  case property(JSRegexProperty, negated: Bool)
}

struct JSRegexCharacterSet: Sendable {
  var items: [JSRegexClassItem]
  var negated: Bool
}

struct JSRegexMode: Sendable {
  static let asciiWordCharacters: [UInt32] = Array(0x30...0x39) + Array(0x41...0x5A) + Array(0x61...0x7A) + [0x5F]

  let unicode: Bool
  let ignoreCase: Bool

  /// With `iu`, the characters that fold into `\w` (ſ and the Kelvin sign) are word characters too.
  func isWordCharacter(_ value: UInt32) -> Bool {
    switch value {
    case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F: true
    case 0..<0x80: false
    default: unicode && ignoreCase && JSCaseFolding.unicodeExtraWordCharacters.contains(value)
    }
  }

  static func isWhitespace(_ value: UInt32) -> Bool {
    Unicode.Scalar(value).map(JSText.isWhitespace) ?? false
  }

  static func isLineTerminator(_ value: UInt32) -> Bool {
    value == 0x0A || value == 0x0D || value == 0x2028 || value == 0x2029
  }
}

struct JSRegexCompiledSet: Sendable {
  private let items: [JSRegexClassItem]
  private let negated: Bool
  private let mode: JSRegexMode
  private let asciiLow: UInt64
  private let asciiHigh: UInt64

  init(_ set: JSRegexCharacterSet, mode: JSRegexMode) {
    items = set.items
    negated = set.negated
    self.mode = mode
    var low: UInt64 = 0
    var high: UInt64 = 0
    for value in UInt32(0)..<0x80 where Self.matches(value, items: set.items, negated: set.negated, mode: mode) {
      if value < 64 { low |= 1 << UInt64(value) } else { high |= 1 << UInt64(value - 64) }
    }
    asciiLow = low
    asciiHigh = high
  }

  func contains(_ value: UInt32) -> Bool {
    if value < 64 { return asciiLow >> UInt64(value) & 1 == 1 }
    if value < 0x80 { return asciiHigh >> UInt64(value - 64) & 1 == 1 }
    return Self.matches(value, items: items, negated: negated, mode: mode)
  }

  /// Under `i` a class matches when any character canonically equal to the input is a member, and only then is the class negated.
  private static func matches(_ value: UInt32, items: [JSRegexClassItem], negated: Bool, mode: JSRegexMode) -> Bool {
    let found =
      mode.ignoreCase
      ? JSCaseFolding.equivalents(value, unicode: mode.unicode).contains { member(items, $0, mode: mode) }
      : member(items, value, mode: mode)
    return found != negated
  }

  private static func member(_ items: [JSRegexClassItem], _ value: UInt32, mode: JSRegexMode) -> Bool {
    items.contains { item in
      switch item {
      case .range(let lower, let upper): lower <= value && value <= upper
      case .digit(let negated): (0x30...0x39).contains(value) != negated
      case .space(let negated): JSRegexMode.isWhitespace(value) != negated
      case .word(let negated): mode.isWordCharacter(value) != negated
      case .property(let property, let negated): property.contains(value) != negated
      }
    }
  }
}
