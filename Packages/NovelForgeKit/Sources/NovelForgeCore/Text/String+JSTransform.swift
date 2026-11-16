import Foundation

enum JSNormalizationForm {
  case nfc
  case nfd
  case nfkc
  case nfkd
}

extension String {
  func jsTrim() -> String {
    trimming(start: true, end: true)
  }

  func jsTrimStart() -> String {
    trimming(start: true, end: false)
  }

  func jsTrimEnd() -> String {
    trimming(start: false, end: true)
  }

  /// JavaScript applies the Final_Sigma context; Swift's `lowercased()` turns every capital sigma into σ.
  func jsToLowerCase() -> String {
    let scalars = Array(unicodeScalars)
    var lowered = String.UnicodeScalarView()
    for (index, scalar) in scalars.enumerated() {
      if scalar.value == 0x03A3 {
        lowered.append(Self.isFinalSigma(at: index, in: scalars) ? "\u{03C2}" : "\u{03C3}")
      } else {
        lowered.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars)
      }
    }
    return String(lowered)
  }

  func jsNormalize(_ form: JSNormalizationForm = .nfc) -> String {
    switch form {
    case .nfc: precomposedStringWithCanonicalMapping
    case .nfd: decomposedStringWithCanonicalMapping
    case .nfkc: precomposedStringWithCompatibilityMapping
    case .nfkd: decomposedStringWithCompatibilityMapping
    }
  }

  /// A nil `limit` is JavaScript's `undefined`; any other goes through ToUint32, so a negative limit splits without bound.
  func jsSplit(_ separator: String, limit: Int? = nil) -> [String] {
    let bound = Int(limit.map { UInt32(truncatingIfNeeded: $0) } ?? UInt32.max)
    guard bound > 0 else { return [] }
    let units = jsCodeUnits
    let needle = separator.jsCodeUnits
    if needle.isEmpty { return units.prefix(bound).map { JSText.string(fromCodeUnits: [$0]) } }
    if units.isEmpty { return [""] }
    var pieces: [String] = []
    var start = 0
    var found = JSText.indexOf(needle, in: units, from: 0)
    while found != -1 {
      pieces.append(JSText.string(fromCodeUnits: units[start..<found]))
      if pieces.count == bound { return pieces }
      start = found + needle.count
      found = JSText.indexOf(needle, in: units, from: start)
    }
    pieces.append(JSText.string(fromCodeUnits: units[start...]))
    return pieces
  }

  private func trimming(start: Bool, end: Bool) -> String {
    var lower = unicodeScalars.startIndex
    var upper = unicodeScalars.endIndex
    if start { while lower < upper, JSText.isWhitespace(unicodeScalars[lower]) { lower = unicodeScalars.index(after: lower) } }
    if end {
      while lower < upper, JSText.isWhitespace(unicodeScalars[unicodeScalars.index(before: upper)]) { upper = unicodeScalars.index(before: upper) }
    }
    return String(unicodeScalars[lower..<upper])
  }

  private static func isFinalSigma(at index: Int, in scalars: [Unicode.Scalar]) -> Bool {
    var before = index - 1
    while before >= 0, scalars[before].properties.isCaseIgnorable { before -= 1 }
    guard before >= 0, scalars[before].properties.isCased else { return false }
    var after = index + 1
    while after < scalars.count, scalars[after].properties.isCaseIgnorable { after += 1 }
    return after == scalars.count || !scalars[after].properties.isCased
  }
}
