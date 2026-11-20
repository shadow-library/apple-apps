import ShadowText

struct WriterBriefInput: Equatable, Sendable {
  var body: String?
  var pov: String?
  var chapterPurpose: String?
  var readerValue: [String] = []
  var repetitionRisks: [String] = []
  var guidance: String?
  var endingContract: ChapterEndingContract?
}

// apps/novel-forge-server/src/modules/ai/context/writer-brief.ts:9
struct WriterBrief: Equatable, Sendable {
  var chapterBrief: String
  var endingContract: String
}

private let guidanceHeading = "Author guidance:"

extension WriterRender {
  // apps/novel-forge-server/src/common/brief-body.ts:107
  private static func stringList(_ values: [String]) -> [String] {
    values.filter { !$0.jsTrim().isEmpty }.map { $0.jsTrim() }
  }

  // brief-body.ts:115
  static func renderChapterBrief(_ brief: WriterBriefInput?) -> String {
    var directives: [String] = []
    if let pov = brief?.pov?.jsTrim(), !pov.isEmpty { directives.append("POV: \(pov)") }
    if let purpose = brief?.chapterPurpose?.jsTrim(), !purpose.isEmpty { directives.append("Chapter purpose: \(purpose)") }
    let readerValue = stringList(brief?.readerValue ?? [])
    if !readerValue.isEmpty { directives.append("This chapter must deliver: \(readerValue.joined(separator: ", "))") }
    let risks = stringList(brief?.repetitionRisks ?? [])
    if !risks.isEmpty { directives.append("Avoid repeating recent patterns: \(risks.joined(separator: "; "))") }
    let guidance = brief?.guidance?.jsTrim() ?? ""
    return [brief?.body ?? "", directives.joined(separator: "\n"), guidance.isEmpty ? "" : "\(guidanceHeading)\n\(guidance)"].filter { !$0.isEmpty }.joined(separator: "\n\n")
  }

  /// `canonFacts` are every fact of the novel; only a `mustNotResolve` entry that could name one makes the writer notes matter.
  // apps/novel-forge-server/src/modules/ai/context/writer-brief.ts:21
  static func writerBrief(_ brief: WriterBriefInput?, canonFacts: [DisclosureFact], disclosure: inout WriterDisclosurePolicy) throws(DisclosureError) -> WriterBrief {
    var notes: [JSString: String?] = [:]
    if brief?.endingContract?.mustNotResolve?.isEmpty == false {
      for fact in canonFacts { notes[JSString(fact.factKey)] = fact.writerNote }
    }
    return WriterBrief(
      chapterBrief: try disclosure.scrub(renderChapterBrief(brief), .plan),
      endingContract: try disclosure.scrub(renderEndingContract(brief?.endingContract, factWriterNotes: notes), .plan))
  }

  // apps/novel-forge-server/src/modules/ai/context/pack-render.ts:122
  static func writingStyleSection(_ stored: String?, disclosure: inout WriterDisclosurePolicy) throws(DisclosureError) -> ChatPackSection {
    var additions = writingInstructionAdditions(stored)
    if let text = additions { additions = try disclosure.scrub(text, .style) }
    let style = effectiveWritingInstructions(additions: additions, maxTokens: writingStyleBudget)
    var section = ChatPack.makeSection("writing_style", style.text, tier: .canonical)
    section.truncated = style.truncated
    return section
  }

  // pack-render.ts:120
  static let writingStyleBudget = 4_000
}
