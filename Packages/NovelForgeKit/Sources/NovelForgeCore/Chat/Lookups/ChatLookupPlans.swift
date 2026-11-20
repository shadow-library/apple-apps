import Foundation
import ShadowStore
import ShadowText

private let walledOffProse = "Prose: walled off. This is an unrestricted chapter, so its text is not available here; only its approved bridge is."
private let walledOffEditHint = "To change the text, propose action.revise_draft rather than draft.update."

extension ChatLookupReader {
  // tools/get-brief.tool.ts:14
  func brief(chapter: Double) throws(ChatLookupFailure) -> String {
    let notFound = "Brief not found for chapter \(chapter.jsString)"
    guard let number = Self.chapterNumber(chapter), let ref = try? ChapterPlanRecord.ref(novel: novel, chapter: number) else { return notFound }
    guard let (plan, revision) = try head(ChapterPlanRecord.self, ref) else { return notFound }
    let content = plan.content
    var lines = ["**Chapter \(plan.chapter)**: \(content.title ?? "(untitled)") (rev \(revision), \(content.writeMode.rawValue))"]
    lines.append("Volume: \(content.volume ?? "?") / POV: \(content.pov ?? "?")")
    if let purpose = ChatPack.present(content.chapterPurpose) { lines.append("Purpose: \(purpose)") }
    lines.append(content.body)
    if let refs = content.contextRefs, !refs.isEmpty { lines.append("Context refs: \(refs.joined(separator: ", "))") }
    if let ending = content.endingContract { lines.append("Ending contract: \(Self.endingJSON(ending).jsonText)") }
    if let knowledge = content.contract.knowledge { lines.append("Knowledge contract: \(Self.knowledgeJSON(knowledge).jsonText)") }
    if let value = content.readerValue { lines.append("Reader value: \(JSONBText.strings(value).jsonText)") }
    if let risks = content.repetitionRisks { lines.append("Repetition risks: \(JSONBText.strings(risks).jsonText)") }
    if let guidance = ChatPack.present(content.guidance) { lines.append("Author guidance: \(guidance)") }
    return lines.joined(separator: "\n")
  }

  // tools/get-draft.tool.ts:19
  func draft(chapter: Double) throws(ChatLookupFailure) -> String {
    let notFound = "Draft not found for chapter \(chapter.jsString)"
    guard let number = Self.chapterNumber(chapter), let ref = try? DraftRecord.ref(novel: novel, chapter: number) else { return notFound }
    guard let (draft, revision) = try head(DraftRecord.self, ref) else { return notFound }
    let content = try query { () throws(StoreError) in try ChatTurnDrafts.readThrough(draft.content, novel: novel, chapter: draft.chapter, in: transaction) }
    let row = try query { () throws(StoreError) in try ChapterList.load(novel, in: transaction) }.rows.value?.first { $0.chapter == draft.chapter }
    let status = row.map { $0.stage == .final ? "final" : "draft" } ?? Self.notAvailable
    let review = row?.review?.rawValue ?? Self.notAvailable
    let title = content.isolated ? "(title withheld)" : (content.title ?? "(untitled)")
    var lines = ["**Chapter \(draft.chapter)**: \(title) (\(status), rev \(revision), review: \(review))"]
    let words = ProseMetrics.countWords(content.body)
    if words > 0 { lines.append("Words: \(words)") }
    if content.isolated {
      lines.append("\(walledOffProse)\n\(ChatPack.noApprovedBridge)")
      lines.append(walledOffEditHint)
    } else {
      if let summary = ChatPack.present(content.summary) { lines.append("Summary: \(summary)") }
      lines.append(content.body)
    }
    return lines.joined(separator: "\n")
  }

  // tools/get-chapter-summaries.tool.ts:21; an isolated chapter reads through no approved bridge, as the vault records none
  func chapterSummaries(from: Double, to: Double) throws(ChatLookupFailure) -> String {
    guard let first = Self.chapterNumber(from), let last = Self.chapterNumber(to), first <= last else { return "No chapters in range." }
    var lines: [String] = []
    for number in first...last {
      guard let ref = try? FinalChapterRecord.ref(novel: novel, chapter: number) else { continue }
      let reading = try query { () throws(StoreError) in try FinalChapterRecord.read(ref, in: transaction) }
      switch reading {
      case .absent: continue
      case .unreadable: lines.append("Ch \(number): \(Self.notAvailable)")
      case .readable(let entry):
        if entry.isRemoved { continue }
        let summary = entry.record.text.summary
        if entry.record.canon.isolated {
          lines.append("Ch \(number) [unrestricted]: (walled off — no approved bridge)")
        } else {
          lines.append("Ch \(number): \(summary ?? "(no summary)")")
        }
      }
    }
    return lines.isEmpty ? "No chapters in range." : lines.joined(separator: "\n")
  }

  // The reference's jsonb keeps these in length order
  private static func endingJSON(_ ending: ChapterEndingContract) -> OrderedJSON {
    var pairs: [(key: String, value: OrderedJSON)] = [
      (key: "hookType", value: .string(ending.hookType.rawValue)), (key: "emotionalBeat", value: .string(ending.emotionalBeat)),
      (key: "openQuestion", value: .string(ending.openQuestion)), (key: "handoffState", value: .string(ending.handoffState)),
    ]
    if let mustNotResolve = ending.mustNotResolve { pairs.append((key: "mustNotResolve", value: JSONBText.strings(mustNotResolve))) }
    pairs += ending.unrecognised.map { (key: $0.key, value: JSONBText.value($0.value)) }
    return JSONBText.object(pairs)
  }

  private static func knowledgeJSON(_ knowledge: KnowledgeContract) -> OrderedJSON {
    let learns = knowledge.learns.map { reveal in
      JSONBText.object([(key: "entityKey", value: .string(reveal.entityKey)), (key: "factKey", value: .string(reveal.factKey))])
    }
    return JSONBText.object([(key: "pov", value: JSONBText.strings(knowledge.pov)), (key: "learns", value: .array(learns))])
  }
}
