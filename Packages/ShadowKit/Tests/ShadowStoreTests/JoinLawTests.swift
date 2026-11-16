import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@Suite("Join laws")
struct JoinLawTests {
  @Test("should reach the same digest for any order of the same changes with random duplicates")
  func shouldIgnoreOrderAndDuplicates() throws {
    try forAll(iterations: 300) { generator in
      var factory = ChangeFactory()
      let changes = factory.changes(&generator)
      let reference = Fixture.state(changes)
      let replayed = Fixture.state(generator.withDuplicates(changes))
      try #require(replayed == reference)
      try #require(replayed.digest == reference.digest)
    }
  }

  @Test("should merge commutatively, associatively and idempotently")
  func shouldSatisfyJoinLaws() throws {
    try forAll(iterations: 300) { generator in
      var factory = ChangeFactory()
      var a = Fixture.state(factory.changes(&generator, count: 0...25))
      var b = Fixture.state(factory.changes(&generator, count: 0...25))
      let c = Fixture.state(factory.changes(&generator, count: 0...25))
      for _ in 0..<generator.int(in: 0...2) { a.keepOpaque(generator.opaqueLine()) }
      for _ in 0..<generator.int(in: 0...2) { b.keepOpaque(generator.opaqueLine()) }
      try #require(a.merging(b) == b.merging(a))
      try #require(a.merging(b).digest == b.merging(a).digest)
      try #require(a.merging(b).merging(c) == a.merging(b.merging(c)))
      try #require(a.merging(a) == a)
      try #require(a.merging(b).merging(b) == a.merging(b))
      try #require(a.merging(VaultState()) == a)
      try #require(VaultState().merging(a) == a)
      try #require(VaultState().merging(VaultState()).isEmpty)
    }
  }

  @Test("should equal applying everything to one state for any partition merged in any order")
  func shouldMatchSingleStateForAnyPartition() throws {
    try forAll(iterations: 300) { generator in
      var factory = ChangeFactory()
      let changes = factory.changes(&generator)
      let parts = generator.split(changes, into: generator.int(in: 1...4)).map { Fixture.state(generator.shuffled($0)) }
      let merged = generator.shuffled(parts).reduce(VaultState()) { $0.merging($1) }
      let reference = Fixture.state(changes)
      try #require(merged == reference)
      try #require(merged.digest == reference.digest)
    }
  }
}
