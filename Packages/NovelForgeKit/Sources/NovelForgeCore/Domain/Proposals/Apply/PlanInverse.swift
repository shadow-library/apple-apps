import Foundation
import ShadowCore
import ShadowText

/// A plan as an inverse writes it back (brief.handler.ts:19-41): every field the op can change, explicit, an empty one `null`; the knowledge contract always
/// named, so an undone reveal does not merge as "keep". No contract is `null`, as are no claims.
struct BriefRestore: Sendable, Equatable {
  let chapter: Int
  let title: String?
  let body: String
  let volume: String?
  let writeMode: StoredEnum<BriefWriteMode>
  let handEdited: Bool
  let contextRefs: [String]?
  let pov: String?
  let chapterPurpose: String?
  let readerValue: [String]?
  let repetitionRisks: [String]?
  let densityRisk: String?
  let endingContract: ChapterEndingContract?
  let knowledgePov: [String]
  let learns: [KnowledgeReveal]
  let direction: String?
  let contentMode: StoredEnum<ContentMode>?
  let scenes: [BriefScene]?
  let claimedMilestones: [String]
  let isEnding: Bool

  init(_ content: ChapterPlanContent, chapter: Int) {
    self.chapter = chapter
    title = content.title
    body = content.body
    volume = content.volume
    writeMode = content.writeMode
    handEdited = content.handEdited
    contextRefs = content.contextRefs
    pov = content.pov
    chapterPurpose = content.chapterPurpose
    readerValue = content.readerValue
    repetitionRisks = content.repetitionRisks
    densityRisk = content.densityRisk
    endingContract = content.endingContract
    knowledgePov = content.contract.pov
    learns = content.contract.reveals
    direction = content.direction
    contentMode = content.contentMode
    scenes = content.scenes?.map(\.scene)
    claimedMilestones = content.contract.claimedMilestones
    isEnding = content.contract.isEnding
  }

  fileprivate init(_ members: InverseMembers, chapter: Int) throws(ApplyRefusal) {
    self.chapter = chapter
    title = try members.nullableString("title")
    body = try members.string("body")
    volume = try members.nullableString("volumeKey")
    writeMode = StoredEnum(rawValue: try members.string("writeMode"))
    handEdited = try members.bool("handEdited")
    contextRefs = try members.nullableStrings("contextRefs")
    pov = try members.nullableString("pov")
    chapterPurpose = try members.nullableString("chapterPurpose")
    readerValue = try members.nullableStrings("readerValue")
    repetitionRisks = try members.nullableStrings("repetitionRisks")
    densityRisk = try members.nullableString("densityRisk")
    endingContract = try members.nullable("endingContract", endingContractValue)
    let knowledge = try members.nullable("knowledgeContract", knowledgeValue)
    knowledgePov = knowledge?.pov ?? []
    learns = knowledge?.learns ?? []
    direction = try members.nullableString("direction")
    contentMode = try members.nullable("contentMode") { $0.stringValue.map(StoredEnum.init(rawValue:)) }
    scenes = try members.nullable("scenes") { value in
      guard let items = value.arrayValue else { return nil }
      let scenes = items.compactMap(sceneValue)
      return scenes.count == items.count ? scenes : nil
    }
    claimedMilestones = try members.nullableStrings("claimedMilestones") ?? []
    isEnding = try members.bool("isEnding")
  }

  // brief.handler.ts:18
  static func removal(chapter: Int) -> OrderedJSONObject {
    inverseOp(.briefRemove, [("chapter", .int(Int64(chapter)))])
  }

  var json: OrderedJSONObject {
    let knowledge: OrderedJSON =
      knowledgePov.isEmpty && learns.isEmpty
      ? .null : jsonObject([("pov", inverseList(knowledgePov)), ("learns", .array(learns.map(learnJSON)))])
    return inverseOp(
      .briefUpdate,
      [
        ("chapter", .int(Int64(chapter))), ("title", inverseText(title)), ("body", .string(body)), ("volumeKey", inverseText(volume)),
        ("writeMode", .string(writeMode.rawValue)), ("handEdited", .bool(handEdited)), ("contextRefs", inverseList(contextRefs)), ("pov", inverseText(pov)),
        ("chapterPurpose", inverseText(chapterPurpose)), ("readerValue", inverseList(readerValue)), ("repetitionRisks", inverseList(repetitionRisks)),
        ("densityRisk", inverseText(densityRisk)), ("endingContract", endingContract.map(endingJSON) ?? .null), ("knowledgeContract", knowledge),
        ("direction", inverseText(direction)), ("contentMode", inverseText(contentMode?.rawValue)), ("scenes", scenes.map { .array($0.map(sceneJSON)) } ?? .null),
        ("claimedMilestones", claimedMilestones.isEmpty ? .null : inverseList(claimedMilestones)), ("isEnding", .bool(isEnding)),
      ])
  }

  /// The captured fields written over `base` verbatim, with none of the trimming, normalising or scene rendering an op's merge does. A scene list, ending
  /// contract or learn that comes back unchanged keeps what `base` holds of it beyond the captured fields.
  func restoring(over base: ChapterPlanContent) -> ChapterPlanContent {
    var content = base
    content.title = title
    content.body = body
    content.volume = volume
    content.writeMode = writeMode
    content.handEdited = handEdited
    content.contextRefs = contextRefs
    content.pov = pov
    content.chapterPurpose = chapterPurpose
    content.readerValue = readerValue
    content.repetitionRisks = repetitionRisks
    content.densityRisk = densityRisk
    if base.endingContract.map(endingJSON) != endingContract.map(endingJSON) { content.endingContract = endingContract }
    content.contract.pov = knowledgePov
    if base.contract.reveals.map(learnJSON) != learns.map(learnJSON) { content.contract.learns = learns.map(ContractLearn.init) }
    content.direction = direction
    content.contentMode = contentMode
    let heldScenes: OrderedJSON? = base.scenes.map { .array($0.map { sceneJSON($0.scene) }) }
    let restoredScenes: OrderedJSON? = scenes.map { .array($0.map(sceneJSON)) }
    if heldScenes != restoredScenes { content.scenes = scenes?.map(PlanScene.init) }
    content.contract.claimedMilestones = claimedMilestones
    content.contract.isEnding = isEnding
    return content
  }
}

enum PlanRestore: Sendable, Equatable {
  case brief(BriefRestore)
  case removal(chapter: Int)

  init(_ inverse: OrderedJSONObject) throws(ApplyRefusal) {
    let members = InverseMembers(inverse)
    let chapter = try members.required("chapter", inverseInt)
    guard chapter >= 1 else { throw .malformedInverse }
    switch members.type {
    case .briefUpdate?: self = .brief(try BriefRestore(members, chapter: chapter))
    case .briefRemove?: self = .removal(chapter: chapter)
    default: throw .malformedInverse
    }
  }
}

private func learnJSON(_ learn: KnowledgeReveal) -> OrderedJSON {
  jsonObject([("entityKey", .string(learn.entityKey)), ("factKey", .string(learn.factKey))])
}

private func endingJSON(_ contract: ChapterEndingContract) -> OrderedJSON {
  var pairs: [(String, OrderedJSON)] = [
    ("hookType", .string(contract.hookType.rawValue)), ("emotionalBeat", .string(contract.emotionalBeat)), ("openQuestion", .string(contract.openQuestion)),
    ("handoffState", .string(contract.handoffState)),
  ]
  if let mustNotResolve = contract.mustNotResolve { pairs.append(("mustNotResolve", inverseList(mustNotResolve))) }
  return jsonObject(pairs)
}

private func endingContractValue(_ value: OrderedJSON) -> ChapterEndingContract? {
  guard let record = value.objectValue, let hookType = record["hookType"]?.stringValue, let beat = record["emotionalBeat"]?.stringValue,
    let question = record["openQuestion"]?.stringValue, let handoff = record["handoffState"]?.stringValue
  else { return nil }
  var mustNotResolve: [String]?
  if let raw = record["mustNotResolve"] {
    guard let list = inverseStrings(raw) else { return nil }
    mustNotResolve = list
  }
  return ChapterEndingContract(hookType: StoredEnum(rawValue: hookType), emotionalBeat: beat, openQuestion: question, handoffState: handoff, mustNotResolve: mustNotResolve)
}

private func knowledgeValue(_ value: OrderedJSON) -> (pov: [String], learns: [KnowledgeReveal])? {
  guard let record = value.objectValue, let pov = record["pov"].flatMap(inverseStrings) else { return nil }
  guard let raw = record["learns"] else { return (pov, []) }
  guard let items = raw.arrayValue else { return nil }
  let learns = items.compactMap { item -> KnowledgeReveal? in
    guard let learn = item.objectValue, let entity = learn["entityKey"]?.stringValue, let fact = learn["factKey"]?.stringValue else { return nil }
    return KnowledgeReveal(entityKey: entity, factKey: fact)
  }
  return learns.count == items.count ? (pov, learns) : nil
}

private func sceneValue(_ value: OrderedJSON) -> BriefScene? {
  guard let record = value.objectValue, let summary = record["summary"]?.stringValue else { return nil }
  var scene = BriefScene(summary: summary)
  for (key, path) in [("pov", \BriefScene.pov), ("goal", \BriefScene.goal), ("obstacle", \BriefScene.obstacle), ("turn", \BriefScene.turn)] {
    guard let raw = record[key], !raw.isNull else { continue }
    guard let text = raw.stringValue else { return nil }
    scene[keyPath: path] = text
  }
  if let raw = record["beats"] {
    guard let beats = inverseStrings(raw) else { return nil }
    scene.beats = beats
  }
  if let raw = record["estimatedWords"] {
    guard let words = raw.numberValue.flatMap({ Int(exactly: $0) }) else { return nil }
    scene.estimatedWords = words
  }
  return scene
}
