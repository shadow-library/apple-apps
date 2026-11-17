// apps/novel-forge-server/src/modules/refinement/prose-intent.ts:4
let proseEditOps: [OpType] = [.draftUpdate, .draftRemove, .draftRewritePassage, .actionReviseDraft]

// apps/novel-forge-server/src/modules/refinement/prose-intent.ts:6
let proseEditWithheldNote =
  "Forge left the chapter's prose untouched because Edit prose was off for this request: apply the plan change, then regenerate the chapter from the updated brief. To have Forge rewrite the text itself, turn on Edit prose and ask again."

// apps/novel-forge-server/src/modules/refinement/prose-intent.ts:9
let passageEditWithheldNote = "Forge left the passage as it is because Edit prose was off for this request. To have Forge rewrite it, turn on Edit prose and ask again."

private let dependentChapterActions: [OpType] = [.actionApproveDraft, .actionJudgeDraft]

private func op(_ fields: OrderedJSONObject) -> String? { fields["op"]?.stringValue }

private func isOp(_ fields: OrderedJSONObject, in types: [OpType]) -> Bool {
  guard let name = op(fields) else { return false }
  return types.contains { $0.rawValue.jsEquals(name) }
}

// apps/novel-forge-server/src/modules/refinement/prose-intent.ts:20
func isProseEditOp(_ fields: OrderedJSONObject) -> Bool {
  isOp(fields, in: proseEditOps)
}

// apps/novel-forge-server/src/modules/refinement/prose-intent.ts:25
private func dependsOnWithheld(_ fields: OrderedJSONObject, _ chapters: Set<Double>) -> Bool {
  if isOp(fields, in: dependentChapterActions) { return fields["chapter"]?.numberValue.map(chapters.contains) ?? false }
  guard isOp(fields, in: [.actionFinalize]), !chapters.isEmpty else { return false }
  guard let upTo = fields["upTo"]?.numberValue else { return true }
  return chapters.contains { $0 <= upTo }
}

// apps/novel-forge-server/src/modules/refinement/prose-intent.ts:31
private func proseEditIssue(_ fields: OrderedJSONObject, _ index: Int) -> String {
  if isOp(fields, in: [.draftRewritePassage]) {
    return
      "changeSet[\(index)]: draft.rewrite_passage needs Edit prose, which is off — drop it, say in the reply what you would change, and suggest turning on Edit prose; never turn a passage comment into a brief.update."
  }
  return
    "changeSet[\(index)]: \(op(fields) ?? "") changes the chapter's prose, but the author did not turn on Edit prose — a plan edit stays a plan edit. Propose brief.update (or the other plan ops) instead, and tell the author they can regenerate the chapter from the updated brief."
}

// apps/novel-forge-server/src/modules/refinement/prose-intent.ts:37
func proseEditIssues(_ changeSet: [OrderedJSONObject]?) -> [String] {
  (changeSet ?? []).enumerated().compactMap { index, fields in isProseEditOp(fields) ? proseEditIssue(fields, index) : nil }
}

// apps/novel-forge-server/src/modules/refinement/prose-intent.ts:42
func proseWithheldNote(_ changeSet: [OrderedJSONObject]) -> String {
  let withheld = changeSet.filter(isProseEditOp)
  return !withheld.isEmpty && withheld.allSatisfy({ isOp($0, in: [.draftRewritePassage]) }) ? passageEditWithheldNote : proseEditWithheldNote
}

// apps/novel-forge-server/src/modules/refinement/prose-intent.ts:47
func withoutProseEditOps(_ changeSet: [OrderedJSONObject]) -> (kept: [OrderedJSONObject], withheld: Int) {
  let chapters = Set(changeSet.filter(isProseEditOp).compactMap { $0["chapter"]?.numberValue })
  let kept = changeSet.filter { !isProseEditOp($0) && !dependsOnWithheld($0, chapters) }
  return (kept, changeSet.count - kept.count)
}
