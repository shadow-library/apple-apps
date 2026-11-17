import Foundation
import ShadowCore
import ShadowStore

// apps/novel-forge-server/src/modules/ai/schemas/knowledge-contract.schema.ts:3
private let contractKey = ProseRegex.literal("^[a-z0-9_]+$")

/// The author's chapter plan (apps/novel-forge-server/src/modules/generation/brief.service.ts). Whether an approval survives the edit, and which drafts go
/// stale, is derived from the plan terms; nothing here resets them.
public enum ChapterPlans {
  /// brief.service.ts:62 (updateBrief): creates the plan or edits it, refused for a chapter at or before the latest final one (PLN_005) and when the plan
  /// as written would claim a milestone it cannot (PLN_003), be a second ending (PLN_002) or reveal a fact still locked there (PLN_001). Raising the content
  /// mode to unrestricted is not gated here: the model catalog it asks is not ported yet.
  public static func write(novel: UUID, chapter: Int, _ edit: PlanEdit, in transaction: inout WriteTransaction) throws(DomainError) {
    let ref = try ChapterRefs.plan(novel: novel, chapter: chapter)
    let scenes = try normalizedScenes(edit.scenes)
    let ending = try handEdited(edit.endingContract)
    try requireContract(edit.knowledge)
    try requireKnown(edit.contentMode)
    guard case .live(let owner) = try transaction.presence(NovelForgeKey.novel(novel), as: NovelRecord.self) else { throw .novelNotFound(novel) }
    let world = try transaction.planWorld(novel: novel, chapter: chapter)
    guard chapter > world.frontier else { throw .planFinal(chapter) }
    let existing = try transaction.presence(ref, as: ChapterPlanRecord.self)
    var content: ChapterPlanContent
    if case .live(let plan) = existing {
      content = plan.content
    } else {
      content = ChapterPlanContent(body: edit.body, volume: world.nearestVolume(to: chapter), contentMode: owner.contentMode)
    }
    let before = content
    apply(edit, scenes: scenes, ending: ending, to: &content)
    if let refusal = try world.refusal(of: content, ref: ref, novel: novel, chapter: chapter) { throw refusal }
    do throws(StoreError) {
      switch existing {
      case .live:
        guard content != before else { return }
        _ = try ChapterPlanRecord.revise(ref, content, in: &transaction)
      case .removed(let plan):
        _ = try plan.restore(in: &transaction)
        _ = try ChapterPlanRecord.revise(ref, content, in: &transaction)
      case .absent:
        _ = try planRecord(novel: novel, chapter: chapter, content).create(in: &transaction)
      }
    } catch {
      throw .store(error)
    }
  }

  private static func apply(_ edit: PlanEdit, scenes: FieldChange<[PlanScene]?>, ending: FieldChange<ChapterEndingContract?>, to content: inout ChapterPlanContent) {
    if case .set(let scenes) = scenes {
      content.body = composePlanBody(edit.body, scenes: (scenes ?? []).map(\.scene))
      content.scenes = scenes
    } else {
      content.body = edit.body
    }
    content.densityRisk = nil
    content.handEdited = true
    if let title = trimmedOrNil(edit.title) { content.title = title }
    if case .set(let knowledge) = edit.knowledge {
      content.contract.pov = knowledge.pov
      content.contract.learns = knowledge.learns.map(ContractLearn.init)
    }
    if case .set(let ending) = ending { content.endingContract = ending }
    if case .set(let purpose) = edit.chapterPurpose { content.chapterPurpose = trimmedOrNil(purpose) }
    if case .set(let pov) = edit.pov { content.pov = trimmedOrNil(pov) }
    if case .set(let guidance) = edit.guidance { content.guidance = trimmedOrNil(guidance) }
    if case .set(let direction) = edit.direction { content.direction = trimmedOrNil(direction) }
    if case .set(let mode) = edit.contentMode { content.contentMode = mode }
    if case .set(let claimed) = edit.claimedMilestones { content.contract.claimedMilestones = claimed.map(normalizeStringList) ?? [] }
    if case .set(let ending) = edit.isEnding { content.contract.isEnding = ending }
  }

  // brief.service.ts:63-65: validated as sent, then normalized
  private static func normalizedScenes(_ change: FieldChange<[PlanScene]?>) throws(DomainError) -> FieldChange<[PlanScene]?> {
    guard case .set(let scenes?) = change else { return change }
    let errors = validateBriefScenes(.array(scenes.map { sceneJSON($0.scene) }))
    guard errors.isEmpty else { throw .scenesMalformed(errors.joined(separator: "; ")) }
    return .set(normalizeBriefScenes(scenes.map(\.scene)).map(PlanScene.init))
  }

  /// A scene in the shape the reference validates, with only the members it was given.
  private static func sceneJSON(_ scene: BriefScene) -> OrderedJSON {
    var members: [(key: String, value: OrderedJSON)] = [(key: "summary", value: .string(scene.summary)), (key: "pov", value: scene.pov.map(OrderedJSON.string) ?? .null)]
    for (key, text) in [("goal", scene.goal), ("obstacle", scene.obstacle), ("turn", scene.turn)] {
      if let text { members.append((key: key, value: .string(text))) }
    }
    if let beats = scene.beats { members.append((key: "beats", value: .array(beats.map(OrderedJSON.string)))) }
    if let words = scene.estimatedWords { members.append((key: "estimatedWords", value: .int(Int64(words)))) }
    return .object(OrderedJSONObject(members))
  }

  // brief.service.ts:27 (handEditedEndingContract)
  private static func handEdited(_ change: FieldChange<ChapterEndingContract?>) throws(DomainError) -> FieldChange<ChapterEndingContract?> {
    guard case .set(let contract?) = change else { return change }
    guard case .known = contract.hookType else { throw .invalidKey(field: "endingContract.hookType") }
    let fields = [("emotionalBeat", contract.emotionalBeat.jsTrim()), ("openQuestion", contract.openQuestion.jsTrim()), ("handoffState", contract.handoffState.jsTrim())]
    let missing = fields.filter { $0.1.isEmpty }.map(\.0)
    guard missing.isEmpty else { throw .endingIncomplete(fields: missing.joined(separator: ", ")) }
    let mustNotResolve = (contract.mustNotResolve ?? []).map { $0.jsTrim() }.filter { !$0.isEmpty }
    return .set(
      ChapterEndingContract(hookType: contract.hookType, emotionalBeat: fields[0].1, openQuestion: fields[1].1, handoffState: fields[2].1, mustNotResolve: mustNotResolve))
  }

  // knowledge-contract.schema.ts:6-18: at least one POV entity, and learns named by keys
  private static func requireContract(_ change: FieldChange<PlanKnowledge>) throws(DomainError) {
    guard case .set(let knowledge) = change else { return }
    guard !knowledge.pov.isEmpty else { throw .belowMinimum(field: "knowledgeContract.pov", minimum: 1) }
    for learn in knowledge.learns {
      guard contractKey.test(learn.entityKey) else { throw .invalidKey(field: "knowledgeContract.learns.entityKey") }
      guard contractKey.test(learn.factKey) else { throw .invalidKey(field: "knowledgeContract.learns.factKey") }
    }
  }

  private static func requireKnown(_ change: FieldChange<StoredEnum<ContentMode>?>) throws(DomainError) {
    guard case .set(.unknown?) = change else { return }
    throw .invalidKey(field: "contentMode")
  }

  private static func planRecord(novel: UUID, chapter: Int, _ content: ChapterPlanContent) throws(StoreError) -> ChapterPlanRecord {
    do throws(NovelForgeKeyError) {
      return try ChapterPlanRecord(novel: novel, chapter: chapter, content: content)
    } catch {
      throw .invalidChange(error.errorDescription ?? error.code)
    }
  }
}
