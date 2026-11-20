import ShadowText

// apps/novel-forge-server/src/modules/refinement/write-policy.ts:319
private func isFilled(_ value: OrderedJSON?) -> Bool {
  switch value {
  case nil, .null?: false
  case .array(let items)?: !items.isEmpty
  case .string(let text)?: !text.jsTrim().isEmpty
  default: true
  }
}

// apps/novel-forge-server/src/modules/refinement/write-policy.ts:326
private func clearsField(_ type: OpType, _ fields: OrderedJSONObject, _ current: WritePolicyRecordFields?) -> Bool {
  guard let current else { return false }
  return declaredOpFields(type).contains { field in fields[field].map { !isFilled($0) } == true && isFilled(current[field]) }
}

// apps/novel-forge-server/src/modules/refinement/write-policy.ts:333
private func clearsPayoff(_ payoff: PromiseSetPayoff, _ current: WritePolicyRecordFields?) -> Bool {
  payoff.someday == true && WritePolicyTables.payoffFields.contains { isFilled(current?[$0]) }
}

// apps/novel-forge-server/src/modules/refinement/write-policy.ts:338
func alwaysCardRule(_ op: ChangeOp, _ state: WritePolicyState) -> AlwaysCardRule? {
  let current = state.fields(of: changeSetRefs([op]).first)
  let fields = opFields(op)
  if case .promiseSetPayoff(let payoff) = op.operation, clearsPayoff(payoff, current) || clearsField(op.type, fields, current) { return .removal }
  if let kindRule = op.type.alwaysCardRule { return kindRule }
  if clearsField(op.type, fields, current) { return .removal }

  switch op.operation {
  case .premiseUpdate:
    return WritePolicyTables.storyFields.contains { fields[$0] != nil && isFilled(current?[$0]) } ? .replacesStory : nil
  case .bibleDocumentUpsert(let page):
    return isWriterExcludedBibleDoc(BibleDocAddress(section: page.section.rawValue, slug: page.slug)) ? .plannerOnlyPage : nil
  case .volumeUpsert(let volume):
    return volume.body != nil || (current != nil && volume.ordinal != nil) ? .volumeStructure : nil
  case .promiseCreate:
    guard let current else { return nil }
    return current["status"] == .string("open") ? nil : .promiseReuse
  case .promiseUpdate(let promise):
    if promise.status != nil { return .promiseDisposition }
    return promise.lastAdvancedChapter != nil ? .promiseProgress : nil
  case .factUpsert(let fact):
    if current != nil, fact.body != nil { return .secretTruth }
    let declared = declaredOpFields(op.type)
    let gates = fields.keys.contains { declared.contains($0) && !WritePolicyTables.factDirectFields.contains($0) }
    return gates || (current != nil && fact.terms != nil) ? .secretGating : nil
  default:
    return nil
  }
}

// apps/novel-forge-server/src/modules/refinement/write-policy.ts:358
func isPlannerSide(_ op: ChangeOp) -> Bool {
  op.type.isPlannerSide
}

// apps/novel-forge-server/src/modules/refinement/write-policy.ts:363
func asChangeSetRef(_ ref: String) -> String {
  let prefix = "bible_doc:"
  return ref.jsStartsWith(prefix) ? "doc:\(ref.jsSlice(prefix.jsLength))" : ref
}

private func named(_ key: String?) -> String? {
  guard let key, !key.isEmpty else { return nil }
  return key
}

// apps/novel-forge-server/src/modules/refinement/write-policy.ts:368
func opReferences(_ op: ChangeOp) -> [String] {
  if isActionOp(op) {
    let fields = opFields(op)
    let chapterRefs = fields["chapter"]?.numberValue.map { ["chapter:\($0.jsString)", "draft:\($0.jsString)"] } ?? []
    let volumeRefs = fields["volumeKey"]?.stringValue.map { ["volume:\($0)"] } ?? []
    return chapterRefs + volumeRefs
  }

  switch op.operation {
  case .factUpsert(let fact):
    let unlock = (fact.unlock.value?.all ?? []).flatMap { term -> [String] in
      switch term {
      case .milestone(let key): ["milestone:\(key)"]
      case .volume(let key): ["volume:\(key)"]
      case .chapter, .ending: []
      }
    }
    return (fact.subjects ?? []).map { "entity:\($0)" } + unlock
  case .milestoneUpsert(let milestone):
    return named(milestone.subjectEntityKey.value).map { ["entity:\($0)"] } ?? []
  case .promiseSetPayoff(let payoff):
    return (named(payoff.payoffMilestoneKey.value).map { ["milestone:\($0)"] } ?? []) + (named(payoff.payoffVolumeKey.value).map { ["volume:\($0)"] } ?? [])
  case .briefUpdate(let brief):
    let learns = brief.knowledgeContract.value?.learns ?? []
    let entities: [String?] =
      [brief.pov.value] + (brief.scenes.value ?? []).map(\.pov) + (brief.knowledgeContract.value?.pov ?? []).map(Optional.some) + learns.map { Optional.some($0.entityKey) }
    return (named(brief.volumeKey).map { ["volume:\($0)"] } ?? []) + entities.compactMap { named($0).map { "entity:\($0)" } } + learns.map { "fact:\($0.factKey)" }
      + (brief.claimedMilestones.value ?? []).map { "milestone:\($0)" } + (brief.contextRefs ?? []).map(asChangeSetRef)
  default:
    return []
  }
}

// apps/novel-forge-server/src/modules/refinement/write-policy.ts:416
func ideaCardRule(_ op: ChangeOp) -> AlwaysCardRule? {
  if case .card(let rule) = op.type.ideaPolicy { return rule }
  guard case .volumeUpsert(let volume) = op.operation, volume.objective != nil else { return nil }
  return .plannerOnlyField
}
