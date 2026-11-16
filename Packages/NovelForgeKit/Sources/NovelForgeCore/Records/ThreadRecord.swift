import Foundation
import ShadowCore
import ShadowStore

extension ThreadField: FieldName {}
extension PromiseStatusMember: FieldName {}

// apps/novel-forge-server/src/database/schemas/story.ts:25,27
public struct ThreadProgress: Sendable, Equatable {
  public var state: StoredEnum<ThreadStatus>
  public var chapter: Int?

  public init(state: StoredEnum<ThreadStatus>, chapter: Int? = nil) {
    self.state = state
    self.chapter = chapter
  }
}

extension ThreadProgress: JSONRepresentable {
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

public struct ThreadRecord: RemovableRecord {
  public static let kind = NovelForgeKind.thread

  public let key: NovelForgeKey
  public let thread: String
  public var summary: String?
  public var openedChapter: Int?
  public var status: ThreadProgress
  public var payoffWindow: Int?
  public var payoffMilestone: String?
  public var payoffVolume: String?
  public var dormant: Bool

  public init(
    novel: UUID, thread: String, summary: String? = nil, openedChapter: Int? = nil, status: ThreadProgress = ThreadProgress(state: .known(.open), chapter: nil),
    payoffWindow: Int? = nil, payoffMilestone: String? = nil, payoffVolume: String? = nil, dormant: Bool = false
  ) {
    let thread = thread.precomposedStringWithCanonicalMapping
    self.thread = thread
    key = .threadKey(novel: novel, thread: thread)
    self.summary = summary
    self.openedChapter = openedChapter
    self.status = status
    self.payoffWindow = payoffWindow
    self.payoffMilestone = payoffMilestone
    self.payoffVolume = payoffVolume
    self.dormant = dormant
  }

  public init(key: NovelForgeKey, reading reader: FieldReader<ThreadField>) throws(UnreadableReason) {
    guard case .thread(let thread) = key.components else { throw .naturalKey(.keyMismatch(key.ref)) }
    self.init(
      novel: key.novel, thread: thread, summary: try reader.optional(.summary), openedChapter: try reader.optional(.openedChapter), status: try reader.required(.status),
      payoffWindow: try reader.optional(.payoffWindow), payoffMilestone: try reader.optional(.payoffMilestone), payoffVolume: try reader.optional(.payoffVolume),
      dormant: try reader.required(.dormant))
  }

  public var fields: RecordFields<ThreadField> {
    var fields = RecordFields<ThreadField>()
    fields.put(.summary, summary)
    fields.put(.openedChapter, openedChapter)
    fields.put(.status, status)
    fields.put(.payoffWindow, payoffWindow)
    fields.put(.payoffMilestone, payoffMilestone)
    fields.put(.payoffVolume, payoffVolume)
    fields.put(.dormant, dormant)
    return fields
  }
}

public struct ThreadEdit: Sendable, Equatable {
  public var summary: FieldChange<String?> = .keep
  public var openedChapter: FieldChange<Int?> = .keep
  public var status: FieldChange<ThreadProgress> = .keep
  public var payoffWindow: FieldChange<Int?> = .keep
  public var payoffMilestone: FieldChange<String?> = .keep
  public var payoffVolume: FieldChange<String?> = .keep
  public var dormant: FieldChange<Bool> = .keep

  public init() {}

  public var fields: RecordFields<ThreadField> {
    var fields = RecordFields<ThreadField>()
    fields.put(.summary, summary)
    fields.put(.openedChapter, openedChapter)
    fields.put(.status, status)
    fields.put(.payoffWindow, payoffWindow)
    fields.put(.payoffMilestone, payoffMilestone)
    fields.put(.payoffVolume, payoffVolume)
    fields.put(.dormant, dormant)
    return fields
  }
}

extension ThreadRecord {
  public static func ref(novel: UUID, thread: String) -> EntityRef { NovelForgeKey.thread(novel: novel, key: thread) }

  public static func read<Transaction: StateReading & ~Copyable>(novel: UUID, thread: String, in transaction: borrowing Transaction) throws(StoreError) -> RecordReading<
    ThreadRecord
  > {
    try read(ref(novel: novel, thread: thread), in: transaction)
  }

  public static func edit(novel: UUID, thread: String, _ changes: ThreadEdit, in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try edit(ref(novel: novel, thread: thread), changes.fields, in: &transaction)
  }

  public static func remove(novel: UUID, thread: String, in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try remove(ref(novel: novel, thread: thread), in: &transaction)
  }
}
