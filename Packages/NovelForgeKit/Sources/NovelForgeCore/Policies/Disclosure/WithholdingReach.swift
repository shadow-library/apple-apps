/// One step of a withholding's body, its pattern without the lookarounds.
enum BodyAtom: Sendable {
  case character(Unicode.Scalar, source: String)
  /// Emphasis or the whitespace between words: never a letter, digit or bracket.
  case filler(source: String, optional: Bool)

  var source: String {
    switch self {
    case .character(_, let source), .filler(let source, _): source
    }
  }
}

/// Where a withholding can match in any text scrubbing leaves.
enum WithholdingReach: Sendable {
  /// Only where `body` matches the text before scrubbing. `rewritesMarkers`: the body can also match the letters between a marker's brackets, which hides nothing
  /// but changes the marker text a withholding that takes it sees.
  case body(JSRegex, rewritesMarkers: Bool)
  /// The body can take marker text, but only through a stretch of bracketed marker spelling; its other characters match text before scrubbing, so a match holds a
  /// match of each of these marker-free pieces.
  case markers(pieces: [JSRegex])
}

private let lookarounds = [(#"(?<![\p{L}\p{N}_])"#, #"(?![\p{L}\p{N}_])"#), (#"(?<![\p{L}\p{N}])"#, #"(?![\p{L}\p{N}])"#)]
private let markerSpelling = Set(withheldMarker.utf16)
private let markerLetters = Array("withheld".utf16)
private let markerHead = Array("[withheld".utf16)
private let markerTail = Array("withheld]".utf16)

/// Whether `unit` is spelt into a marker, in either case: case-insensitive matching folds no other character onto these.
private func spellsMarker(_ unit: UInt16) -> Bool {
  markerSpelling.contains(asciiLowercased(unit))
}

private func asciiLowercased(_ unit: UInt16) -> UInt16 {
  (65...90).contains(unit) ? unit + 32 : unit
}

/// Whether a run of marker spelling in a body can match marker text: a whole marker inside it, or a bracket at the body's edge that lines up with a marker's.
private func takesMarkerText(_ run: [UInt16], opensBody: Bool, closesBody: Bool) -> Bool {
  if JSText.indexOf(Array(withheldMarker.utf16), in: run, from: 0) != -1 { return true }
  for (index, unit) in run.enumerated() {
    if closesBody, unit == UInt16(UInt8(ascii: "[")), markerTail.starts(with: run[(index + 1)...]) { return true }
    if opensBody, unit == UInt16(UInt8(ascii: "]")), markerHead.reversed().starts(with: run[..<index].reversed()) { return true }
  }
  return false
}

extension WithholdingReach {
  /// Nil when `pattern` is not `body` between one of the reference's lookaround pairs.
  init?(pattern: JSRegex, body: [BodyAtom]) {
    let source = body.map(\.source).joined()
    guard lookarounds.contains(where: { pattern.source.jsEquals($0.0 + source + $0.1) }) else { return nil }
    let fixed = body.indices.filter { atom in
      if case .filler(_, optional: true) = body[atom] { return false }
      return true
    }
    var crossing: [Range<Int>] = []
    var start = 0
    while start < body.count {
      guard case .character(let scalar, _) = body[start], scalar.isASCII, spellsMarker(UInt16(scalar.value)) else {
        start += 1
        continue
      }
      var end = start + 1
      while end < body.count, case .character(let next, _) = body[end], next.isASCII, spellsMarker(UInt16(next.value)) { end += 1 }
      let run = body[start..<end].compactMap { atom -> UInt16? in
        guard case .character(let scalar, _) = atom else { return nil }
        return asciiLowercased(UInt16(scalar.value))
      }
      if takesMarkerText(run, opensBody: fixed.first == start, closesBody: fixed.last == end - 1) { crossing.append(start..<end) }
      start = end
    }
    guard !crossing.isEmpty else {
      guard let regex = try? JSRegex(source, flags: pattern.flags) else { return nil }
      let letters = fixed.compactMap { atom -> UInt16? in
        guard case .character(let scalar, _) = body[atom], scalar.isASCII else { return nil }
        return asciiLowercased(UInt16(scalar.value))
      }
      let rewritesMarkers = letters.count == fixed.count && !letters.isEmpty && JSText.indexOf(letters, in: markerLetters, from: 0) != -1
      self = .body(regex, rewritesMarkers: rewritesMarkers)
      return
    }
    var pieces: [JSRegex] = []
    var pieceStart = 0
    for range in crossing + [body.count..<body.count] {
      let piece = body[pieceStart..<range.lowerBound]
      pieceStart = range.upperBound
      guard piece.contains(where: { if case .filler(_, optional: true) = $0 { false } else { true } }) else { continue }
      guard let regex = try? JSRegex(piece.map(\.source).joined(), flags: pattern.flags) else { return nil }
      pieces.append(regex)
    }
    self = .markers(pieces: pieces)
  }
}

/// Where a body that takes marker text can match: in a stretch of units each hideable by some withholding, spelt like a marker, emphasis, or inside a match of one of
/// its pieces; and only in a stretch that holds the start of a match of every piece.
func markerSites(_ pieceMatches: [[Range<Int>]], in units: [UInt16], hideable: [Bool]) -> [Range<Int>] {
  var reachable = hideable
  for (offset, unit) in units.enumerated() where spellsMarker(unit) || unit == UInt16(UInt8(ascii: "*")) || unit == UInt16(UInt8(ascii: "_")) { reachable[offset] = true }
  for match in pieceMatches.joined() {
    for offset in match where offset < units.count { reachable[offset] = true }
  }
  var sites: [Range<Int>] = []
  var start = 0
  while start < units.count {
    guard reachable[start] else {
      start += 1
      continue
    }
    var end = start + 1
    while end < units.count, reachable[end] { end += 1 }
    let stretch = start..<end
    if pieceMatches.allSatisfy({ $0.contains { stretch.contains($0.lowerBound) } }) { sites.append(stretch) }
    start = end
  }
  return sites
}
