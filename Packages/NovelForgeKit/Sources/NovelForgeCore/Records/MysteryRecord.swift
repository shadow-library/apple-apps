import Foundation
import ShadowCore
import ShadowStore

extension MysteryField: FieldName {}

// apps/novel-forge-server/src/database/schemas/story.ts:75,77
public struct MysteryProgress: Sendable, Equatable {
  public var state: StoredEnum<MysteryStatus>
  public var chapter: Int?

  public init(state: StoredEnum<MysteryStatus>, chapter: Int? = nil) {
    self.state = state
    self.chapter = chapter
  }
}

extension MysteryProgress: JSONRepresentable {
  public init?(json: JSONValue) {
    guard let reader = FieldReader<PromiseStatusMember>(object: json) else { return nil }
    do throws(UnreadableReason) {
      self.init(state: try reader.required(.state), chapter: try reader.optional(.chapter))
    } catch {
      return nil
    }
  }

  public var json: JSONValue {
    var fields = RecordFields<PromiseStatusMember>()
    fields.put(.state, state)
    fields.put(.chapter, chapter)
    return fields.json
  }
}

public struct MysteryRecord: RemovableRecord {
  public static let kind = NovelForgeKind.mystery

  public let key: NovelForgeKey
  public let mystery: String
  public var question: String
  public var openedChapter: Int?
  public var status: MysteryProgress
  public var truthFact: String?
  public var payoffWindow: Int?
  public var payoffMilestone: String?
  public var payoffVolume: String?
  public var dormant: Bool

  public init(
    novel: UUID, mystery: String, question: String, openedChapter: Int? = nil, status: MysteryProgress = MysteryProgress(state: .known(.open), chapter: nil),
    truthFact: String? = nil, payoffWindow: Int? = nil, payoffMilestone: String? = nil, payoffVolume: String? = nil, dormant: Bool = false
  ) {
    let mystery = mystery.precomposedStringWithCanonicalMapping
    self.mystery = mystery
    key = .mysteryKey(novel: novel, mystery: mystery)
    self.question = question
    self.openedChapter = openedChapter
    self.status = status
    self.truthFact = truthFact
    self.payoffWindow = payoffWindow
    self.payoffMilestone = payoffMilestone
    self.payoffVolume = payoffVolume
    self.dormant = dormant
  }

  public init(key: NovelForgeKey, reading reader: FieldReader<MysteryField>) throws(UnreadableReason) {
    guard case .mystery(let mystery) = key.components else { throw .naturalKey(.keyMismatch(key.ref)) }
    self.init(
      novel: key.novel, mystery: mystery, question: try reader.required(.question), openedChapter: try reader.optional(.openedChapter),
      status: try reader.required(.status), truthFact: try reader.optional(.truthFact), payoffWindow: try reader.optional(.payoffWindow),
      payoffMilestone: try reader.optional(.payoffMilestone), payoffVolume: try reader.optional(.payoffVolume), dormant: try reader.required(.dormant))
  }

  public var fields: RecordFields<MysteryField> {
    var fields = RecordFields<MysteryField>()
    fields.put(.question, question)
    fields.put(.openedChapter, openedChapter)
    fields.put(.status, status)
    fields.put(.truthFact, truthFact)
    fields.put(.payoffWindow, payoffWindow)
    fields.put(.payoffMilestone, payoffMilestone)
    fields.put(.payoffVolume, payoffVolume)
    fields.put(.dormant, dormant)
    return fields
  }
}

public struct MysteryEdit: Sendable, Equatable {
  public var question: FieldChange<String> = .keep
  public var openedChapter: FieldChange<Int?> = .keep
  public var status: FieldChange<MysteryProgress> = .keep
  public var truthFact: FieldChange<String?> = .keep
  public var payoffWindow: FieldChange<Int?> = .keep
  public var payoffMilestone: FieldChange<String?> = .keep
  public var payoffVolume: FieldChange<String?> = .keep
  public var dormant: FieldChange<Bool> = .keep

  public init() {}

  public var fields: RecordFields<MysteryField> {
    var fields = RecordFields<MysteryField>()
    fields.put(.question, question)
    fields.put(.openedChapter, openedChapter)
    fields.put(.status, status)
    fields.put(.truthFact, truthFact)
    fields.put(.payoffWindow, payoffWindow)
    fields.put(.payoffMilestone, payoffMilestone)
    fields.put(.payoffVolume, payoffVolume)
    fields.put(.dormant, dormant)
    return fields
  }
}

extension MysteryRecord {
  public static func ref(novel: UUID, mystery: String) -> EntityRef { NovelForgeKey.mystery(novel: novel, key: mystery) }

  public static func read<Transaction: StateReading & ~Copyable>(novel: UUID, mystery: String, in transaction: borrowing Transaction) throws(StoreError) -> RecordReading<
    MysteryRecord
  > {
    try read(ref(novel: novel, mystery: mystery), in: transaction)
  }

  public static func edit(novel: UUID, mystery: String, _ changes: MysteryEdit, in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try edit(ref(novel: novel, mystery: mystery), changes.fields, in: &transaction)
  }

  public static func remove(novel: UUID, mystery: String, in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try remove(ref(novel: novel, mystery: mystery), in: &transaction)
  }
}
