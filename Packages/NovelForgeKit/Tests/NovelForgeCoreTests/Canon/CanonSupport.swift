import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowText

@testable import NovelForgeCore

enum Kept {
  static func entity(_ key: String, name: String? = nil) -> ProposedChange {
    .entity(ProposedChange.Entity(entityKey: key, name: name ?? key.capitalized, type: .character, notes: nil))
  }

  static func appearance(_ key: String) -> ProposedChange { .appearance(entityKey: key) }

  static func state(_ key: String, location: String? = nil, conditions: [String]? = nil, goal: String? = nil, note: String? = nil) -> ProposedChange {
    .characterState(
      ProposedChange.CharacterState(entityKey: key, location: location, conditions: conditions, immediateGoal: goal, statusNote: note, evidence: "It is written."))
  }

  static func relationship(_ key: String, _ target: String, _ kind: String, note: String? = nil) -> ProposedChange {
    .relationship(ProposedChange.Relationship(entityKey: key, targetKey: target, kind: kind, note: note, evidence: "It is written."))
  }

  static func thread(_ key: String, _ status: ThreadStatus, summary: String? = nil, open: Bool? = nil) -> ProposedChange {
    .thread(ProposedChange.PlotThread(threadKey: key, status: status, summary: summary, intentionallyOpen: open))
  }

  static func mystery(_ key: String, _ status: MysteryStatus, question: String? = nil, open: Bool? = nil, truth: String? = nil) -> ProposedChange {
    .mystery(ProposedChange.Mystery(mysteryKey: key, status: status, question: question, intentionallyOpen: open, truthFactKey: truth))
  }

  static func knowledge(_ entity: String, _ fact: String) -> ProposedChange {
    .knowledge(ProposedChange.Knowledge(entityKey: entity, factKey: fact, how: "She overhears it."))
  }

  static func milestone(_ key: String, reached: Bool = true) -> ProposedChange {
    .milestone(ProposedChange.Milestone(milestoneKey: key, reached: reached))
  }
}

func stamp(_ millis: Int64) throws -> HLCTimestamp {
  guard let stamp = HLCTimestamp(wallMillis: millis, counter: 0, replica: ReplicaID(SchemaFixture.novel)) else { throw SchemaFixtureError(description: "a valid clock") }
  return stamp
}

func review(_ kept: [ProposedChange], unreached: [String] = [], id: UUID = UUID()) -> CanonReview {
  CanonReview(id: id, kept: kept.compactMap(\.json.objectValue), unreached: unreached)
}

enum CanonWrites {
  /// A canon as the reviewed commit writes it: the plan's contract, the review it applied and, when given, the knowledge it committed.
  static func finalize(
    novel: UUID, chapter: Int, review: CanonReview?, knowledge: [KnowledgeReveal]? = nil, contract: ChapterContract = ChapterContract(), approval: UUID? = nil,
    in transaction: inout WriteTransaction
  ) throws {
    let canon = Canon(
      draftRevision: "v:draft", planRevision: "v:plan", approval: approval, body: "Final \(chapter).", contract: contract, disclosed: [], review: review, knowledge: knowledge)
    _ = try FinalChapterRecord(novel: novel, chapter: chapter, canon: canon).finalize(in: &transaction)
  }

  /// A canon whose `member` holds a value this version cannot read.
  static func finalize(
    novel: UUID, chapter: Int, unreadable member: FinalChapterCanonMember, terms: ChapterContract = contract(claims: ["rise"]), in transaction: inout WriteTransaction
  ) throws {
    let record = try FinalChapterRecord(novel: novel, chapter: chapter, canon: Canon(body: "Final \(chapter).", contract: terms))
    guard case .object(var canon) = record.canon.json else { throw SchemaFixtureError(description: "a canon encodes to an object") }
    canon[member.rawValue] = .string("from a newer version")
    _ = try transaction.set(record.ref, [CommonField.naturalKey.rawValue: record.key.stored, FinalChapterField.canon.rawValue: .object(canon)])
  }

  static func entity(novel: UUID, _ key: String, in transaction: inout WriteTransaction) throws {
    try ChapterWrites.entity(novel: novel, key, in: &transaction)
  }

  static func removeEntity(novel: UUID, _ key: String, in transaction: inout WriteTransaction) throws {
    guard case .readable(let entry) = try EntityRecord.read(EntityRecord.ref(novel: novel, entity: key), in: transaction), !entry.isRemoved else { return }
    _ = try EntityRecord.remove(novel: novel, entity: key, in: &transaction)
  }
}

struct StateView: Hashable, CustomStringConvertible {
  let entity: String
  let location: String?
  let conditions: [String]?
  let goal: String?
  let note: String?
  let chapter: Int

  init(_ entity: String, location: String? = nil, conditions: [String]? = nil, goal: String? = nil, note: String? = nil, chapter: Int) {
    self.entity = entity
    self.location = location
    self.conditions = conditions
    self.goal = goal
    self.note = note
    self.chapter = chapter
  }

  init(_ entry: CharacterStateEntry) throws {
    self.init(
      entry.entity, location: entry.location, conditions: try entry.conditionList(), goal: entry.immediateGoal, note: entry.statusNote, chapter: entry.chapter)
  }

  var description: String { "\(entity)@\(chapter) \(location ?? "-") \(conditions ?? []) \(goal ?? "-") \(note ?? "-")" }
}

struct EventView: Hashable, CustomStringConvertible {
  let entity: String
  let chapter: Int
  let kind: CharacterEventKind
  let detail: String
  let before: JSONValue?
  let after: JSONValue?

  init(_ entity: String, _ chapter: Int, _ kind: CharacterEventKind, detail: String = "", before: JSONValue?, after: JSONValue?) {
    self.entity = entity
    self.chapter = chapter
    self.kind = kind
    self.detail = detail
    self.before = before
    self.after = after
  }

  init(_ entry: CharacterEventEntry) throws {
    self.init(
      entry.entity, entry.chapter, entry.kind, detail: entry.detail, before: try entry.before.map(CanonJSON.value), after: try entry.after.map(CanonJSON.value))
  }

  var description: String { "\(entity)@\(chapter) \(kind.rawValue) \(detail) \(before.map { "\($0)" } ?? "null") -> \(after.map { "\($0)" } ?? "null")" }
}

struct PromiseView: Hashable, CustomStringConvertible {
  let key: String
  let status: String
  let opened: Int?
  let closed: Int?
  let text: String?
  let open: Bool
  let truth: String?
  let advanced: Int?

  init(_ key: String, _ status: String, opened: Int? = nil, closed: Int? = nil, text: String? = nil, open: Bool = false, truth: String? = nil, advanced: Int? = nil) {
    self.key = key
    self.status = status
    self.opened = opened
    self.closed = closed
    self.text = text
    self.open = open
    self.truth = truth
    self.advanced = advanced
  }

  init(_ entry: PromiseStateEntry) {
    self.init(
      entry.key, entry.status, opened: entry.openedChapter, closed: entry.closedChapter, text: entry.text, open: entry.intentionallyOpen, truth: entry.truthFact,
      advanced: entry.lastAdvancedChapter)
  }

  var description: String {
    "\(key) \(status) opened=\(opened.map(String.init) ?? "-") closed=\(closed.map(String.init) ?? "-") \(text ?? "-") open=\(open) \(truth ?? "-") advanced=\(advanced.map(String.init) ?? "-")"
  }
}

func stateJSON(location: String? = nil, conditions: [String]? = nil, goal: String? = nil, note: String? = nil) -> JSONValue {
  let text = { (value: String?) in value.map(JSONValue.string) ?? .null }
  return .object([
    "location": text(location), "conditions": conditions.map { .array($0.map(JSONValue.string)) } ?? .null, "immediateGoal": text(goal), "statusNote": text(note),
  ])
}

func edgeJSON(_ target: String, _ kind: String, note: String?) -> JSONValue {
  .object(["targetKey": .string(target), "kind": .string(kind), "note": note.map(JSONValue.string) ?? .null])
}

enum CanonTables {
  static func appearances(_ novel: UUID, in store: VaultStore) async throws -> Set<String> {
    Set(try await Projection.fetch(CanonAppearanceDerivation.request(for: novel), in: store).map { "\($0.entity)@\($0.chapter)" })
  }

  static func states(_ novel: UUID, in store: VaultStore) async throws -> Set<StateView> {
    Set(try await Projection.fetch(CharacterStateDerivation.request(for: novel), in: store).map(StateView.init))
  }

  static func relationships(_ novel: UUID, in store: VaultStore) async throws -> Set<String> {
    Set(try await Projection.fetch(CanonRelationshipDerivation.request(for: novel), in: store).map { "\($0.entity)→\($0.target):\($0.kind)@\($0.chapter) \($0.note ?? "-")" })
  }

  static func events(_ novel: UUID, in store: VaultStore) async throws -> Set<EventView> {
    Set(try await Projection.fetch(CharacterEventDerivation.request(for: novel), in: store).map(EventView.init))
  }

  static func promises(_ novel: UUID, in store: VaultStore) async throws -> [String: PromiseView] {
    let entries = try await Projection.fetch(PromiseStateDerivation.request(for: novel), in: store)
    return Dictionary(uniqueKeysWithValues: entries.map { ("\($0.promise.rawValue):\($0.key)", PromiseView($0)) })
  }
}
