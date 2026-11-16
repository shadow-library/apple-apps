let maxPassageChars = 6000
let anchorContextChars = 32

/// Offsets are UTF-16 code units into the draft body.
struct PassageAnchor: Equatable, Sendable {
  let start: Int
  let end: Int
  let passageHash: String
  let passage: String
  let contextBefore: String
  let contextAfter: String
}

enum PassageLocation: Equatable, Sendable {
  case fresh(start: Int, end: Int)
  case relocated(start: Int, end: Int)
  case stale
}

private func sum(_ left: Int, _ right: Int) -> Int {
  let (result, overflow) = left.addingReportingOverflow(right)
  return overflow ? (right < 0 ? Int.min : Int.max) : result
}

private func hash(ofCodeUnits units: [UInt16]) -> String {
  sha256Hex(String(decoding: units, as: UTF16.self))
}

// apps/novel-forge-server/src/modules/generation/passage-anchor.ts:21
func passageHash(_ passage: String) -> String {
  hash(ofCodeUnits: passage.jsCodeUnits)
}

// apps/novel-forge-server/src/modules/generation/passage-anchor.ts:25
func anchorContext(_ body: String, start: Int, end: Int) -> (contextBefore: String, contextAfter: String) {
  (
    contextBefore: JSText.string(fromCodeUnits: body.jsSliceCodeUnits(max(0, sum(start, -anchorContextChars)), start)),
    contextAfter: JSText.string(fromCodeUnits: body.jsSliceCodeUnits(end, sum(end, anchorContextChars)))
  )
}

private func surroundedAt(_ body: String, _ anchor: PassageAnchor, start: Int, end: Int) -> Bool {
  let before = anchor.contextBefore.jsCodeUnits
  let after = anchor.contextAfter.jsCodeUnits
  return body.jsSliceCodeUnits(max(0, sum(start, -before.count)), start) == before && body.jsSliceCodeUnits(end, sum(end, after.count)) == after
}

// apps/novel-forge-server/src/modules/generation/passage-anchor.ts:41
func locatePassage(_ body: String, anchor: PassageAnchor) -> PassageLocation {
  let units = body.jsCodeUnits
  let inPlace = hash(ofCodeUnits: body.jsSliceCodeUnits(anchor.start, anchor.end)) == anchor.passageHash
  if inPlace, surroundedAt(body, anchor, start: anchor.start, end: anchor.end) { return .fresh(start: anchor.start, end: anchor.end) }
  if passageHash(anchor.passage) != anchor.passageHash { return .stale }

  let before = anchor.contextBefore.jsCodeUnits
  let needle = before + anchor.passage.jsCodeUnits + anchor.contextAfter.jsCodeUnits
  let found = JSText.indexOf(needle, in: units, from: 0)
  guard found != -1, JSText.indexOf(needle, in: units, from: JSText.clamped(found + 1, length: units.count)) == -1 else { return .stale }
  let start = found + before.count
  return .relocated(start: start, end: start + anchor.passage.jsLength)
}

private let leadingWhitespace = try? JSRegex(#"^\s*"#)
private let trailingWhitespace = try? JSRegex(#"\s*$"#)

// apps/novel-forge-server/src/modules/generation/passage-anchor.ts:50
func fitReplacement(_ passage: String, _ replacement: String) -> String {
  let leading = leadingWhitespace?.exec(passage)?.text ?? ""
  let trailing = trailingWhitespace?.exec(passage)?.text ?? ""
  return "\(leading)\(replacement.jsTrim())\(trailing)"
}

// apps/novel-forge-server/src/modules/generation/passage-anchor.ts:56
func replacePassage(_ body: String, start: Int, end: Int, replacement: String) -> String {
  JSText.string(fromCodeUnits: body.jsSliceCodeUnits(0, start) + replacement.jsCodeUnits + body.jsSliceCodeUnits(end))
}
