import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowStore

private let composed = "\u{E9}"
private let decomposed = "e\u{301}"

private func history(_ generator: inout SeededGenerator) -> [ChangeRecord] {
  var factory = ChangeFactory()
  var changes = factory.changes(&generator)
  if generator.chance(0.3) {
    let clock = factory.clock(&generator)
    let key = generator.pick(from: Fixture.noteKeys)
    changes += [composed, decomposed].map { Fixture.change(.set, Fixture.note, key, clock: clock, fields: ["title": .string($0)], id: Fixture.uuid(&generator)) }
  }
  if generator.chance(0.3) {
    let key = generator.pick(from: Fixture.noteKeys)
    let clock = generator.chance(0.5) ? Fixture.clock(-1) : Fixture.clock(10)
    changes.append(Fixture.change(.purge, Fixture.note, key, clock: clock, id: Fixture.uuid(&generator)))
  }
  return changes
}

private func opaqueLines(_ generator: inout SeededGenerator) -> [Data] {
  (0..<generator.int(in: 0...3)).map { _ in generator.opaqueLine() }
}

private func reference(_ changes: [ChangeRecord], _ lines: [Data], _ registry: SchemaRegistry) -> VaultState {
  var state = Fixture.state(changes, registry)
  for line in lines { state.keepOpaque(line) }
  return state.retained(registry: registry)
}

@Suite("VaultStore equivalence with the reference model")
struct StoreEquivalenceTests {
  @Test("should equal the reference state for records applied in a shuffled order with random duplicates")
  func shouldMatchReferenceInOneTransaction() async throws {
    try await forAll(iterations: 300) { generator in
      let registry = generator.chance(0.5) ? Fixture.v1 : Fixture.v2
      let changes = history(&generator)
      let lines = opaqueLines(&generator)
      let store = try StoreFixture.open(registry)
      try await store.apply(generator.withDuplicates(changes))
      try await store.keepOpaque(lines + lines.prefix(1))
      let expected = reference(changes, lines, registry)
      let loaded = try await store.loadState(.vault)
      try #require(loaded == expected)
      try #require(loaded.digest == expected.digest)
      try #require(try await store.loadState(.own).isEmpty)
    }
  }

  @Test("should equal the reference state when the records are spread over several transactions")
  func shouldMatchReferenceAcrossTransactions() async throws {
    try await forAll(iterations: 300) { generator in
      let registry = generator.chance(0.5) ? Fixture.v1 : Fixture.v2
      let changes = history(&generator)
      let lines = opaqueLines(&generator)
      let store = try StoreFixture.open(registry)
      for part in generator.split(changes, into: generator.int(in: 2...6)) { try await store.apply(generator.shuffled(part)) }
      for line in lines { try await store.keepOpaque([line]) }
      let expected = reference(changes, lines, registry)
      let loaded = try await store.loadState(.vault)
      try #require(loaded == expected)
      try #require(loaded.digest == expected.digest)
    }
  }

  @Test("should keep the two scopes independent, each equal to the reference of its own records")
  func shouldKeepScopesIndependent() async throws {
    try await forAll(iterations: 300) { generator in
      let vault = history(&generator)
      let own = history(&generator)
      let lines = opaqueLines(&generator)
      let store = try StoreFixture.open(Fixture.v1)
      try await store.write { transaction in
        for (record, scope) in (vault.map { ($0, StateScope.vault) } + own.map { ($0, StateScope.own) }) { try transaction.apply(record, scope: scope) }
        for line in lines { try transaction.keepOpaque(line, scope: .own) }
      }
      try #require(try await store.loadState(.vault).digest == reference(vault, [], Fixture.v1).digest)
      try #require(try await store.loadState(.own).digest == reference(own, lines, Fixture.v1).digest)
    }
  }

  @Test("should read one entity exactly as the whole-state load does")
  func shouldReadEntitiesLikeTheWholeState() async throws {
    try await forAll(iterations: 300) { generator in
      let changes = history(&generator)
      let store = try StoreFixture.open(Fixture.v2)
      try await store.apply(changes)
      let loaded = try await store.loadState(.vault)
      let refs = LocalOperation.notes + LocalOperation.messages + LocalOperation.revisioned + LocalOperation.tags
      let states = try await store.read { transaction in try refs.map { try transaction.state(of: $0) } }
      try #require(states == refs.map { loaded.state(of: $0) })
    }
  }
}
