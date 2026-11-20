import Foundation
import ShadowText

// apps/novel-forge-server/src/common/brief-body.ts:9-12
let continuesLine = "[CONTINUES INTO NEXT CHAPTER] Do not resolve this chapter's central action/tension."
let startsLine =
  "[STARTS FROM PREVIOUS CHAPTER] Continue forward in new sentences from the exact beat the previous chapter handed off — no time skip, no recap, and never repeat the previous chapter's closing line(s) verbatim; the reader already read them."
let handoffPrefix = "Handoff beat: "

enum ChapterRegex {
  static let returnNewline = ProseRegex.literal(#"\r\n"#, "g")
  static let carriageReturn = ProseRegex.literal(#"\r"#, "g")
  static let sentenceEnd = ProseRegex.literal(#"[.!?…"'”’)]$"#, "u")
  static let sceneLine = ProseRegex.literal(#"^Scene \d+\b"#)
}

// apps/novel-forge-server/src/common/sanitize-content.ts:66
func normalizeLineEndings(_ text: String) -> String {
  text.jsReplace(ChapterRegex.returnNewline, "\n").jsReplace(ChapterRegex.carriageReturn, "\n")
}

// apps/novel-forge-server/src/common/brief-body.ts:21
func asSentence(_ text: String) -> String {
  let flat = text.jsReplace(ProseRegex.whitespaceRunGlobal, " ").jsTrim()
  return ChapterRegex.sentenceEnd.test(flat) ? flat : flat + "."
}

// apps/novel-forge-server/src/common/brief-body.ts:55
func renderPlanScene(_ scene: BriefScene, index: Int) -> String {
  let words = scene.estimatedWords.flatMap { $0 == 0 ? nil : " (~\(Double($0).jsString) words)" } ?? ""
  var parts = [asSentence(scene.summary)]
  for (label, text) in [("Goal", scene.goal), ("Obstacle", scene.obstacle), ("Turn", scene.turn)] {
    guard let text, !text.isEmpty else { continue }
    parts.append("\(label): \(asSentence(text))")
  }
  let beats = (scene.beats ?? []).map { $0.jsReplace(ProseRegex.whitespaceRunGlobal, " ").jsTrim() }.filter { !$0.isEmpty }
  if !beats.isEmpty { parts.append("Beats: \(asSentence(beats.joined(separator: "; ")))") }
  if let pov = scene.pov, !pov.isEmpty { parts.append("POV: \(pov).") }
  return "Scene \(Double(index + 1).jsString)\(words). \(parts.joined(separator: " "))"
}

// apps/novel-forge-server/src/common/brief-body.ts:70
func composePlanBody(_ body: String, scenes: [BriefScene]) -> String {
  let lines = body.isEmpty ? [] : body.jsSplit("\n")
  let sceneIndexes = lines.indices.filter { ChapterRegex.sceneLine.test(lines[$0]) }
  let rendered = scenes.enumerated().map { renderPlanScene($0.element, index: $0.offset) }
  guard let first = sceneIndexes.first, let last = sceneIndexes.last else {
    guard !rendered.isEmpty else { return body }
    let at = lines.firstIndex(where: isContinuationLine) ?? lines.count
    return (lines[..<at] + rendered + lines[at...]).joined(separator: "\n")
  }
  let kept = lines[first...last].filter { !ChapterRegex.sceneLine.test($0) && !$0.jsTrim().isEmpty }
  return (Array(lines[..<first]) + rendered + kept + lines[(last + 1)...]).joined(separator: "\n")
}

// apps/novel-forge-server/src/common/brief-body.ts:37
private func isContinuationLine(_ line: String) -> Bool {
  line.jsEquals(continuesLine) || line.jsEquals(startsLine) || line.utf16.starts(with: handoffPrefix.utf16)
}
