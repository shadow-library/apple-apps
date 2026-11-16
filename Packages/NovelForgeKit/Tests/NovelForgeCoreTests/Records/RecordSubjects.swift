import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport

@testable import NovelForgeCore

struct SubjectEdit<Record> {
  let members: Set<String>
  let apply: (inout Record) -> Void
  let perform: @Sendable (inout WriteTransaction) throws(StoreError) -> ChangeRecord

  func applied(to record: Record) -> Record {
    var copy = record
    apply(&copy)
    return copy
  }
}

protocol RecordSubject {
  associatedtype Record: NovelForgeRecord
  static var requiredMembers: Set<String> { get }
  static var groupMember: String? { get }
  static var unknownEnum: (member: String, value: JSONValue)? { get }
  static func random(_ generator: inout SeededGenerator, novel: UUID, key: String) -> Record
  static func randomEdit(_ generator: inout SeededGenerator, of record: Record) -> SubjectEdit<Record>
}

protocol RemovableSubject: RecordSubject where Record: RemovableRecord {}

enum Gen {
  static func text(_ generator: inout SeededGenerator) -> String { generator.unicodeString(maxLength: 12) }
  static func optionalText(_ generator: inout SeededGenerator) -> String? { generator.chance(0.35) ? nil : text(&generator) }
  static func int(_ generator: inout SeededGenerator) -> Int { generator.int(in: -50...5000) }
  static func optionalInt(_ generator: inout SeededGenerator) -> Int? { generator.chance(0.35) ? nil : int(&generator) }
  static func bool(_ generator: inout SeededGenerator) -> Bool { generator.chance(0.5) }

  static func stored<Value: RawRepresentable & CaseIterable & Hashable & Sendable>(_ generator: inout SeededGenerator) -> StoredEnum<Value> where Value.RawValue == String {
    guard !generator.chance(0.2) else { return .unknown("x_" + generator.asciiString(maxLength: 6)) }
    return .known(generator.pick(from: Array(Value.allCases)))
  }

  static func themes(_ generator: inout SeededGenerator) -> [String]? {
    guard !generator.chance(0.35) else { return nil }
    return (0..<generator.int(in: 0...3)).map { _ in text(&generator) }
  }

  static func wordTarget(_ generator: inout SeededGenerator) -> WordTarget? {
    guard !generator.chance(0.35) else { return nil }
    let low = generator.int(in: 0...5000)
    return WordTarget(min: low, max: low + generator.int(in: 1...5000))
  }

  static func threadProgress(_ generator: inout SeededGenerator) -> ThreadProgress {
    ThreadProgress(state: stored(&generator), chapter: optionalInt(&generator))
  }

  static func mysteryProgress(_ generator: inout SeededGenerator) -> MysteryProgress {
    MysteryProgress(state: stored(&generator), chapter: optionalInt(&generator))
  }

  static func key(_ generator: inout SeededGenerator) -> String { generator.unicodeString(maxLength: 8) }
}

extension SeededGenerator {
  mutating func uuid() -> UUID {
    let hex = Array(String(format: "%016llx%016llx", next(), next()))
    let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(hex[$0]) }
    return UUID(uuidString: parts.joined(separator: "-")) ?? UUID()
  }
}

struct EditDraft<Edit: Sendable, Record> {
  var edit: Edit
  private(set) var members: Set<String> = []
  private var appliers: [(inout Record) -> Void] = []

  init(_ edit: Edit) {
    self.edit = edit
  }

  mutating func maybe<Value: JSONWritable & Equatable>(
    _ generator: inout SeededGenerator, _ name: String, edit editPath: WritableKeyPath<Edit, FieldChange<Value>>, record recordPath: WritableKeyPath<Record, Value>,
    _ make: (inout SeededGenerator) -> Value
  ) {
    guard generator.chance(0.45) else { return }
    let value = make(&generator)
    edit[keyPath: editPath] = .set(value)
    appliers.append { $0[keyPath: recordPath] = value }
    members.insert(name)
  }

  func subject(perform: @escaping @Sendable (Edit, inout WriteTransaction) throws(StoreError) -> ChangeRecord) -> SubjectEdit<Record> {
    let (edit, appliers) = (edit, appliers)
    return SubjectEdit(
      members: members, apply: { record in for applier in appliers { applier(&record) } }, perform: { transaction throws(StoreError) in try perform(edit, &transaction) })
  }
}

struct VolumeSubject: RemovableSubject {
  static let requiredMembers: Set<String> = ["natural_key", "removed", "ordinal", "goal_met"]
  static let groupMember: String? = nil
  static let unknownEnum: (member: String, value: JSONValue)? = nil

  static func random(_ generator: inout SeededGenerator, novel: UUID, key: String) -> VolumeRecord {
    VolumeRecord(
      novel: novel, volume: key, ordinal: Gen.int(&generator), title: Gen.optionalText(&generator), objective: Gen.optionalText(&generator),
      body: Gen.optionalText(&generator), goalMet: Gen.bool(&generator))
  }

  static func randomEdit(_ generator: inout SeededGenerator, of record: VolumeRecord) -> SubjectEdit<VolumeRecord> {
    var draft = EditDraft<VolumeEdit, VolumeRecord>(VolumeEdit())
    repeat {
      draft = EditDraft(VolumeEdit())
      draft.maybe(&generator, "ordinal", edit: \.ordinal, record: \.ordinal, Gen.int)
      draft.maybe(&generator, "title", edit: \.title, record: \.title, Gen.optionalText)
      draft.maybe(&generator, "objective", edit: \.objective, record: \.objective, Gen.optionalText)
      draft.maybe(&generator, "body", edit: \.body, record: \.body, Gen.optionalText)
      draft.maybe(&generator, "goal_met", edit: \.goalMet, record: \.goalMet, Gen.bool)
    } while draft.members.isEmpty
    let (novel, volume) = (record.novel, record.volume)
    return draft.subject { edit, transaction throws(StoreError) in try VolumeRecord.edit(novel: novel, volume: volume, edit, in: &transaction) }
  }
}

struct MilestoneSubject: RemovableSubject {
  static let requiredMembers: Set<String> = ["natural_key", "removed", "label", "kind"]
  static let groupMember: String? = nil
  static let unknownEnum: (member: String, value: JSONValue)? = ("kind", "x_future_kind")

  static func random(_ generator: inout SeededGenerator, novel: UUID, key: String) -> MilestoneRecord {
    MilestoneRecord(novel: novel, milestone: key, label: Gen.text(&generator), subject: Gen.optionalText(&generator), kind: Gen.stored(&generator))
  }

  static func randomEdit(_ generator: inout SeededGenerator, of record: MilestoneRecord) -> SubjectEdit<MilestoneRecord> {
    var draft = EditDraft<MilestoneEdit, MilestoneRecord>(MilestoneEdit())
    repeat {
      draft = EditDraft(MilestoneEdit())
      draft.maybe(&generator, "label", edit: \.label, record: \.label, Gen.text)
      draft.maybe(&generator, "subject", edit: \.subject, record: \.subject, Gen.optionalText)
      draft.maybe(&generator, "kind", edit: \.kind, record: \.kind, Gen.stored)
    } while draft.members.isEmpty
    let (novel, milestone) = (record.novel, record.milestone)
    return draft.subject { edit, transaction throws(StoreError) in try MilestoneRecord.edit(novel: novel, milestone: milestone, edit, in: &transaction) }
  }
}

struct ThreadSubject: RemovableSubject {
  static let requiredMembers: Set<String> = ["natural_key", "removed", "status", "dormant"]
  static let groupMember: String? = "status"
  static let unknownEnum: (member: String, value: JSONValue)? = ("status", ["state": "x_paused", "chapter": 4])

  static func random(_ generator: inout SeededGenerator, novel: UUID, key: String) -> ThreadRecord {
    ThreadRecord(
      novel: novel, thread: key, summary: Gen.optionalText(&generator), openedChapter: Gen.optionalInt(&generator), status: Gen.threadProgress(&generator),
      payoffWindow: Gen.optionalInt(&generator), payoffMilestone: Gen.optionalText(&generator), payoffVolume: Gen.optionalText(&generator), dormant: Gen.bool(&generator))
  }

  static func randomEdit(_ generator: inout SeededGenerator, of record: ThreadRecord) -> SubjectEdit<ThreadRecord> {
    var draft = EditDraft<ThreadEdit, ThreadRecord>(ThreadEdit())
    repeat {
      draft = EditDraft(ThreadEdit())
      draft.maybe(&generator, "summary", edit: \.summary, record: \.summary, Gen.optionalText)
      draft.maybe(&generator, "opened_chapter", edit: \.openedChapter, record: \.openedChapter, Gen.optionalInt)
      draft.maybe(&generator, "status", edit: \.status, record: \.status, Gen.threadProgress)
      draft.maybe(&generator, "payoff_window", edit: \.payoffWindow, record: \.payoffWindow, Gen.optionalInt)
      draft.maybe(&generator, "payoff_milestone", edit: \.payoffMilestone, record: \.payoffMilestone, Gen.optionalText)
      draft.maybe(&generator, "payoff_volume", edit: \.payoffVolume, record: \.payoffVolume, Gen.optionalText)
      draft.maybe(&generator, "dormant", edit: \.dormant, record: \.dormant, Gen.bool)
    } while draft.members.isEmpty
    let (novel, thread) = (record.novel, record.thread)
    return draft.subject { edit, transaction throws(StoreError) in try ThreadRecord.edit(novel: novel, thread: thread, edit, in: &transaction) }
  }
}

struct MysterySubject: RemovableSubject {
  static let requiredMembers: Set<String> = ["natural_key", "removed", "question", "status", "dormant"]
  static let groupMember: String? = "status"
  static let unknownEnum: (member: String, value: JSONValue)? = ("status", ["state": "x_unsolvable", "chapter": nil])

  static func random(_ generator: inout SeededGenerator, novel: UUID, key: String) -> MysteryRecord {
    MysteryRecord(
      novel: novel, mystery: key, question: Gen.text(&generator), openedChapter: Gen.optionalInt(&generator), status: Gen.mysteryProgress(&generator),
      truthFact: Gen.optionalText(&generator), payoffWindow: Gen.optionalInt(&generator), payoffMilestone: Gen.optionalText(&generator),
      payoffVolume: Gen.optionalText(&generator), dormant: Gen.bool(&generator))
  }

  static func randomEdit(_ generator: inout SeededGenerator, of record: MysteryRecord) -> SubjectEdit<MysteryRecord> {
    var draft = EditDraft<MysteryEdit, MysteryRecord>(MysteryEdit())
    repeat {
      draft = EditDraft(MysteryEdit())
      draft.maybe(&generator, "question", edit: \.question, record: \.question, Gen.text)
      draft.maybe(&generator, "opened_chapter", edit: \.openedChapter, record: \.openedChapter, Gen.optionalInt)
      draft.maybe(&generator, "status", edit: \.status, record: \.status, Gen.mysteryProgress)
      draft.maybe(&generator, "truth_fact", edit: \.truthFact, record: \.truthFact, Gen.optionalText)
      draft.maybe(&generator, "payoff_window", edit: \.payoffWindow, record: \.payoffWindow, Gen.optionalInt)
      draft.maybe(&generator, "payoff_milestone", edit: \.payoffMilestone, record: \.payoffMilestone, Gen.optionalText)
      draft.maybe(&generator, "payoff_volume", edit: \.payoffVolume, record: \.payoffVolume, Gen.optionalText)
      draft.maybe(&generator, "dormant", edit: \.dormant, record: \.dormant, Gen.bool)
    } while draft.members.isEmpty
    let (novel, mystery) = (record.novel, record.mystery)
    return draft.subject { edit, transaction throws(StoreError) in try MysteryRecord.edit(novel: novel, mystery: mystery, edit, in: &transaction) }
  }
}

struct NovelSubject: RecordSubject {
  static let requiredMembers: Set<String> = ["name", "content_mode", "cost_tier", "archived"]
  static let groupMember: String? = "word_target"
  static let unknownEnum: (member: String, value: JSONValue)? = ("cost_tier", "x_platinum")

  static func random(_ generator: inout SeededGenerator, novel: UUID, key: String) -> NovelRecord {
    NovelRecord(
      id: novel, name: Gen.text(&generator), title: Gen.optionalText(&generator), contentMode: Gen.stored(&generator), costTier: Gen.stored(&generator),
      wordTarget: Gen.wordTarget(&generator), brief: Gen.optionalText(&generator), premise: Gen.optionalText(&generator), themes: Gen.themes(&generator),
      theme: Gen.optionalText(&generator), endingQuestion: Gen.optionalText(&generator), ending: Gen.optionalText(&generator),
      readerPromise: Gen.optionalText(&generator), protagonist: Gen.optionalText(&generator), opposition: Gen.optionalText(&generator),
      writingStyle: Gen.optionalText(&generator), archived: Gen.bool(&generator))
  }

  static func randomEdit(_ generator: inout SeededGenerator, of record: NovelRecord) -> SubjectEdit<NovelRecord> {
    var draft = EditDraft<NovelEdit, NovelRecord>(NovelEdit())
    repeat {
      draft = EditDraft(NovelEdit())
      draft.maybe(&generator, "name", edit: \.name, record: \.name, Gen.text)
      draft.maybe(&generator, "title", edit: \.title, record: \.title, Gen.optionalText)
      draft.maybe(&generator, "content_mode", edit: \.contentMode, record: \.contentMode, Gen.stored)
      draft.maybe(&generator, "cost_tier", edit: \.costTier, record: \.costTier, Gen.stored)
      draft.maybe(&generator, "word_target", edit: \.wordTarget, record: \.wordTarget, Gen.wordTarget)
      draft.maybe(&generator, "brief", edit: \.brief, record: \.brief, Gen.optionalText)
      draft.maybe(&generator, "premise", edit: \.premise, record: \.premise, Gen.optionalText)
      draft.maybe(&generator, "themes", edit: \.themes, record: \.themes, Gen.themes)
      draft.maybe(&generator, "theme", edit: \.theme, record: \.theme, Gen.optionalText)
      draft.maybe(&generator, "ending_question", edit: \.endingQuestion, record: \.endingQuestion, Gen.optionalText)
      draft.maybe(&generator, "ending", edit: \.ending, record: \.ending, Gen.optionalText)
      draft.maybe(&generator, "reader_promise", edit: \.readerPromise, record: \.readerPromise, Gen.optionalText)
      draft.maybe(&generator, "protagonist", edit: \.protagonist, record: \.protagonist, Gen.optionalText)
      draft.maybe(&generator, "opposition", edit: \.opposition, record: \.opposition, Gen.optionalText)
      draft.maybe(&generator, "writing_style", edit: \.writingStyle, record: \.writingStyle, Gen.optionalText)
      draft.maybe(&generator, "archived", edit: \.archived, record: \.archived, Gen.bool)
    } while draft.members.isEmpty
    let id = record.id
    return draft.subject { edit, transaction throws(StoreError) in try NovelRecord.edit(id: id, edit, in: &transaction) }
  }
}
