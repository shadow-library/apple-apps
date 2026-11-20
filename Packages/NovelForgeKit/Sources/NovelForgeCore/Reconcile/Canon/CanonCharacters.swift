import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowText

// apps/novel-forge-server/src/database/schemas/knowledge.ts (character_events.kind)
public enum CharacterEventKind: String, Codable, CaseIterable, Sendable {
  case appearance
  case state
  case relationship
}

public struct CanonAppearanceEntry: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nf_derived_canon_appearance"

  public let novel: UUID
  public let entity: String
  public let chapter: Int
}

/// An entity's latest reported state; `conditions` is the list as JSON text, read through `conditionList()`.
public struct CharacterStateEntry: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nf_derived_character_state"

  public let novel: UUID
  public let entity: String
  public let location: String?
  let conditions: String?
  public let immediateGoal: String?
  public let statusNote: String?
  public let chapter: Int

  enum CodingKeys: String, CodingKey {
    case novel
    case entity
    case location
    case conditions
    case immediateGoal = "immediate_goal"
    case statusNote = "status_note"
    case chapter
  }

  public func conditionList() throws(StoreError) -> [String]? {
    try conditions.map { text throws(StoreError) in try CanonJSON.value(text).arrayValue?.compactMap(\.stringValue) ?? [] }
  }
}

/// One chapter's observation of a relationship; the latest chapter's note is the relationship's standing.
public struct CanonRelationshipEntry: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nf_derived_canon_relationship"

  public let novel: UUID
  public let entity: String
  public let target: String
  public let kind: String
  public let chapter: Int
  public let note: String?
}

/// `before` and `after` are the reference's jsonb payloads as canonical JSON text, nil where it stores null.
public struct CharacterEventEntry: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nf_derived_character_event"

  public let novel: UUID
  public let entity: String
  public let chapter: Int
  public let kind: CharacterEventKind
  public let detail: String
  public let before: String?
  public let after: String?
}

private struct RelationshipKey: Hashable {
  let entity: JSString
  let target: JSString
  let kind: JSString
}

private struct EventKey: Hashable {
  let entity: JSString
  let chapter: Int
  let kind: CharacterEventKind
  let detail: JSString
}

private func nfc(_ key: String) -> String { key.jsNormalize(.nfc) }

private func text(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }

/// The appearances, character states, relationships and character events the novel's winning canons keep, replayed in chapter order as
/// apps/novel-forge-server/src/modules/finalize-review/review-event-apply.ts:190-201 applies each kept change through applyContinuityDelta
/// (apps/novel-forge-server/src/modules/ai/graphs/apply-continuity.ts:72-354).
/// An entity counts for a chapter only when it is live now and its `CanonBinding.liveSince` is at or before that canon's clock.
struct CanonCharacters: Equatable {
  var appearances: [CanonAppearanceEntry] = []
  var states: [CharacterStateEntry] = []
  var relationships: [CanonRelationshipEntry] = []
  var events: [CharacterEventEntry] = []

  static var inputs: [DerivationInput<UUID>] {
    [
      .outputs(of: CanonBindingDerivation.self) { [$0.novel] },
      .outputs(of: RecordIndexDerivation.self) { row in row.kind == .entity ? row.novel.map { [$0] } ?? [] : [] },
    ]
  }

  static func novels(in context: DerivationContext) throws(StoreError) -> Set<UUID> {
    Set(try context.fetchAll(CanonBindingEntry.all()).map(\.novel))
  }

  static func load(novel: UUID, in context: DerivationContext) throws(StoreError) -> CanonCharacters {
    let bindings = try CanonBinding.all(of: novel, in: context)
    var named = Set<JSString>()
    for change in bindings.flatMap(\.kept) { named.formUnion(entityKeys(of: change).map { JSString(nfc($0)) }) }
    let keptAsNew = CanonBinding.keptAsNew(in: bindings)
    var liveSince = [JSString: HLCTimestamp]()
    for key in named {
      let ref = EntityRecord.ref(novel: novel, entity: key.value)
      let state = try context.records.state(of: ref, scope: .vault)
      guard case .readable(let entry) = EntityRecord.reading(state, of: ref), !entry.isRemoved,
        let since = CanonBinding.liveSince(key.value, record: state?.liveSince, keptAsNew: keptAsNew)
      else { continue }
      liveSince[key] = since
    }
    return replay(novel: novel, bindings: bindings, liveSince: liveSince)
  }

  private static func entityKeys(of change: ProposedChange) -> [String] {
    switch change {
    case .entity(let entity): [entity.entityKey]
    case .appearance(let entityKey): [entityKey]
    case .characterState(let state): [state.entityKey]
    case .relationship(let relationship): [relationship.entityKey, relationship.targetKey]
    case .thread, .mystery, .knowledge, .milestone, .summary: []
    }
  }

  static func replay(novel: UUID, bindings: [CanonBinding], liveSince: [JSString: HLCTimestamp]) -> CanonCharacters {
    var replay = Replay(novel: novel, liveSince: liveSince)
    for binding in bindings {
      for change in binding.kept { replay.apply(change, chapter: binding.chapter, clock: binding.clock) }
    }
    return replay.result
  }

  private struct Replay {
    let novel: UUID
    let liveSince: [JSString: HLCTimestamp]
    var states: [JSString: ReportedState] = [:]
    var relationships: [CanonRelationshipEntry] = []
    var relationshipRows: [RelationshipKey: [Int]] = [:]
    var events: [CharacterEventEntry] = []
    var eventRows: [EventKey: Int] = [:]
    var appearances: [CanonAppearanceEntry] = []

    var result: CanonCharacters {
      CanonCharacters(
        appearances: appearances, states: states.keys.sorted().compactMap { states[$0]?.entry(novel: novel) }, relationships: relationships, events: events)
    }

    func resolves(_ key: String, at clock: HLCTimestamp) -> Bool {
      liveSince[JSString(key)].map { $0 <= clock } ?? false
    }

    mutating func apply(_ change: ProposedChange, chapter: Int, clock: HLCTimestamp) {
      switch change {
      case .entity(let entity): appear(nfc(entity.entityKey), chapter: chapter, clock: clock)
      case .appearance(let entityKey): appear(nfc(entityKey), chapter: chapter, clock: clock)
      case .characterState(let state): report(state, chapter: chapter, clock: clock)
      case .relationship(let relationship): relate(relationship, chapter: chapter, clock: clock)
      case .thread, .mystery, .knowledge, .milestone, .summary: break
      }
    }

    // apply-continuity.ts:105-122: an appearance row is inserted once per chapter, and only an inserted one records an event
    private mutating func appear(_ entity: String, chapter: Int, clock: HLCTimestamp) {
      guard resolves(entity, at: clock) else { return }
      let key = EventKey(entity: JSString(entity), chapter: chapter, kind: .appearance, detail: JSString(""))
      guard eventRows[key] == nil else { return }
      appearances.append(CanonAppearanceEntry(novel: novel, entity: entity, chapter: chapter))
      record(key, entity: entity, before: nil, after: nil)
    }

    // apply-continuity.ts:286-353: a reported state replaces the whole snapshot, an omitted field becoming null
    private mutating func report(_ state: ProposedChange.CharacterState, chapter: Int, clock: HLCTimestamp) {
      let entity = nfc(state.entityKey)
      guard resolves(entity, at: clock) else { return }
      let slot = JSString(entity)
      let reported = ReportedState(entity: entity, state: state, chapter: chapter)
      let before = states[slot]?.snapshot
      states[slot] = reported
      record(EventKey(entity: slot, chapter: chapter, kind: .state, detail: JSString("")), entity: entity, before: before, after: reported.snapshot)
    }

    // apply-continuity.ts:224-284: both ends must resolve; `before` is the newest earlier chapter's note, a second report in the same chapter keeps a note it omits
    private mutating func relate(_ relationship: ProposedChange.Relationship, chapter: Int, clock: HLCTimestamp) {
      let (entity, target, kind) = (nfc(relationship.entityKey), nfc(relationship.targetKey), nfc(relationship.kind))
      guard resolves(entity, at: clock), resolves(target, at: clock) else { return }
      let key = RelationshipKey(entity: JSString(entity), target: JSString(target), kind: JSString(kind))
      let rows = relationshipRows[key] ?? []
      let earlier = rows.last { relationships[$0].chapter < chapter }.map { relationships[$0] }
      let saved: CanonRelationshipEntry
      if let index = rows.first(where: { relationships[$0].chapter == chapter }) {
        saved = CanonRelationshipEntry(
          novel: novel, entity: entity, target: target, kind: kind, chapter: chapter, note: relationship.note ?? relationships[index].note)
        relationships[index] = saved
      } else {
        saved = CanonRelationshipEntry(novel: novel, entity: entity, target: target, kind: kind, chapter: chapter, note: relationship.note)
        relationshipRows[key, default: []].append(relationships.count)
        relationships.append(saved)
      }
      let edge = { (note: String?) in JSONValue.object(["targetKey": .string(target), "kind": .string(kind), "note": text(note)]) }
      record(
        EventKey(entity: JSString(entity), chapter: chapter, kind: .relationship, detail: JSString("\(target):\(kind)")), entity: entity,
        before: earlier.map { edge($0.note) }, after: edge(saved.note))
    }

    // apply-continuity.ts:51-70: a second event for the same (entity, chapter, kind, detail) refreshes `after` and keeps the `before` written first
    private mutating func record(_ key: EventKey, entity: String, before: JSONValue?, after: JSONValue?) {
      if let index = eventRows[key] {
        let first = events[index]
        events[index] = CharacterEventEntry(
          novel: novel, entity: entity, chapter: first.chapter, kind: first.kind, detail: first.detail, before: first.before, after: after.map(CanonJSON.text))
        return
      }
      eventRows[key] = events.count
      events.append(
        CharacterEventEntry(
          novel: novel, entity: entity, chapter: key.chapter, kind: key.kind, detail: key.detail.value, before: before.map(CanonJSON.text), after: after.map(CanonJSON.text)))
    }

  }

  private struct ReportedState {
    let entity: String
    let state: ProposedChange.CharacterState
    let chapter: Int

    var conditions: JSONValue? { state.conditions.map { .array($0.map(JSONValue.string)) } }

    var snapshot: JSONValue {
      .object([
        "location": text(state.location), "conditions": conditions ?? .null, "immediateGoal": text(state.immediateGoal), "statusNote": text(state.statusNote),
      ])
    }

    func entry(novel: UUID) -> CharacterStateEntry {
      CharacterStateEntry(
        novel: novel, entity: entity, location: state.location, conditions: conditions.map(CanonJSON.text), immediateGoal: state.immediateGoal,
        statusNote: state.statusNote, chapter: chapter)
    }
  }
}

public struct CanonAppearanceDerivation: Derivation {
  public static let version = 2
  public static let definition = """
    CREATE TABLE nf_derived_canon_appearance (novel BLOB NOT NULL, entity TEXT NOT NULL, chapter INTEGER NOT NULL, PRIMARY KEY (novel, entity, chapter)) STRICT, WITHOUT ROWID;
    """

  public init() {}

  public var inputs: [DerivationInput<UUID>] { CanonCharacters.inputs }

  public static func key(of output: CanonAppearanceEntry) -> UUID { output.novel }

  public static func request(for novel: UUID) -> QueryInterfaceRequest<CanonAppearanceEntry> { CanonAppearanceEntry.filter(Column("novel") == novel) }

  public func allKeys(in context: DerivationContext) throws(StoreError) -> Set<UUID> { try CanonCharacters.novels(in: context) }

  public func outputs(for novel: UUID, in context: DerivationContext) throws(StoreError) -> [CanonAppearanceEntry] {
    try CanonCharacters.load(novel: novel, in: context).appearances
  }
}

public struct CharacterStateDerivation: Derivation {
  public static let version = 2
  public static let definition = """
    CREATE TABLE nf_derived_character_state (
      novel BLOB NOT NULL, entity TEXT NOT NULL, location TEXT, conditions TEXT, immediate_goal TEXT, status_note TEXT, chapter INTEGER NOT NULL,
      PRIMARY KEY (novel, entity)
    ) STRICT, WITHOUT ROWID;
    """

  public init() {}

  public var inputs: [DerivationInput<UUID>] { CanonCharacters.inputs }

  public static func key(of output: CharacterStateEntry) -> UUID { output.novel }

  public static func request(for novel: UUID) -> QueryInterfaceRequest<CharacterStateEntry> { CharacterStateEntry.filter(Column("novel") == novel) }

  public func allKeys(in context: DerivationContext) throws(StoreError) -> Set<UUID> { try CanonCharacters.novels(in: context) }

  public func outputs(for novel: UUID, in context: DerivationContext) throws(StoreError) -> [CharacterStateEntry] { try CanonCharacters.load(novel: novel, in: context).states }
}

public struct CanonRelationshipDerivation: Derivation {
  public static let version = 2
  public static let definition = """
    CREATE TABLE nf_derived_canon_relationship (
      novel BLOB NOT NULL, entity TEXT NOT NULL, target TEXT NOT NULL, kind TEXT NOT NULL, chapter INTEGER NOT NULL, note TEXT,
      PRIMARY KEY (novel, entity, target, kind, chapter)
    ) STRICT, WITHOUT ROWID;
    """

  public init() {}

  public var inputs: [DerivationInput<UUID>] { CanonCharacters.inputs }

  public static func key(of output: CanonRelationshipEntry) -> UUID { output.novel }

  public static func request(for novel: UUID) -> QueryInterfaceRequest<CanonRelationshipEntry> { CanonRelationshipEntry.filter(Column("novel") == novel) }

  public func allKeys(in context: DerivationContext) throws(StoreError) -> Set<UUID> { try CanonCharacters.novels(in: context) }

  public func outputs(for novel: UUID, in context: DerivationContext) throws(StoreError) -> [CanonRelationshipEntry] {
    try CanonCharacters.load(novel: novel, in: context).relationships
  }
}

public struct CharacterEventDerivation: Derivation {
  public static let version = 2
  public static let definition = """
    CREATE TABLE nf_derived_character_event (
      novel BLOB NOT NULL, entity TEXT NOT NULL, chapter INTEGER NOT NULL, kind TEXT NOT NULL, detail TEXT NOT NULL, before TEXT, after TEXT,
      PRIMARY KEY (novel, entity, chapter, kind, detail)
    ) STRICT, WITHOUT ROWID;
    """

  public init() {}

  public var inputs: [DerivationInput<UUID>] { CanonCharacters.inputs }

  public static func key(of output: CharacterEventEntry) -> UUID { output.novel }

  public static func request(for novel: UUID) -> QueryInterfaceRequest<CharacterEventEntry> { CharacterEventEntry.filter(Column("novel") == novel) }

  public func allKeys(in context: DerivationContext) throws(StoreError) -> Set<UUID> { try CanonCharacters.novels(in: context) }

  public func outputs(for novel: UUID, in context: DerivationContext) throws(StoreError) -> [CharacterEventEntry] { try CanonCharacters.load(novel: novel, in: context).events }
}
