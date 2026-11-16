import Foundation
import GRDB
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowStore

private let draft = EntityRef(kind: Fixture.draft, key: Fixture.key("d1"))
private let outline = EntityRef(kind: Fixture.outline, key: Fixture.key("d1"))

private func item(_ body: JSONValue, _ generation: Int64, parent: String? = nil) -> RevisionItem {
  RevisionItem(parent: parent, body: body, created: Fixture.clock(generation, replica: 1), generation: generation)
}

private func revise(_ item: RevisionItem, _ ref: EntityRef = draft, at wall: Int64? = nil, head: Bool = false, marks: [String] = []) -> ChangeRecord {
  Fixture.revise(item, clock: wall.map { Fixture.clock($0, replica: 1) } ?? item.created, entity: ref.kind, key: ref.key, head: head, marks: marks)
}

private func revisionIDs(_ store: VaultStore, _ ref: EntityRef = draft, scope: StateScope = .vault) async throws -> Set<String> {
  guard case .revisioned(let state) = try await store.read({ try $0.state(of: ref, scope: scope) }) else { return [] }
  return Set(state.revisions.keys.map(\.value))
}

private func revisionRows(_ store: VaultStore, _ ref: EntityRef) async throws -> Int {
  try await store.read { transaction in
    try Int.fetchOne(transaction.database, sql: "SELECT COUNT(*) FROM revision WHERE scope = 0 AND kind = ? AND key = ?", arguments: [ref.kind.rawValue, ref.key.rawValue]) ?? -1
  }
}

private struct Interleaving {
  var local: [ChangeRecord] = []
  var remote: [ChangeRecord] = []
  var opaque: [Data] = []
}

private func interleave(_ store: VaultStore, _ generator: inout SeededGenerator) async throws -> Interleaving {
  var factory = ChangeFactory()
  var known = [EntityRef: [String]]()
  var history = Interleaving()
  for _ in 0..<generator.int(in: 1...6) {
    if generator.chance(0.5) {
      let records = factory.changes(&generator, count: 0...12)
      let opaque = (0..<generator.int(in: 0...1)).map { _ in generator.opaqueLine() }
      _ = try await store.applyRemote(Remote.lines(records, opaque: opaque, &generator))
      history.remote += records
      history.opaque += opaque
    } else {
      let result = try await runLocal((0..<generator.int(in: 1...8)).map { _ in LocalOperation.random(&generator) }, in: store, known: known)
      history.local += result.records
      known = result.known
    }
  }
  return history
}

@Suite("VaultStore retention")
struct StoreRetentionTests {
  @Test("should keep the vault scope equal to the retained reference of every record after any interleaving of local writes and remote applies")
  func shouldRetainVaultScope() async throws {
    try await forAll(iterations: 300, seed: 0x7E7A_1) { generator in
      let registry = generator.chance(0.5) ? Fixture.v2 : Fixture.vStrict
      let store = try StoreFixture.open(registry)
      let history = try await interleave(store, &generator)
      let expected = Remote.reference(history.local + history.remote, opaque: history.opaque, registry)
      let loaded = try await store.loadState(.vault)
      try #require(loaded == expected)
      try #require(loaded.digest == expected.digest)
    }
  }

  @Test("should keep the own scope equal to the retained reference of the local records after any interleaving of local writes and remote applies")
  func shouldRetainOwnScope() async throws {
    try await forAll(iterations: 300, seed: 0x7E7A_2) { generator in
      let registry = generator.chance(0.5) ? Fixture.v2 : Fixture.vStrict
      let store = try StoreFixture.open(registry)
      let history = try await interleave(store, &generator)
      let expected = Remote.reference(history.local, registry)
      let loaded = try await store.loadState(.own)
      try #require(loaded == expected)
      try #require(loaded.digest == expected.digest)
    }
  }

  @Test("should keep only the newest revision and the head of a kind that keeps one")
  func shouldKeepNewestOne() async throws {
    let store = try StoreFixture.open(Fixture.v2)
    let items = (0...2).map { item(.string("outline \($0)"), Int64($0)) }
    _ = try await store.applyRemote([revise(items[0], outline, head: true), revise(items[1], outline), revise(items[2], outline)].map { $0.canonicalBytes() })
    #expect(try await revisionIDs(store, outline) == [items[0].id, items[2].id])
    let (_, written) = try await store.write { transaction in try transaction.revise(outline, body: "local") }
    #expect(try await revisionIDs(store, outline) == [written])
    #expect(try await revisionIDs(store, outline, scope: .own) == [written])
    #expect(try await revisionRows(store, outline) == 1)
  }

  @Test("should keep a re-asserted old revision while a mark names it and prune it once the mark moves on")
  func shouldKeepMarkedOldRevision() async throws {
    let store = try StoreFixture.open(Fixture.v2)
    let items = (0...4).map { item(.string("draft \($0)"), Int64($0)) }
    _ = try await store.applyRemote(items.map { revise($0, head: $0 == items[4]).canonicalBytes() })
    #expect(try await revisionIDs(store) == Set(items[2...].map(\.id)))
    _ = try await store.applyRemote([revise(items[0], at: 20, marks: ["approved"]).canonicalBytes()])
    #expect(try await revisionIDs(store) == Set(([items[0]] + items[2...]).map(\.id)))
    _ = try await store.write { transaction in try transaction.reassert(draft, revision: items[3].id, head: false, marks: ["approved"]) }
    #expect(try await revisionIDs(store) == Set(items[2...].map(\.id)))
  }

  @Test("should break a tie between two branches of equal generations by the higher revision id")
  func shouldBreakTiesByID() async throws {
    let root = item("root", 0)
    func branch(_ name: String) -> [RevisionItem] {
      (1...5).reduce(into: [RevisionItem]()) { chain, generation in
        chain.append(item(.string("\(name) \(generation)"), Int64(generation), parent: chain.last?.id ?? root.id))
      }
    }
    let (left, right) = (branch("left"), branch("right"))
    let records = [revise(root, head: true)] + (left + right).map { revise($0) }
    let thirdSlot = try #require([left[3], right[3]].max { ExactString($0.id) < ExactString($1.id) })
    let expected = Set([root.id, left[4].id, right[4].id, thirdSlot.id])
    for order in [records, records.reversed()] {
      let store = try StoreFixture.open(Fixture.v2)
      for record in order { _ = try await store.applyRemote([record.canonicalBytes()]) }
      #expect(try await revisionIDs(store) == expected)
      #expect(try await store.loadState(.vault) == Remote.reference(records, Fixture.v2))
    }
  }

  @Test("should prune an entity holding thousands of revisions down to the limit")
  func shouldPruneThousands() async throws {
    let store = try StoreFixture.open(Fixture.v2)
    let items = (0..<3_000).map { item(.int(Int64($0)), Int64($0 % 1_000)) }
    let records = items.map { revise($0) }
    let result = try await store.applyRemote(records.map { $0.canonicalBytes() })
    #expect(result.touched == [draft])
    #expect(try await revisionRows(store, draft) == 3)
    #expect(try await store.loadState(.vault) == Remote.reference(records, Fixture.v2))
  }
}
