import Foundation
import ShadowAI
import ShadowText

extension PlannedChapter {
  init?(json: OrderedJSON) {
    guard let record = json.objectValue else { return nil }
    let fields = OpFields(record: record)
    guard let title = fields.string("title"), let objective = fields.string("objective"), let scenes = record["scenes"]?.arrayValue,
      let endingRecord = fields.object("endingContract"), let ending = EndingContract(endingRecord), let purpose = fields.string("chapterPurpose"),
      let readerValue = fields.strings("readerValue")
    else { return nil }
    let sceneRecords = scenes.compactMap { $0.objectValue.map(OpFields.init(record:)) }
    guard sceneRecords.count == scenes.count else { return nil }
    self.init(
      title: title, objective: objective, scenes: sceneRecords.compactMap(BriefScene.init(fields:)), continuesIntoNextChapter: fields.bool("continuesIntoNextChapter") ?? false,
      startsFromPreviousChapter: fields.bool("startsFromPreviousChapter") ?? false, handoffBeat: fields.string("handoffBeat"), endingContract: ending,
      knowledgeContract: fields.object("knowledgeContract").flatMap(ChangeKnowledgeContract.init), claimedMilestones: fields.strings("claimedMilestones"),
      chapterPurpose: purpose, readerValue: readerValue, repetitionRisks: fields.strings("repetitionRisks"), densityRisk: fields.string("densityRisk"),
      moves: fields.string("moves"))
  }
}

extension BriefScene {
  fileprivate init?(fields: OpFields) {
    guard let summary = fields.string("summary") else { return nil }
    self.init(
      summary: summary, pov: fields.string("pov"), goal: fields.string("goal"), obstacle: fields.string("obstacle"), turn: fields.string("turn"), beats: fields.strings("beats"),
      estimatedWords: fields.int("estimatedWords"))
  }
}

// apps/novel-forge-server/src/modules/ai/schemas/chapter-plan.schema.ts:81
func chapterPlanIssues(_ plan: PlannedChapter) -> [String] {
  var issues = plan.readerValue.filter { value in !chapterPlanReaderValueChanges.contains { $0.jsEquals(value) } }.map {
    "readerValue '\($0)' is not one of: \(chapterPlanReaderValueChanges.joined(separator: ", "))"
  }
  if plan.continuesIntoNextChapter || plan.startsFromPreviousChapter, (plan.handoffBeat?.jsTrim() ?? "").isEmpty {
    issues.append("handoffBeat is required when the chapter continues into the next one or starts from the previous one")
  }
  return issues
}

// apps/novel-forge-server/src/modules/ai/schemas/knowledge-contract.schema.ts:3; JSON Schema reports it as the path and the pattern.
func chapterPlanKeyIssues(_ plan: PlannedChapter) -> [String] {
  let learns = plan.knowledgeContract?.learns ?? []
  return learns.enumerated().flatMap { index, reveal in
    [("entityKey", reveal.entityKey), ("factKey", reveal.factKey)].filter { !isPlanKey($0.1) }.map {
      "/knowledgeContract/learns/\(index)/\($0.0) must match pattern \"\(chapterPlanKeyPattern)\""
    }
  }
}

private func isPlanKey(_ key: String) -> Bool {
  !key.isEmpty && key.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
}

// apps/novel-forge-server/src/modules/ai/prompts/chapter-plan.prompt.ts:57; `advise` is where the plan's reveal rules run (planAdvice).
func chapterPlanReview(advise: @escaping @Sendable (PlannedChapter) -> [String] = { _ in [] }) -> StructuredReview {
  StructuredReview(
    postValidate: { data in
      guard let json = try? OrderedJSON(parsing: String(decoding: data, as: UTF8.self)), let plan = PlannedChapter(json: json) else { return ["the plan is not readable"] }
      return chapterPlanIssues(plan) + chapterPlanKeyIssues(plan)
    },
    advise: { data in
      guard let json = try? OrderedJSON(parsing: String(decoding: data, as: UTF8.self)), let plan = PlannedChapter(json: json) else { return [] }
      return advise(plan)
    })
}
