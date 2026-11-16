import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport

func must<Value>(_ value: Value?, _ what: String) -> Value {
  guard let value else { preconditionFailure("invalid fixture: \(what)") }
  return value
}

enum Fixture {
  static let note = must(EntityKind("note"), "note")
  static let message = must(EntityKind("message"), "message")
  static let draft = must(EntityKind("draft"), "draft")
  static let tag = must(EntityKind("tag"), "tag")
  static let outline = must(EntityKind("outline"), "outline")

  static let statusOrder = ["draft", "review", "final"]
  static let extendedStatusOrder = ["draft", "review", "final", "archived"]

  static let replicas = ["00000000-0000-0000-0000-00000000000a", "00000000-0000-0000-0000-00000000000b", "00000000-0000-0000-0000-00000000000c"].map {
    must(ReplicaID($0), $0)
  }

  static let noteKeys = ["k1", "k2", "k3"].map(key)
  static let messageKeys = ["m1", "m2", "m3"].map(key)
  static let draftKeys = ["d1", "d2"].map(key)

  static let values: [JSONValue] = ["a", "b", "\u{E9}", "e\u{301}", 1, 2, nil, ["x": 1], ["x": "\u{E9}"]]

  static let v1 = registry(version: 1, noteFields: [:], status: statusOrder, marks: ["approved"], tag: false)
  static let vMid = registry(version: 2, noteFields: ["pinned": .register], status: statusOrder, marks: ["approved"], tag: false)
  static let v2 = registry(version: 3, noteFields: ["pinned": .register], status: extendedStatusOrder, marks: ["approved", "reviewed"], tag: true)

  static func registry(version: Int, noteFields: [String: FieldRule], status: [String], marks: [String], tag: Bool) -> SchemaRegistry {
    let noteShape = EntityShape.record(fields: noteFields.merging(["title": .register, "status": .monotone(order: status), "origin": .firstWriterWins]) { $1 })
    var entities = [
      EntitySchema(kind: note, shape: noteShape, syncClass: .general),
      EntitySchema(kind: message, shape: .appended, syncClass: .general),
      EntitySchema(kind: draft, shape: .revisioned(fields: ["title": .register], marks: marks, retention: .keepNewest(3)), syncClass: .general),
      EntitySchema(kind: outline, shape: .revisioned(fields: [:], marks: [], retention: .keepNewest(1)), syncClass: .general),
    ]
    if tag { entities.append(EntitySchema(kind: self.tag, shape: .record(fields: ["label": .register]), syncClass: .general)) }
    return SchemaRegistry(version: version, entities: entities)
  }

  static func key(_ text: String) -> EntityKey {
    must(EntityKey(text), text)
  }

  static func clock(_ wall: Int64, _ counter: UInt16 = 0, replica: Int = 0) -> HLCTimestamp {
    must(HLCTimestamp(wallMillis: 1_700_000_000_000 + wall, counter: counter, replica: replicas[replica]), "clock")
  }

  static func uuid(_ generator: inout SeededGenerator) -> UUID {
    let bytes = (0..<16).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
    return UUID(
      uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
  }

  static func change(
    _ kind: ChangeKind, _ entity: EntityKind, _ key: EntityKey, clock: HLCTimestamp, schema: Int = 1, fields: [String: JSONValue] = [:], id: UUID = UUID()
  ) -> ChangeRecord {
    ChangeRecord(id: id, clock: clock, schema: schema, entity: entity, key: key, kind: kind, fields: fields)
  }

  static func revise(
    _ item: RevisionItem, clock: HLCTimestamp, entity: EntityKind = Fixture.draft, key: EntityKey = Fixture.key("d1"), head: Bool = true, marks: [String] = [],
    id: UUID = UUID()
  ) -> ChangeRecord {
    .revise(id: id, clock: clock, schema: 1, entity: entity, key: key, item: item, head: head, marks: marks)
  }

  static func state(_ changes: [ChangeRecord], _ registry: SchemaRegistry = v1) -> VaultState {
    var state = VaultState()
    for change in changes { state.apply(change, registry: registry) }
    return state
  }

  static func rebuilt(_ state: VaultState, _ registry: SchemaRegistry = v1) -> VaultState {
    var rebuilt = Fixture.state(state.records(schema: registry.version), registry)
    for line in state.opaqueLines { rebuilt.keepOpaque(line) }
    return rebuilt
  }
}

struct ChangeFactory {
  private struct Stored {
    let entity: EntityKind
    let key: EntityKey
    let item: RevisionItem
  }

  private var recentClocks: [HLCTimestamp] = []
  private var stored: [Stored] = []

  mutating func changes(_ generator: inout SeededGenerator, count: ClosedRange<Int> = 1...40) -> [ChangeRecord] {
    (0..<generator.int(in: count)).map { _ in change(&generator) }
  }

  mutating func change(_ generator: inout SeededGenerator) -> ChangeRecord {
    switch generator.int(in: 0...99) {
    case 0..<25: noteSet(&generator)
    case 25..<37: messageAppend(&generator)
    case 37..<57: draftRevise(&generator)
    case 57..<72: draftReassert(&generator)
    case 72..<82: draftSet(&generator)
    case 82..<92: foreign(&generator)
    default: purge(&generator)
    }
  }

  mutating func clock(_ generator: inout SeededGenerator) -> HLCTimestamp {
    if !recentClocks.isEmpty, generator.chance(0.25) { return generator.pick(from: recentClocks) }
    let issued = Fixture.clock(Int64(generator.int(in: 0...4)), UInt16(generator.int(in: 0...1)), replica: generator.int(in: 0...2))
    recentClocks.append(issued)
    if recentClocks.count > 6 { recentClocks.removeFirst() }
    return issued
  }

  mutating func noteSet(_ generator: inout SeededGenerator, key: EntityKey? = nil) -> ChangeRecord {
    var fields = [String: JSONValue]()
    if generator.chance(0.6) { fields["title"] = generator.pick(from: Fixture.values) }
    if generator.chance(0.5) { fields["status"] = .string(generator.pick(from: Fixture.statusOrder)) }
    if generator.chance(0.4) { fields["origin"] = generator.pick(from: Fixture.values) }
    let clock = clock(&generator)
    return Fixture.change(.set, Fixture.note, key ?? generator.pick(from: Fixture.noteKeys), clock: clock, fields: fields, id: Fixture.uuid(&generator))
  }

  mutating func messageAppend(_ generator: inout SeededGenerator) -> ChangeRecord {
    let fields: [String: JSONValue] = ["text": generator.pick(from: Fixture.values), "n": .int(Int64(generator.int(in: 0...2)))]
    let clock = clock(&generator)
    return Fixture.change(.append, Fixture.message, generator.pick(from: Fixture.messageKeys), clock: clock, fields: fields, id: Fixture.uuid(&generator))
  }

  mutating func draftRevise(_ generator: inout SeededGenerator) -> ChangeRecord {
    let key = generator.pick(from: Fixture.draftKeys)
    let entity = generator.chance(0.3) ? Fixture.outline : Fixture.draft
    let parent = stored.isEmpty || generator.chance(0.3) ? nil : generator.pick(from: stored).item.id
    let created = clock(&generator)
    let generation: Int64 = generator.chance(0.15) ? generator.pick(from: [0, Int64.max - 1, Int64.max]) : Int64(generator.int(in: 0...6))
    let item = RevisionItem(parent: parent, body: generator.pick(from: Fixture.values), created: created, generation: generation)
    stored.append(Stored(entity: entity, key: key, item: item))
    let clock = generator.chance(0.5) ? created : clock(&generator)
    let marks = entity == Fixture.outline ? [] : marks(&generator)
    return Fixture.revise(item, clock: clock, entity: entity, key: key, head: generator.chance(0.6), marks: marks, id: Fixture.uuid(&generator))
  }

  mutating func draftReassert(_ generator: inout SeededGenerator) -> ChangeRecord {
    guard !stored.isEmpty else { return draftRevise(&generator) }
    let original = generator.pick(from: stored)
    let clock = clock(&generator)
    let marks = original.entity == Fixture.outline ? [] : marks(&generator)
    return Fixture.revise(
      original.item, clock: clock, entity: original.entity, key: original.key, head: generator.chance(0.6), marks: marks, id: Fixture.uuid(&generator))
  }

  mutating func draftSet(_ generator: inout SeededGenerator) -> ChangeRecord {
    var fields: [String: JSONValue] = [:]
    if generator.chance(0.8) { fields["title"] = generator.pick(from: Fixture.values) }
    if generator.chance(0.3), !stored.isEmpty { fields[generator.pick(from: ["head", "approved"])] = .string(generator.pick(from: stored).item.id) }
    let clock = clock(&generator)
    return Fixture.change(.set, Fixture.draft, generator.pick(from: Fixture.draftKeys), clock: clock, fields: fields, id: Fixture.uuid(&generator))
  }

  mutating func purge(_ generator: inout SeededGenerator) -> ChangeRecord {
    let (kind, key) =
      switch generator.int(in: 0...4) {
      case 0: (Fixture.note, generator.pick(from: Fixture.noteKeys))
      case 1: (Fixture.message, generator.pick(from: Fixture.messageKeys))
      case 2: (Fixture.outline, generator.pick(from: Fixture.draftKeys))
      case 3: (Fixture.tag, Fixture.key("t1"))
      default: (Fixture.draft, generator.pick(from: Fixture.draftKeys))
      }
    let clock = clock(&generator)
    return Fixture.change(.purge, kind, key, clock: clock, id: Fixture.uuid(&generator))
  }

  mutating func foreign(_ generator: inout SeededGenerator) -> ChangeRecord {
    let clock = clock(&generator)
    let id = Fixture.uuid(&generator)
    let noteKey = generator.pick(from: Fixture.noteKeys)
    let draftKey = generator.pick(from: Fixture.draftKeys)
    let value = generator.pick(from: Fixture.values)
    let revise = Fixture.revise(RevisionItem(parent: nil, body: value, created: clock, generation: 0), clock: clock, key: draftKey, id: id).fields
    switch generator.int(in: 0...10) {
    case 0: return Fixture.change(.set, Fixture.note, noteKey, clock: clock, schema: 9, fields: ["title": value], id: id)
    case 1: return Fixture.change(.set, Fixture.tag, Fixture.key("t1"), clock: clock, fields: ["label": value], id: id)
    case 2: return Fixture.change(.set, Fixture.note, noteKey, clock: clock, fields: ["pinned": value, "title": value, "status": "archived"], id: id)
    case 3: return Fixture.change(.set, Fixture.note, noteKey, clock: clock, fields: ["status": "archived", "unknown": value], id: id)
    case 4: return Fixture.change(.revise, Fixture.draft, draftKey, clock: clock, fields: revise.merging(["marks": ["reviewed"]]) { $1 }, id: id)
    case 5: return Fixture.change(.append, Fixture.note, noteKey, clock: clock, fields: ["text": value], id: id)
    case 6: return Fixture.change(.revise, Fixture.draft, draftKey, clock: clock, fields: revise.merging(["revision": "v:not-derived"]) { $1 }, id: id)
    case 7: return Fixture.change(.revise, Fixture.draft, draftKey, clock: clock, fields: revise.merging(["created": "yesterday"]) { $1 }, id: id)
    case 8: return Fixture.change(.revise, Fixture.draft, draftKey, clock: clock, fields: revise.merging(["generation": -1]) { $1 }, id: id)
    case 9: return Fixture.change(.purge, Fixture.note, noteKey, clock: clock, fields: ["reason": value], id: id)
    default: return Fixture.change(.set, Fixture.message, generator.pick(from: Fixture.messageKeys), clock: clock, fields: ["text": value], id: id)
    }
  }

  private func marks(_ generator: inout SeededGenerator) -> [String] {
    generator.chance(0.4) ? ["approved"] : []
  }
}

extension SeededGenerator {
  mutating func withDuplicates(_ changes: [ChangeRecord]) -> [ChangeRecord] {
    guard !changes.isEmpty else { return changes }
    let extra = (0..<int(in: 0...changes.count)).map { _ in pick(from: changes) }
    return shuffled(changes + extra)
  }

  mutating func split(_ changes: [ChangeRecord], into count: Int) -> [[ChangeRecord]] {
    var parts = Array(repeating: [ChangeRecord](), count: count)
    for change in changes {
      parts[int(in: 0...(count - 1))].append(change)
      if chance(0.2) { parts[int(in: 0...(count - 1))].append(change) }
    }
    return parts
  }

  mutating func opaqueLine() -> Data {
    data(count: int(in: 0...12))
  }
}
