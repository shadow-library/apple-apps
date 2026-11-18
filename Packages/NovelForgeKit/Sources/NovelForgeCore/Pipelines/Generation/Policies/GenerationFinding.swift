typealias GenerationFinding = CheckFinding

// apps/novel-forge-server/src/database/schemas/generation.ts:34
enum GenerationVerdict: String, CaseIterable, Sendable {
  case consistent
  case contradiction
  case evaluationFailed = "evaluation_failed"
}

// apps/novel-forge-server/src/modules/ai/schemas/judge.schema.ts:17
struct JudgeCompliance: Equatable, Sendable {
  let compliant: Bool
  let issues: [String]
}
