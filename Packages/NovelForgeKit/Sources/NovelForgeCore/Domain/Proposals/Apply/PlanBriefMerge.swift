import Foundation
import ShadowCore
import ShadowStore

// apps/novel-forge-server/src/modules/refinement/brief-merge.ts:6: read only for a plan the op creates, and only for a field it leaves out
struct PlanDefaults: Sendable, Equatable {
  var volume: String?
  var contentMode: StoredEnum<ContentMode>?
}

enum PlanBriefMerge {
  /// brief-merge.ts:44: the plan as applying `update` leaves it; pure, so a plan card's preview judges what the apply would write. The plan's guidance, its
  /// inserted mark and members this version does not know are kept from the plan it merges into.
  static func merged(_ existing: ChapterPlanContent?, _ update: BriefUpdate, defaults: PlanDefaults) -> ChapterPlanContent {
    var content = existing ?? ChapterPlanContent(body: "")
    if let title = update.title { content.title = title }
    if let body = update.body { content.body = body }
    if let mode = update.writeMode { content.writeMode = .known(mode) }
    if let volume = update.volumeKey {
      content.volume = volume
    } else if existing == nil {
      content.volume = defaults.volume
    }
    if let refs = update.contextRefs { content.contextRefs = refs }
    content.pov = trimmed(update.pov, keeping: content.pov)
    if let purpose = update.chapterPurpose { content.chapterPurpose = purpose }
    if let value = update.readerValue { content.readerValue = value }
    content.repetitionRisks = kept(update.repetitionRisks, content.repetitionRisks)
    content.densityRisk = trimmed(update.densityRisk, keeping: content.densityRisk)
    if let ending = update.endingContract {
      content.endingContract = ChapterEndingContract(
        hookType: .known(ending.hookType), emotionalBeat: ending.emotionalBeat, openQuestion: ending.openQuestion, handoffState: ending.handoffState,
        mustNotResolve: ending.mustNotResolve)
    }
    switch update.knowledgeContract {
    case .omitted: break
    case .null: (content.contract.pov, content.contract.learns) = ([], [])
    case .set(let knowledge): (content.contract.pov, content.contract.learns) = (knowledge.pov, (knowledge.learns ?? []).map(ContractLearn.init))
    }
    content.direction = trimmed(update.direction, keeping: content.direction)
    switch update.contentMode {
    case .omitted: if existing == nil { content.contentMode = defaults.contentMode }
    case .null: content.contentMode = nil
    case .set(let mode): content.contentMode = .known(mode)
    }
    content.scenes = kept(update.scenes.map { normalizeBriefScenes($0).map(PlanScene.init) }, content.scenes)
    switch update.claimedMilestones {
    case .omitted: break
    case .null: content.contract.claimedMilestones = []
    case .set(let claimed): content.contract.claimedMilestones = normalizeStringList(claimed)
    }
    if let ending = update.isEnding { content.contract.isEnding = ending }
    if update.scenes != .omitted { content.body = composePlanBody(content.body, scenes: (content.scenes ?? []).map(\.scene)) }
    content.handEdited = true
    return content
  }

  private static func trimmed(_ value: OpValue<String>, keeping current: String?) -> String? {
    switch value {
    case .omitted: current
    case .null: nil
    case .set(let text): trimmedOrNil(text)
    }
  }

  private static func kept<Value>(_ value: OpValue<Value>, _ current: Value?) -> Value? {
    switch value {
    case .omitted: current
    case .null: nil
    case .set(let given): given
    }
  }
}

extension OpValue {
  fileprivate func map<Other: Sendable & Equatable>(_ transform: (Value) -> Other) -> OpValue<Other> {
    switch self {
    case .omitted: .omitted
    case .null: .null
    case .set(let value): .set(transform(value))
    }
  }
}
