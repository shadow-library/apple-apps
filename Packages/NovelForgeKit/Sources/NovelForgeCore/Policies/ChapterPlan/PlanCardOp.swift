struct PlanCardOp: Equatable, Sendable {
  var update: BriefUpdate
  var rationale: String?
  var startedEmpty = false
}

struct PlanOpInput: Equatable, Sendable {
  var chapter: Int
  var steer: String?
  var rationale: String?
}

struct ExistingPlan: Equatable, Sendable {
  var hasKnowledgeContract: Bool
  var direction: String?
}

private func blankUpdate(chapter: Int) -> BriefUpdate {
  let record = OrderedJSONObject([(key: "chapter", value: .int(Int64(chapter)))])
  guard let update = BriefUpdate(OpFields(record: record)) else { preconditionFailure("a brief.update with a chapter always reads") }
  return update
}

private func knowledgeContract(pov: [String], learns: [KnowledgeReveal]) -> ChangeKnowledgeContract? {
  let reveals = learns.map { jsonObject([("entityKey", .string($0.entityKey)), ("factKey", .string($0.factKey))]) }
  let record = OrderedJSONObject([(key: "pov", value: .array(pov.map(OrderedJSON.string))), (key: "learns", value: .array(reveals))])
  return ChangeKnowledgeContract(record)
}

// apps/novel-forge-server/src/common/brief-body.ts:89
private func briefFrame(_ plan: PlannedChapter) -> String {
  var lines = [plan.objective.jsReplace(ProseRegex.whitespaceRunGlobal, " ").jsTrim()]
  if plan.continuesIntoNextChapter { lines.append(continuesLine) }
  if plan.startsFromPreviousChapter { lines.append(startsLine) }
  if let beat = plan.handoffBeat, !beat.isEmpty { lines.append(handoffPrefix + beat) }
  return lines.joined(separator: "\n")
}

// apps/novel-forge-server/src/modules/actions/chapter-plan.ts:273
func emptyPlanOp(_ input: PlanOpInput) -> PlanCardOp {
  var update = blankUpdate(chapter: input.chapter)
  update.body = ""
  update.scenes = .set([])
  update.claimedMilestones = .set([])
  if let steer = input.steer, !steer.isEmpty { update.direction = .set(steer) }
  return PlanCardOp(update: update, rationale: input.rationale.flatMap { $0.isEmpty ? nil : $0 }, startedEmpty: true)
}

// apps/novel-forge-server/src/modules/actions/chapter-plan.ts:284
func chapterPlanOp(_ input: PlanOpInput, existing: ExistingPlan?, vetted: VettedPlan, contextRefs: [String]) -> PlanCardOp {
  let plan = vetted.plan
  let scenes = normalizeBriefScenes(plan.scenes)
  let scenePovs = scenes.compactMap(\.pov).jsUnique()
  let learns = (plan.knowledgeContract?.learns ?? []).map { KnowledgeReveal(entityKey: $0.entityKey, factKey: $0.factKey) }
  let contractPov = scenePovs.isEmpty ? (plan.knowledgeContract?.pov ?? []).jsUnique() : scenePovs
  var update = blankUpdate(chapter: input.chapter)
  update.title = plan.title
  update.body = composePlanBody(briefFrame(plan), scenes: scenes)
  update.contextRefs = contextRefs
  update.pov = scenePovs.first.map { .set($0) } ?? .null
  update.chapterPurpose = plan.chapterPurpose
  update.readerValue = plan.readerValue
  update.repetitionRisks = plan.repetitionRisks.flatMap { $0.isEmpty ? nil : .set($0) } ?? .null
  update.densityRisk = plan.densityRisk.map { $0.jsTrim() }.flatMap { $0.isEmpty ? nil : .set($0) } ?? .null
  update.endingContract = plan.endingContract
  update.scenes = .set(scenes)
  update.claimedMilestones = .set(vetted.claimedMilestones)
  if !contractPov.isEmpty, !scenePovs.isEmpty || !learns.isEmpty, let contract = knowledgeContract(pov: contractPov, learns: learns) {
    update.knowledgeContract = .set(contract)
  } else if existing?.hasKnowledgeContract == true {
    update.knowledgeContract = .null
  }
  if let steer = input.steer, !steer.isEmpty {
    update.direction = .set(steer)
  } else if let direction = existing?.direction, !direction.isEmpty {
    update.direction = .null
  }
  return PlanCardOp(update: update, rationale: input.rationale.flatMap { $0.isEmpty ? nil : $0 })
}
