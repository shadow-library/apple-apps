import Foundation
import ShadowAI
import ShadowText

// apps/novel-forge-server/src/modules/ai/prompts/chapter-canon-refresh.prompt.ts:38
func canonRefreshIssues(_ output: OrderedJSON) -> [String] {
  let updates = output.objectValue?["updates"]?.arrayValue ?? []
  return updates.enumerated().flatMap { index, update in
    let changeSet = update.objectValue?["changeSet"] ?? .null
    return validateChangeSet(changeSet, allowedOps: canonRefreshOps, options: ChangeSetValidationOptions(entityMaterialization: false)).errors.map { "updates[\(index)].\($0)" }
  }
}

func canonRefreshReview() -> StructuredReview {
  StructuredReview(postValidate: { data in
    guard let json = try? OrderedJSON(parsing: String(decoding: data, as: UTF8.self)) else { return ["the update is not readable JSON"] }
    return canonRefreshIssues(json)
  })
}
