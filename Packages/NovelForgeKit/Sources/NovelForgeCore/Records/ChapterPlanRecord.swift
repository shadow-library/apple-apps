import Foundation
import ShadowCore
import ShadowStore

extension ChapterPlanMark: FieldName {}
extension CanonContractMember: FieldName {}
extension CanonLearnMember: FieldName {}

enum ChapterPlanContentMember: String, CaseIterable, FieldName {
  case title
  case body
  case volume
  case contextRefs = "context_refs"
  case pov
  case endingContract = "ending_contract"
  case contract
  case chapterPurpose = "chapter_purpose"
  case readerValue = "reader_value"
  case repetitionRisks = "repetition_risks"
  case densityRisk = "density_risk"
  case guidance
  case direction
  case contentMode = "content_mode"
  case scenes
  case writeMode = "write_mode"
  case handEdited = "hand_edited"
  case inserted
}

enum EndingContractMember: String, CaseIterable, FieldName {
  case hookType = "hook_type"
  case emotionalBeat = "emotional_beat"
  case openQuestion = "open_question"
  case handoffState = "handoff_state"
  case mustNotResolve = "must_not_resolve"
}

enum PlanSceneMember: String, CaseIterable, FieldName {
  case summary
  case pov
  case goal
  case obstacle
  case turn
  case beats
  case estimatedWords = "estimated_words"
}

public struct ContractLearn: Sendable, Equatable {
  public var reveal: KnowledgeReveal
  public private(set) var unrecognised: [String: JSONValue]

  public init(_ reveal: KnowledgeReveal) {
    self.reveal = reveal
    unrecognised = [:]
  }
}

extension ContractLearn: JSONRepresentable {
  public init?(json: JSONValue) {
    guard let reader = FieldReader<CanonLearnMember>(object: json) else { return nil }
    do throws(UnreadableReason) {
      self.init(KnowledgeReveal(entityKey: try reader.required(.entity), factKey: try reader.required(.fact)))
    } catch {
      return nil
    }
    unrecognised = reader.unrecognised
  }

  public var json: JSONValue {
    var fields = RecordFields<CanonLearnMember>()
    fields.put(.entity, reveal.entityKey)
    fields.put(.fact, reveal.factKey)
    return .object(unrecognised.merging(fields.members) { _, known in known })
  }
}

// What finalize copies into the canon whole: apps/novel-forge-server/src/common/knowledge-contract.ts:7 and database/schemas/generation.ts:120-121
public struct ChapterContract: Sendable, Equatable {
  public var pov: [String]
  public var learns: [ContractLearn]
  public var claimedMilestones: [String]
  public var isEnding: Bool
  public private(set) var unrecognised: [String: JSONValue]

  public init(pov: [String] = [], learns: [ContractLearn] = [], claimedMilestones: [String] = [], isEnding: Bool = false) {
    self.pov = pov
    self.learns = learns
    self.claimedMilestones = claimedMilestones
    self.isEnding = isEnding
    unrecognised = [:]
  }

  // apps/novel-forge-server/src/common/knowledge-contract.ts:16 turns the feature off unless a POV entity is named
  public var knowledge: KnowledgeContract? {
    let named = pov.filter { !$0.isEmpty }
    guard !named.isEmpty else { return nil }
    return KnowledgeContract(pov: named, learns: reveals)
  }

  public var reveals: [KnowledgeReveal] { learns.map(\.reveal) }
}

extension ChapterContract: JSONRepresentable {
  public init?(json: JSONValue) {
    guard let reader = FieldReader<CanonContractMember>(object: json) else { return nil }
    do throws(UnreadableReason) {
      self.init(
        pov: try reader.required(.pov), learns: try reader.required(.learns), claimedMilestones: try reader.required(.claimedMilestones),
        isEnding: try reader.required(.isEnding))
    } catch {
      return nil
    }
    unrecognised = reader.unrecognised
  }

  public var json: JSONValue {
    var fields = RecordFields<CanonContractMember>()
    fields.put(.pov, pov)
    fields.put(.learns, learns)
    fields.put(.claimedMilestones, claimedMilestones)
    fields.put(.isEnding, isEnding)
    return .object(unrecognised.merging(fields.members) { _, known in known })
  }
}

// apps/novel-forge-server/src/modules/refinement/change-set/op-vocabulary.ts:46
public struct ChapterEndingContract: Sendable, Equatable {
  public var hookType: StoredEnum<HookType>
  public var emotionalBeat: String
  public var openQuestion: String
  public var handoffState: String
  public var mustNotResolve: [String]?
  public private(set) var unrecognised: [String: JSONValue]

  public init(hookType: StoredEnum<HookType>, emotionalBeat: String, openQuestion: String, handoffState: String, mustNotResolve: [String]? = nil) {
    self.hookType = hookType
    self.emotionalBeat = emotionalBeat
    self.openQuestion = openQuestion
    self.handoffState = handoffState
    self.mustNotResolve = mustNotResolve
    unrecognised = [:]
  }
}

extension ChapterEndingContract: JSONRepresentable {
  public init?(json: JSONValue) {
    guard let reader = FieldReader<EndingContractMember>(object: json) else { return nil }
    do throws(UnreadableReason) {
      self.init(
        hookType: try reader.required(.hookType), emotionalBeat: try reader.required(.emotionalBeat), openQuestion: try reader.required(.openQuestion),
        handoffState: try reader.required(.handoffState), mustNotResolve: try reader.optional(.mustNotResolve))
    } catch {
      return nil
    }
    unrecognised = reader.unrecognised
  }

  public var json: JSONValue {
    var fields = RecordFields<EndingContractMember>()
    fields.put(.hookType, hookType)
    fields.put(.emotionalBeat, emotionalBeat)
    fields.put(.openQuestion, openQuestion)
    fields.put(.handoffState, handoffState)
    fields.put(.mustNotResolve, mustNotResolve)
    return .object(unrecognised.merging(fields.members) { _, known in known })
  }
}

// apps/novel-forge-server/src/database/schemas/generation.ts:10
public struct PlanScene: Sendable, Equatable {
  public var scene: BriefScene
  public private(set) var unrecognised: [String: JSONValue]

  public init(_ scene: BriefScene) {
    self.scene = scene
    unrecognised = [:]
  }
}

extension PlanScene: JSONRepresentable {
  public init?(json: JSONValue) {
    guard let reader = FieldReader<PlanSceneMember>(object: json) else { return nil }
    do throws(UnreadableReason) {
      self.init(
        BriefScene(
          summary: try reader.required(.summary), pov: try reader.optional(.pov), goal: try reader.optional(.goal), obstacle: try reader.optional(.obstacle),
          turn: try reader.optional(.turn), beats: try reader.optional(.beats), estimatedWords: try reader.optional(.estimatedWords)))
    } catch {
      return nil
    }
    unrecognised = reader.unrecognised
  }

  public var json: JSONValue {
    var fields = RecordFields<PlanSceneMember>()
    fields.put(.summary, scene.summary)
    fields.put(.pov, scene.pov)
    fields.put(.goal, scene.goal)
    fields.put(.obstacle, scene.obstacle)
    fields.put(.turn, scene.turn)
    fields.put(.beats, scene.beats)
    fields.put(.estimatedWords, scene.estimatedWords)
    return .object(unrecognised.merging(fields.members) { _, known in known })
  }
}

// apps/novel-forge-server/src/database/schemas/generation.ts:95; revision, content hash and stale reason are derived, never stored
public struct ChapterPlanContent: RevisionBody, Sendable {
  public var title: String?
  public var body: String
  public var volume: String?
  public var contextRefs: [String]?
  public var pov: String?
  public var endingContract: ChapterEndingContract?
  public var contract: ChapterContract
  public var chapterPurpose: String?
  public var readerValue: [String]?
  public var repetitionRisks: [String]?
  public var densityRisk: String?
  public var guidance: String?
  public var direction: String?
  public var contentMode: StoredEnum<ContentMode>?
  public var scenes: [PlanScene]?
  public var writeMode: StoredEnum<BriefWriteMode>
  public var handEdited: Bool
  public var inserted: Bool
  public private(set) var unrecognised: [String: JSONValue]

  public init(
    title: String? = nil, body: String, volume: String? = nil, contextRefs: [String]? = nil, pov: String? = nil, endingContract: ChapterEndingContract? = nil,
    contract: ChapterContract = ChapterContract(), chapterPurpose: String? = nil, readerValue: [String]? = nil, repetitionRisks: [String]? = nil, densityRisk: String? = nil,
    guidance: String? = nil, direction: String? = nil, contentMode: StoredEnum<ContentMode>? = nil, scenes: [PlanScene]? = nil,
    writeMode: StoredEnum<BriefWriteMode> = .known(.standard), handEdited: Bool = false, inserted: Bool = false
  ) {
    self.title = title
    self.body = body
    self.volume = volume
    self.contextRefs = contextRefs
    self.pov = pov
    self.endingContract = endingContract
    self.contract = contract
    self.chapterPurpose = chapterPurpose
    self.readerValue = readerValue
    self.repetitionRisks = repetitionRisks
    self.densityRisk = densityRisk
    self.guidance = guidance
    self.direction = direction
    self.contentMode = contentMode
    self.scenes = scenes
    self.writeMode = writeMode
    self.handEdited = handEdited
    self.inserted = inserted
    unrecognised = [:]
  }

  public init?(json: JSONValue) {
    guard let reader = FieldReader<ChapterPlanContentMember>(object: json) else { return nil }
    do throws(UnreadableReason) {
      self.init(
        title: try reader.optional(.title), body: try reader.required(.body), volume: try reader.optional(.volume), contextRefs: try reader.optional(.contextRefs),
        pov: try reader.optional(.pov), endingContract: try reader.optional(.endingContract), contract: try reader.required(.contract),
        chapterPurpose: try reader.optional(.chapterPurpose), readerValue: try reader.optional(.readerValue), repetitionRisks: try reader.optional(.repetitionRisks),
        densityRisk: try reader.optional(.densityRisk), guidance: try reader.optional(.guidance), direction: try reader.optional(.direction),
        contentMode: try reader.optional(.contentMode), scenes: try reader.optional(.scenes), writeMode: try reader.required(.writeMode),
        handEdited: try reader.required(.handEdited), inserted: try reader.required(.inserted))
    } catch {
      return nil
    }
    unrecognised = reader.unrecognised
  }

  public var json: JSONValue {
    var fields = RecordFields<ChapterPlanContentMember>()
    fields.put(.title, title)
    fields.put(.body, body)
    fields.put(.volume, volume)
    fields.put(.contextRefs, contextRefs)
    fields.put(.pov, pov)
    fields.put(.endingContract, endingContract)
    fields.put(.contract, contract)
    fields.put(.chapterPurpose, chapterPurpose)
    fields.put(.readerValue, readerValue)
    fields.put(.repetitionRisks, repetitionRisks)
    fields.put(.densityRisk, densityRisk)
    fields.put(.guidance, guidance)
    fields.put(.direction, direction)
    fields.put(.contentMode, contentMode)
    fields.put(.scenes, scenes)
    fields.put(.writeMode, writeMode)
    fields.put(.handEdited, handEdited)
    fields.put(.inserted, inserted)
    return .object(unrecognised.merging(fields.members) { _, known in known })
  }
}

// The `finalized` mark only keeps a revision from being pruned; a chapter is final when its canon exists.
public struct ChapterPlanRecord: DocumentRecord, RemovableRecord {
  public typealias Body = ChapterPlanContent
  public typealias Mark = ChapterPlanMark

  public static let kind = NovelForgeKind.chapterPlan

  public let key: NovelForgeKey
  public let chapter: Int
  public var content: ChapterPlanContent

  public init(novel: UUID, chapter: Int, content: ChapterPlanContent) throws(NovelForgeKeyError) {
    key = try .chapterPlanKey(novel: novel, chapter: chapter)
    self.chapter = chapter
    self.content = content
  }

  public init(key: NovelForgeKey, reading reader: FieldReader<DocumentField>) throws(UnreadableReason) {
    guard case .chapterPlan(let chapter) = key.components else { throw .naturalKey(.keyMismatch(key.ref)) }
    self.key = key
    self.chapter = chapter
    content = try reader.head()
  }
}

extension ChapterPlanRecord {
  public static func ref(novel: UUID, chapter: Int) throws(NovelForgeKeyError) -> EntityRef { try NovelForgeKey.chapterPlan(novel: novel, chapter: chapter) }

  public static func revise(_ ref: EntityRef, _ content: ChapterPlanContent, marks: [ChapterPlanMark] = [], in transaction: inout WriteTransaction) throws(StoreError) -> Revised {
    try revise(ref, body: content, marks: marks, in: &transaction)
  }

  public static func mark(_ ref: EntityRef, revision: String, _ marks: [ChapterPlanMark], in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try mark(ref, revision: revision, as: marks, in: &transaction)
  }

  public static func history<Transaction: StateReading & ~Copyable>(_ ref: EntityRef, in transaction: borrowing Transaction) throws(StoreError) -> HistoryReading<
    ChapterPlanContent, ChapterPlanMark
  > {
    try history(of: ref, in: transaction)
  }
}
