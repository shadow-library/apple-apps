/// How `i` compares characters: without `u` by single-unit upper-casing that never maps a non-ASCII unit into ASCII, with `u` by simple case folding.
enum JSCaseFolding {
  static func canonical(_ value: UInt32, unicode: Bool) -> UInt32 {
    if unicode { return simpleFolds[value] ?? value }
    return value <= 0xFFFF ? UInt32(codeUnitCanonicals[Int(value)]) : value
  }

  static func equivalents(_ value: UInt32, unicode: Bool) -> [UInt32] {
    let orbits = unicode ? simpleFoldOrbits : codeUnitOrbits
    return orbits[canonical(value, unicode: unicode)] ?? [value]
  }

  static let unicodeExtraWordCharacters: Set<UInt32> = Set(
    JSRegexMode.asciiWordCharacters.flatMap { equivalents($0, unicode: true) }.filter { $0 >= 0x80 }
  )

  /// JavaScriptCore's table for `i` without `u` stops before Unicode 16 (`/[ƛ]/i` misses "Ꟛ" though `"ƛ".toUpperCase()` is "Ꟛ"); V8 follows Unicode 16.
  private static let codeUnitCanonicals: [UInt16] = (0...0xFFFF).map { unit in
    guard let scalar = Unicode.Scalar(UInt32(unit)) else { return UInt16(unit) }
    let upper = Array(scalar.properties.uppercaseMapping.utf16)
    guard upper.count == 1, unit < 0x80 || upper[0] >= 0x80, let target = Unicode.Scalar(UInt32(upper[0])) else { return UInt16(unit) }
    guard let age = target.properties.age, age.major < 16 else { return UInt16(unit) }
    return upper[0]
  }

  private static let codeUnitOrbits: [UInt32: [UInt32]] = {
    var orbits: [UInt32: [UInt32]] = [:]
    for unit in 0...0xFFFF { orbits[UInt32(codeUnitCanonicals[unit]), default: []].append(UInt32(unit)) }
    return orbits.filter { $0.value.count > 1 }
  }()

  private static let simpleFolds: [UInt32: UInt32] = {
    var folds: [UInt32: UInt32] = [:]
    for value in UInt32(0)...0x1_FFFF {
      guard let scalar = Unicode.Scalar(value), let folded = simpleFold(of: scalar), folded != value else { continue }
      folds[value] = folded
    }
    return folds
  }()

  private static let simpleFoldOrbits: [UInt32: [UInt32]] = {
    var orbits: [UInt32: [UInt32]] = [:]
    for (value, folded) in simpleFolds { orbits[folded, default: simpleFolds[folded] == nil ? [folded] : []].append(value) }
    return orbits.mapValues { $0.sorted() }
  }()

  private static let foldsUnlikeLowercase: [UInt32: UInt32] = [
    0x00B5: 0x03BC, 0x017F: 0x0073, 0x0345: 0x03B9, 0x03C2: 0x03C3, 0x03D0: 0x03B2, 0x03D1: 0x03B8, 0x03D5: 0x03C6, 0x03D6: 0x03C0, 0x03F0: 0x03BA,
    0x03F1: 0x03C1, 0x03F5: 0x03B5, 0x1E9B: 0x1E61, 0x1FBE: 0x03B9, 0x1FD3: 0x0390, 0x1FE3: 0x03B0, 0xFB05: 0xFB06, 0x1C80: 0x0432, 0x1C81: 0x0434,
    0x1C82: 0x043E, 0x1C83: 0x0441, 0x1C84: 0x0442, 0x1C85: 0x0442, 0x1C86: 0x044A, 0x1C87: 0x0463, 0x1C88: 0xA64B,
  ]

  /// Cherokee folds to its capitals, the reverse of lower-casing; every other fold is the single-scalar lower case or one of the listed exceptions.
  private static func simpleFold(of scalar: Unicode.Scalar) -> UInt32? {
    let value = scalar.value
    if let folded = foldsUnlikeLowercase[value] { return folded }
    if (0x13A0...0x13F5).contains(value) { return value }
    if (0x13F8...0x13FD).contains(value) { return value - 8 }
    if (0xAB70...0xABBF).contains(value) { return value - 0xAB70 + 0x13A0 }
    let lower = scalar.properties.lowercaseMapping.unicodeScalars
    guard lower.count == 1, let only = lower.first else { return nil }
    return only.value
  }
}
