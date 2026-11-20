import Foundation
import ShadowCore
import ShadowText

extension ArtifactSubject {
  // The hash input follows the reference's field lists (artifact-state.ts:50-199, common/content-hash.ts:21-47) over the native record, canonicalised by computeContentHash so two devices agree
  var contentHash: String {
    switch self {
    case .premise(let novel): computeContentHash(premiseHashInput(novel))
    case .doc(let page): computeBibleDocHash(frontmatter: page.content.frontmatter.map { OrderedJSON(.object($0)) }, body: page.content.body.map(OrderedJSON.string))
    case .volume(let volume): volumeContentHash(volume.hashRecord)
    case .chapter(let plan): plan.contentHash
    case .draft(let draft):
      computeContentHash(jsonRecord([("title", optionalText(draft.content.title)), ("body", .string(draft.content.body)), ("summary", optionalText(draft.content.summary))]))
    case .entity(let entity):
      computeContentHash(
        jsonRecord([
          ("name", .string(entity.name)), ("type", .string(entity.type.rawValue)), ("status", optionalText(entity.status)), ("motivation", optionalText(entity.motivation)),
          ("notes", optionalText(entity.notes)), ("body", optionalText(entity.body)),
        ]))
    case .fact(let fact): computeContentHash(factHashInput(fact))
    case .milestone(let milestone):
      computeContentHash(jsonRecord([("label", .string(milestone.label)), ("subjectEntityKey", optionalText(milestone.subject)), ("kind", .string(milestone.kind.rawValue))]))
    case .thread(let thread):
      computeContentHash(
        jsonRecord([
          ("label", optionalText(thread.summary)), ("status", .string(thread.status.state.rawValue)), ("closedChapter", optionalNumber(thread.status.chapter)),
          ("lastAdvancedChapter", .null), ("payoffWindow", optionalNumber(thread.payoffWindow)), ("payoffMilestoneKey", optionalText(thread.payoffMilestone)),
          ("payoffVolumeKey", optionalText(thread.payoffVolume)), ("intentionallyOpen", .bool(thread.dormant)),
        ]))
    case .mystery(let mystery):
      computeContentHash(
        jsonRecord([
          ("label", .string(mystery.question)), ("status", .string(mystery.status.state.rawValue)), ("resolvedChapter", optionalNumber(mystery.status.chapter)),
          ("lastAdvancedChapter", .null), ("payoffWindow", optionalNumber(mystery.payoffWindow)), ("payoffMilestoneKey", optionalText(mystery.payoffMilestone)),
          ("payoffVolumeKey", optionalText(mystery.payoffVolume)), ("intentionallyOpen", .bool(mystery.dormant)),
        ]))
    }
  }
}

private func premiseHashInput(_ novel: NovelRecord) -> OrderedJSONObject {
  var pairs: [(String, OrderedJSON)] = [
    ("premise", optionalText(novel.premise)), ("brief", optionalText(novel.brief)), ("themes", optionalList(novel.themes)), ("instructions", optionalText(novel.writingStyle)),
  ]
  let story: [(String, String?)] = [
    ("theme", novel.theme), ("readerPromise", novel.readerPromise), ("protagonistKey", novel.protagonist), ("opposition", novel.opposition),
    ("endingQuestion", novel.endingQuestion), ("ending", novel.ending),
  ]
  for (field, value) in story { if let value { pairs.append((field, .string(value))) } }
  return jsonRecord(pairs)
}

private func factHashInput(_ fact: SecretRecord) -> OrderedJSONObject {
  var pairs: [(String, OrderedJSON)] = [
    ("text", .string(fact.text)), ("subjects", optionalList(fact.subjects)), ("constraintNote", optionalText(fact.constraintNote)),
    ("terms", optionalList(fact.cluesAndTerms?.terms)),
    ("revealChapter", optionalNumber(fact.revealChapter)),
  ]
  if let writerNote = fact.writerNote { pairs.append(("writerNote", .string(writerNote))) }
  if let unlock = fact.unlock, unlock != .null { pairs.append(("unlock", OrderedJSON(unlock))) }
  if let clues = fact.cluesAndTerms?.clues { pairs.append(("allowedClues", optionalList(clues))) }
  return jsonRecord(pairs)
}

extension VolumeRecord {
  // The state is derived from the volumes' order and goals, so it stays out of the hash; the reference joins it only once it leaves not_started
  fileprivate var hashRecord: OrderedJSONObject {
    jsonRecord([
      ("volumeKey", .string(volume)), ("ordinal", optionalNumber(ordinal)), ("title", optionalText(title)), ("objective", optionalText(objective)), ("body", optionalText(body)),
    ])
  }
}

extension ChapterPlanRecord {
  // writeMode and densityRisk are written by brief.update but are outside the reference's brief field list, so they extend the hash natively; a plan without them keeps the reference hash
  fileprivate var contentHash: String {
    let base = briefContentHash(hashRecord)
    var extras: [(String, OrderedJSON)] = []
    if content.writeMode != .known(.standard) { extras.append(("writeMode", .string(content.writeMode.rawValue))) }
    if let risk = content.densityRisk { extras.append(("densityRisk", .string(risk))) }
    return extras.isEmpty ? base : computeContentHash(jsonRecord([("base", .string(base))] + extras))
  }

  fileprivate var hashRecord: OrderedJSONObject {
    let plan = content
    let ending: OrderedJSON =
      plan.endingContract.map { contract in
        var pairs: [(String, OrderedJSON)] = [
          ("hookType", .string(contract.hookType.rawValue)), ("emotionalBeat", .string(contract.emotionalBeat)), ("openQuestion", .string(contract.openQuestion)),
          ("handoffState", .string(contract.handoffState)),
        ]
        if let mustNotResolve = contract.mustNotResolve { pairs.append(("mustNotResolve", optionalList(mustNotResolve))) }
        return .object(jsonRecord(pairs))
      } ?? .null
    let contract = plan.contract
    var knowledge = OrderedJSON.null
    if !contract.pov.isEmpty || !contract.learns.isEmpty {
      var pairs: [(String, OrderedJSON)] = [("pov", optionalList(contract.pov))]
      if !contract.learns.isEmpty {
        pairs.append(("learns", .array(contract.reveals.map { .object(jsonRecord([("entityKey", .string($0.entityKey)), ("factKey", .string($0.factKey))])) })))
      }
      knowledge = .object(jsonRecord(pairs))
    }
    let claimed = plan.contract.claimedMilestones
    return jsonRecord([
      ("chapter", optionalNumber(chapter)), ("volumeKey", optionalText(plan.volume)), ("title", optionalText(plan.title)), ("body", .string(plan.body)),
      ("contextRefs", optionalList(plan.contextRefs)),
      ("pov", optionalText(plan.pov)), ("endingContract", ending), ("knowledgeContract", knowledge), ("chapterPurpose", optionalText(plan.chapterPurpose)),
      ("readerValue", optionalList(plan.readerValue)), ("repetitionRisks", optionalList(plan.repetitionRisks)), ("guidance", optionalText(plan.guidance)),
      ("direction", optionalText(plan.direction)),
      ("contentMode", optionalText(plan.contentMode?.rawValue)), ("scenes", plan.scenes.map { .array($0.map { sceneJSON($0.scene) }) } ?? .null),
      ("claimedMilestones", claimed.isEmpty ? .null : optionalList(claimed)), ("isEnding", .bool(plan.contract.isEnding)),
    ])
  }
}
