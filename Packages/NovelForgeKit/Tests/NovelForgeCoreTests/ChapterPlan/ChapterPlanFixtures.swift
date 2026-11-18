import Foundation

@testable import NovelForgeCore

typealias PlanJSON = [String: Any]

enum ChapterPlanFixtureError: Error {
  case malformed(String)
}

enum ChapterPlanFixture {
  static func cases(_ name: String) throws -> [PlanJSON] {
    let root = try JSONSerialization.jsonObject(with: ReferenceFixture.data("chapter-plan/chapter-plan.json")) as? PlanJSON
    return root?[name] as? [PlanJSON] ?? []
  }

  static func ordered(_ value: Any) throws -> OrderedJSON {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    return try OrderedJSON(parsing: String(decoding: data, as: UTF8.self))
  }

  static func decode<Value: Decodable>(_ value: Any) throws -> Value {
    try JSONDecoder().decode(Value.self, from: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
  }

  static func same(_ actual: Any, _ expected: Any) -> Bool {
    (actual as AnyObject).isEqual(expected)
  }
}

extension Dictionary where Key == String, Value == Any {
  func text(_ key: String) -> String? { self[key] as? String }
  func number(_ key: String) -> Int? { (self[key] as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.intValue } }
  func flag(_ key: String) -> Bool { (self[key] as? NSNumber)?.boolValue ?? false }
  func list(_ key: String) -> [String]? { self[key] as? [String] }
  func object(_ key: String) -> PlanJSON? { self[key] as? PlanJSON }
  func objects(_ key: String) -> [PlanJSON] { self[key] as? [PlanJSON] ?? [] }
}

func promise(_ json: PlanJSON) -> PlanPromise {
  PlanPromise(
    kind: json.text("kind") == "thread" ? .thread : .mystery, key: json.text("key") ?? "", text: json.text("text"), isOpen: json.flag("isOpen"),
    intentionallyOpen: json.flag("intentionallyOpen"), openedChapter: json.number("openedChapter"), lastAdvancedChapter: json.number("lastAdvancedChapter"),
    payoff: PromisePayoff(payoffWindow: json.number("payoffWindow"), payoffMilestoneKey: json.text("payoffMilestoneKey"), payoffVolumeKey: json.text("payoffVolumeKey")))
}

func obligationSources(_ json: PlanJSON) -> ObligationSources {
  let ending = json.object("previousEnding").map { PlanEnding(openQuestion: $0.text("openQuestion"), handoffState: $0.text("handoffState")) }
  let volume = json.object("volume").map { ObligationVolume(volumeKey: $0.text("volumeKey") ?? "", title: $0.text("title"), objective: $0.text("objective")) }
  let milestones = (json.object("milestoneStates") ?? [:]).compactMap { key, value in (value as? String).flatMap(MilestoneState.init(rawValue:)).map { (key: key, value: $0) } }
  let volumes = (json.object("volumeStates") ?? [:]).compactMap { key, value in (value as? String).flatMap(VolumeState.init(rawValue:)).map { (key: key, value: $0) } }
  return ObligationSources(
    chapter: json.number("chapter") ?? 0, previousEnding: ending, threads: json.objects("threads").map(promise), mysteries: json.objects("mysteries").map(promise), volume: volume,
    milestoneStates: Dictionary(jsEntries: milestones), volumeStates: Dictionary(jsEntries: volumes))
}

func planClaims(_ json: PlanJSON) -> PlanClaims {
  PlanClaims(chapter: json.number("chapter") ?? 0, volumeKey: json.text("volumeKey"), isEnding: json.flag("isEnding"), claimedMilestones: json.list("claimedMilestones"))
}

func planWorld(_ json: PlanJSON) -> PlanWorld {
  let ordinals = (json.object("volumeOrdinals") ?? [:]).compactMap { key, value in (value as? Int).map { (key: key, value: $0) } }
  return PlanWorld(
    plans: json.objects("plans").map { PlanRow(claims: planClaims($0), knowledgeContract: .null) },
    milestones: json.objects("milestones").map {
      MilestoneRow(milestoneKey: $0.text("milestoneKey") ?? "", state: MilestoneState(rawValue: $0.text("state") ?? "") ?? .open, reachedChapter: $0.number("reachedChapter"))
    },
    volumeOrdinals: Dictionary(jsEntries: ordinals))
}

func planFact(_ json: PlanJSON) throws -> PlanFact {
  PlanFact(
    factKey: json.text("factKey") ?? "", revealChapter: json.number("revealChapter"), unlock: try json.object("unlock").map { try ChapterPlanFixture.decode($0) },
    source: FactSource(rawValue: json.text("source") ?? "") ?? .manual, terms: json.list("terms") ?? [], writerNote: json.text("writerNote"))
}

func planMilestone(_ json: PlanJSON) -> PlanMilestone {
  PlanMilestone(
    milestoneKey: json.text("milestoneKey") ?? "", label: json.text("label") ?? "", subjectEntityKey: json.text("subjectEntityKey"),
    state: MilestoneState(rawValue: json.text("state") ?? "") ?? .open)
}

func plannedChapter(_ json: PlanJSON) throws -> PlannedChapter {
  guard let record = try ChapterPlanFixture.ordered(json.object("endingContract") ?? [:]).objectValue, let ending = EndingContract(record) else {
    throw ChapterPlanFixtureError.malformed("endingContract")
  }
  let contract = try json.object("knowledgeContract").map { try ChapterPlanFixture.ordered($0).objectValue.flatMap(ChangeKnowledgeContract.init) }
  return PlannedChapter(
    title: json.text("title") ?? "", objective: json.text("objective") ?? "", scenes: try (json["scenes"] as? [Any] ?? []).map { try ChapterPlanFixture.decode($0) },
    continuesIntoNextChapter: json.flag("continuesIntoNextChapter"), startsFromPreviousChapter: json.flag("startsFromPreviousChapter"), handoffBeat: json.text("handoffBeat"),
    endingContract: ending, knowledgeContract: contract ?? nil, claimedMilestones: json.list("claimedMilestones"), chapterPurpose: json.text("chapterPurpose") ?? "",
    readerValue: json.list("readerValue") ?? [], repetitionRisks: json.list("repetitionRisks"), densityRisk: json.text("densityRisk"), moves: json.text("moves"))
}

func planSceneJSON(_ scene: BriefScene) -> PlanJSON {
  var json: PlanJSON = ["summary": scene.summary]
  if let pov = scene.pov { json["pov"] = pov }
  if let goal = scene.goal { json["goal"] = goal }
  if let obstacle = scene.obstacle { json["obstacle"] = obstacle }
  if let turn = scene.turn { json["turn"] = turn }
  if let beats = scene.beats { json["beats"] = beats }
  if let words = scene.estimatedWords { json["estimatedWords"] = words }
  return json
}

func foundation(_ value: OrderedJSON) throws -> PlanJSON {
  try JSONSerialization.jsonObject(with: Data(value.jsonText.utf8)) as? PlanJSON ?? [:]
}

func plannedJSON(_ plan: PlannedChapter) throws -> PlanJSON {
  var json: PlanJSON = [
    "title": plan.title, "objective": plan.objective, "scenes": plan.scenes.map(planSceneJSON), "chapterPurpose": plan.chapterPurpose, "readerValue": plan.readerValue,
  ]
  json["endingContract"] = try foundation(plan.endingContract.json)
  if plan.continuesIntoNextChapter { json["continuesIntoNextChapter"] = true }
  if plan.startsFromPreviousChapter { json["startsFromPreviousChapter"] = true }
  if let beat = plan.handoffBeat { json["handoffBeat"] = beat }
  if let contract = plan.knowledgeContract { json["knowledgeContract"] = try foundation(contract.json) }
  if let claims = plan.claimedMilestones { json["claimedMilestones"] = claims }
  if let risks = plan.repetitionRisks { json["repetitionRisks"] = risks }
  if let density = plan.densityRisk { json["densityRisk"] = density }
  if let moves = plan.moves { json["moves"] = moves }
  return json
}

func cardOpJSON(_ op: PlanCardOp) throws -> PlanJSON {
  var encoder = OpEncoder()
  op.update.encode(into: &encoder)
  var json = try foundation(jsonObject(encoder.pairs.map { ($0.key, $0.value) }))
  json["op"] = "brief.update"
  if let rationale = op.rationale { json["rationale"] = rationale }
  if op.startedEmpty { json["startedEmpty"] = true }
  return json
}

func violationJSON(_ violation: RevealViolation) -> PlanJSON {
  ["subject": violation.subject, "field": violation.field, "factKey": violation.factKey, "revealChapter": violation.revealChapter.map { $0 as Any } ?? NSNull()]
}
