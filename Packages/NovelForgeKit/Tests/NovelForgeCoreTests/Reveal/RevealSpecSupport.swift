@testable import NovelForgeCore

func object(_ pairs: (String, OrderedJSON)...) -> OrderedJSON {
  .object(OrderedJSONObject(pairs.map { (key: $0.0, value: $0.1) }))
}

func learning(_ factKeys: String...) -> OrderedJSON {
  object(
    ("pov", .array([.string("mira")])),
    ("learns", .array(factKeys.map { object(("entityKey", .string("mira")), ("factKey", .string($0))) }))
  )
}

func plan(_ chapter: Int, isEnding: Bool = false, claimed: [String]? = nil, contract: OrderedJSON = .null) -> PlanRow {
  PlanRow(claims: PlanClaims(chapter: chapter, volumeKey: "the_tower", isEnding: isEnding, claimedMilestones: claimed), knowledgeContract: contract)
}

func fact(_ factKey: String, revealChapter: Int? = nil, unlock: UnlockCondition? = nil, source: FactSource = .manual) -> RevealFact {
  RevealFact(factKey: factKey, revealChapter: revealChapter, unlock: unlock, source: source)
}

func world(_ plans: [PlanRow], milestones: [MilestoneRow] = []) -> PlanWorld {
  PlanWorld(plans: plans, milestones: milestones, volumeOrdinals: ["the_tower": 1])
}

func milestone(_ key: String, _ state: MilestoneState, reachedChapter: Int? = nil) -> MilestoneRow {
  MilestoneRow(milestoneKey: key, state: state, reachedChapter: reachedChapter)
}

func keys(_ values: [String]) -> Set<JSString> {
  Set(values.map { JSString($0) })
}
