import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowStore

private let composed = "caf\u{E9}"
private let decomposed = "cafe\u{301}"
private let entry = must(EntityKind("entry"), "entry")
private let page = must(EntityKind("page"), "page")

private let registry = SchemaRegistry(
  version: 1,
  entities: [
    EntitySchema(kind: entry, shape: .record(fields: [composed: .register]), syncClass: .general),
    EntitySchema(kind: page, shape: .revisioned(fields: [:], marks: [composed, decomposed], retention: .keepAll), syncClass: .general),
  ])

private func naturalKey(_ text: String) -> EntityKey {
  EntityKey.natural(scope: "vault", kind: entry, components: [text])
}

@Suite("VaultStore byte exactness")
struct StoreByteExactnessTests {
  @Test("should keep entities whose natural keys come from normalisation twins apart")
  func shouldKeepNaturalKeysApart() async throws {
    let store = try StoreFixture.open(registry)
    let refs = [composed, decomposed].map { EntityRef(kind: entry, key: naturalKey($0)) }
    #expect(refs[0] != refs[1])
    let records = try await store.write { transaction in try refs.map { try transaction.set($0, [composed: .string($0.key.rawValue)]) } }
    let loaded = try await store.loadState(.vault)
    #expect(loaded.refs.count == 2)
    #expect(loaded == Fixture.state(records, registry))
  }

  @Test("should keep a field and its normalisation twin apart, the undeclared one as a foreign remainder")
  func shouldKeepFieldNamesApart() async throws {
    let store = try StoreFixture.open(registry)
    let ref = EntityRef(kind: entry, key: Fixture.key("e1"))
    let refused = await #expect(throws: StoreError.self) { try await store.write { transaction in try transaction.set(ref, [decomposed: "twin"]) } }
    #expect(refused?.code == "store.invalid_change")
    let records = [composed, decomposed].map { Fixture.change(.set, entry, ref.key, clock: Fixture.clock(1), fields: [$0: .string($0)]) }
    try await store.apply(records)
    let loaded = try await store.loadState(.vault)
    #expect(loaded == Fixture.state(records, registry))
    guard case .record(let state) = loaded.state(of: ref) else { throw StoreTestFailure.unexpectedState }
    #expect(state.fields.keys.map { Array($0.value.utf8) } == [Array(composed.utf8)])
    #expect(loaded.foreign.map { $0.canonicalBytes() } == [records[1].canonicalBytes()])
  }

  @Test("should keep two marks whose names differ only by normalisation apart")
  func shouldKeepMarkNamesApart() async throws {
    let store = try StoreFixture.open(registry)
    let ref = EntityRef(kind: page, key: Fixture.key("p1"))
    let (records, ids) = try await store.write { transaction in
      let first = try transaction.revise(ref, body: "first", marks: [composed])
      let second = try transaction.revise(ref, body: "second", marks: [decomposed])
      return ([first.record, second.record], [first.revision, second.revision])
    }
    let loaded = try await store.loadState(.vault)
    #expect(loaded.digest == Fixture.state(records, registry).digest)
    guard case .revisioned(let state) = loaded.state(of: ref) else { throw StoreTestFailure.unexpectedState }
    #expect(state.marks.count == 2)
    #expect(state[mark: composed]?.value == .string(ids[0]))
    #expect(state[mark: decomposed]?.value == .string(ids[1]))
  }

  @Test("should keep an empty opaque line and lines that differ in one byte")
  func shouldKeepOpaqueLinesExactly() async throws {
    let store = try StoreFixture.open(registry)
    let lines = [Data(), Data([0x00]), Data([0x00, 0x00]), Data(composed.utf8), Data(decomposed.utf8)]
    try await store.keepOpaque(lines + lines)
    #expect(try await store.loadState(.vault).opaqueLines == lines.sorted { $0.lexicographicallyPrecedes($1) })
  }

  @Test("should break an equal-clock tie between normalisation twins by bytes and keep twin revisions apart")
  func shouldCompareValuesByBytes() async throws {
    let ref = EntityRef(kind: entry, key: Fixture.key("e1"))
    let values = [composed, decomposed].map { Fixture.change(.set, entry, ref.key, clock: Fixture.clock(1), fields: [composed: .string($0)]) }
    let items = [composed, decomposed].map { RevisionItem(parent: nil, body: .string($0), created: Fixture.clock(1), generation: 0) }
    let revisions = items.map { Fixture.revise($0, clock: Fixture.clock(1), entity: page, key: Fixture.key("p1"), head: false) }
    for order in [values + revisions, (values + revisions).reversed()] {
      let store = try StoreFixture.open(registry)
      try await store.apply(order)
      let loaded = try await store.loadState(.vault)
      #expect(loaded == Fixture.state(order, registry))
      guard case .record(let state) = loaded.state(of: ref), case .revisioned(let draft) = loaded.state(of: EntityRef(kind: page, key: Fixture.key("p1"))) else {
        throw StoreTestFailure.unexpectedState
      }
      let winner = [Array(composed.utf8), Array(decomposed.utf8)].max { $0.lexicographicallyPrecedes($1) }
      #expect(state[field: composed]?.value.stringValue.map { Array($0.utf8) } == winner)
      #expect(draft.revisions.count == 2)
    }
  }
}
