enum JSONCodeUnit {
  static let quote = UInt16(ascii: "\"")
  static let backslash = UInt16(ascii: "\\")
  static let openBrace = UInt16(ascii: "{")
  static let closeBrace = UInt16(ascii: "}")
  static let openBracket = UInt16(ascii: "[")
  static let closeBracket = UInt16(ascii: "]")
  static let comma = UInt16(ascii: ",")
  static let colon = UInt16(ascii: ":")
  static let minus = UInt16(ascii: "-")
  static let plus = UInt16(ascii: "+")
  static let dot = UInt16(ascii: ".")
  static let zero = UInt16(ascii: "0")
  static let lowerE = UInt16(ascii: "e")
  static let upperE = UInt16(ascii: "E")
  static let lowerU = UInt16(ascii: "u")
  static let lowerT = UInt16(ascii: "t")
  static let lowerF = UInt16(ascii: "f")
  static let lowerN = UInt16(ascii: "n")

  static let trueWord = Array("true".utf16)
  static let falseWord = Array("false".utf16)
  static let nullWord = Array("null".utf16)
  static let opKey = Array("op".utf16)
  static let replyKey = Array("reply".utf16)
  static let changeSetKey = Array("changeSet".utf16)

  static let replacement: UInt16 = 0xFFFD

  static let simpleEscapes: [UInt16: UInt16] = [
    UInt16(ascii: "\""): UInt16(ascii: "\""),
    UInt16(ascii: "\\"): UInt16(ascii: "\\"),
    UInt16(ascii: "/"): UInt16(ascii: "/"),
    UInt16(ascii: "b"): 0x08,
    UInt16(ascii: "f"): 0x0C,
    UInt16(ascii: "n"): 0x0A,
    UInt16(ascii: "r"): 0x0D,
    UInt16(ascii: "t"): 0x09,
  ]

  static func isDigit(_ unit: UInt16) -> Bool {
    unit >= zero && unit <= UInt16(ascii: "9")
  }

  static func hexValue(_ unit: UInt16) -> UInt16? {
    switch unit {
    case zero...UInt16(ascii: "9"): unit - zero
    case UInt16(ascii: "a")...UInt16(ascii: "f"): unit - UInt16(ascii: "a") + 10
    case UInt16(ascii: "A")...UInt16(ascii: "F"): unit - UInt16(ascii: "A") + 10
    default: nil
    }
  }

  static func isHighSurrogate(_ unit: UInt16) -> Bool {
    unit >= 0xD800 && unit <= 0xDBFF
  }

  static func isLowSurrogate(_ unit: UInt16) -> Bool {
    unit >= 0xDC00 && unit <= 0xDFFF
  }

  static func isScriptWhitespace(_ unit: UInt16) -> Bool {
    switch unit {
    case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
    default: false
    }
  }

  static func isScalarDelimiter(_ unit: UInt16) -> Bool {
    switch unit {
    case comma, closeBrace, closeBracket, 0x20, 0x09, 0x0A, 0x0D: true
    default: false
    }
  }
}

extension UInt16 {
  fileprivate init(ascii scalar: Unicode.Scalar) {
    self.init(scalar.value)
  }
}
