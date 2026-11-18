struct ChapterJudgeEvaluationInput: Equatable, Sendable {
  var prose: String
  var pov: String?
  var briefBody: String?
  var endingContract: ChapterEndingContract?
  var hiddenFacts: [DisclosureFact]
  var readerKnows: [DisclosureFact]
  var readabilityEvidence: String
}

// apps/novel-forge-server/src/modules/ai/graphs/chapter-generation.graph.ts:628
func chapterJudgeEvaluation(_ input: ChapterJudgeEvaluationInput) -> String {
  let renderedContract = renderEndingContract(input.endingContract)
  let contractBlock =
    renderedContract.isEmpty
    ? ""
    : "\n\n## ENDING CONTRACT\n\(renderedContract)\n\nAlso assess the draft ending against this contract and include endingCompliance in your JSON."
  let forbidden = input.hiddenFacts.filter { $0.source != .seed }
  let knowledgeBlock =
    forbidden.isEmpty
    ? ""
    : "\n\n## FORBIDDEN KNOWLEDGE\n\(renderForbiddenFacts(forbidden))\n\nThe POV cast does not know these facts — assess the draft for leaks and include knowledgeCompliance in your JSON."
  let povLine = input.pov.flatMap { $0.isEmpty ? nil : "POV: \($0)\n" } ?? ""
  let readabilityBlock =
    input.readabilityEvidence.isEmpty
    ? ""
    : "\n\n\(input.readabilityEvidence)\n\nWeigh this evidence in readabilityCompliance; the project's writing-style additions win where they allow this prose."
  let briefBlock =
    "\n\n## BRIEF\n\(povLine)\(input.briefBody ?? "")\n\nThis is the plan the chapter was written from — assess whether the draft delivers it and include briefCompliance in your JSON."
  return
    "Draft prose to evaluate:\n\(input.prose)\(briefBlock)\(contractBlock)\(knowledgeBlock)\(renderJudgeReaderKnows(input.readerKnows))\(readabilityBlock)\n\nEvaluate this chapter draft for continuity and consistency with the established canon. Return a JSON object with verdict (\"consistent\" or \"contradiction\") and findings array."
}
