import Foundation
import GRDB
import ShadowCore
import ShadowTestSupport
import Synchronization
import Testing

@testable import ShadowStore

private let replicaCount = 3

private final class CausalCountingReconciler: StoreReconciler {
  private let remoteCalls = Mutex(0)
  private let failsOnRemote: Bool

  init(failsOnRemote: Bool = false) {
    self.failsOnRemote = failsOnRemote
  }

  var remote: Int {
    remoteCalls.withLock { $0 }
  }

  func reconcile(_ touched: [EntityRef], origin: ChangeOrigin, in database: Database) throws {
    guard origin == .remote else { return }
    remoteCalls.withLock { $0 += 1 }
    if failsOnRemote { throw ReconcilerFailure() }
  }

  func reset(in database: Database) throws {}
}

private func replicas(
  _ order: CausalReplicaOrder, count: Int = replicaCount, seed: UInt64 = 0, reconciler: @escaping @Sendable (Int) -> (any StoreReconciler)? = { _ in nil }
) async throws -> CausalReplicas {
  try await CausalReplicas(CausalReplicaSetup(count: count, registry: Fixture.v2, order: order, reconciler: reconciler, seed: seed))
}

private func localWrite(_ replicas: CausalReplicas, _ index: Int, _ operations: [LocalOperation], known: [EntityRef: [String]]) async throws -> [EntityRef: [String]] {
  try await replicas.write(index) { transaction in
    var known = known
    for operation in operations {
      do {
        _ = try operation.run(&transaction, known: &known)
      } catch StoreError.invalidChange {
        continue
      }
    }
    return known
  }
}

private func drive(_ replicas: CausalReplicas, _ generator: inout SeededGenerator, steps: Int = 24) async throws {
  var known = Array(repeating: [EntityRef: [String]](), count: replicas.count)
  for _ in 0..<steps {
    switch generator.int(in: 0...99) {
    case 0..<45:
      let index = generator.int(in: 0...(replicas.count - 1))
      let operations = (0..<generator.int(in: 1...3)).map { _ in LocalOperation.random(&generator) }
      known[index] = try await localWrite(replicas, index, operations, known: known[index])
    case 45..<90:
      _ = try await replicas.step(using: &generator)
    default:
      await replicas.advanceClock(of: generator.int(in: 0...(replicas.count - 1)), by: .seconds(generator.int(in: 1...7_200)))
    }
  }
}

private func model(_ records: [ChangeRecord]) -> VaultState {
  Fixture.state(records, Fixture.v2).retained(registry: Fixture.v2)
}

private func digests(_ replicas: CausalReplicas) async throws -> [String] {
  var result = [String]()
  for index in 0..<replicas.count { result.append(try await replicas.store(index).loadState(.vault).digest) }
  return result
}

private func replicaIds(_ replicas: CausalReplicas) async -> [ReplicaID] {
  var ids = [ReplicaID]()
  for index in 0..<replicas.count { ids.append(await replicas.store(index).replica) }
  return ids
}

private func coverageKey(_ record: ChangeRecord) -> String {
  record.kind == .revise && [Fixture.draft, Fixture.outline].contains(record.entity) ? "revise" : record.kind == .revise ? "other" : record.kind.rawValue
}

private struct Audit {
  var causalViolations = 0
  var orderViolations = 0
}

private func audit(_ replicas: CausalReplicas) async -> Audit {
  var counts = Array(repeating: Array(repeating: 0, count: replicas.count), count: replicas.count)
  var result = Audit()
  for event in await replicas.deliveries() {
    let taken = counts[event.reader][event.writer]
    guard !event.isRedelivery else {
      if event.first < 0 || event.first + event.count > taken { result.orderViolations += 1 }
      continue
    }
    if event.first != taken { result.orderViolations += 1 }
    for index in event.first..<(event.first + event.count) {
      let dependencies = await replicas.dependencies(writer: event.writer, index: index)
      for other in 0..<replicas.count where other != event.writer && other != event.reader && counts[event.reader][other] < dependencies[other] {
        result.causalViolations += 1
      }
    }
    counts[event.reader][event.writer] += event.count
  }
  return result
}

private let note = EntityRef(kind: Fixture.note, key: Fixture.noteKeys[0])

@Suite("CausalReplicas")
struct CausalReplicasTests {
  @Test("should converge every replica to the reference model", arguments: [CausalReplicaOrder.causal, .writerOrderOnly])
  func shouldConverge(order: CausalReplicaOrder) async throws {
    let iterations = 60
    var coverage = [String: Int]()
    try await forAll(iterations: iterations) { generator in
      let replicas = try await replicas(order, seed: generator.next())
      try await drive(replicas, &generator)
      try await replicas.settle()
      try #require(await replicas.isSettled())
      let records = await replicas.records()
      for key in Set(records.map(coverageKey)) { coverage[key, default: 0] += 1 }
      let expected = model(records).digest
      for digest in try await digests(replicas) { try #require(digest == expected) }
    }
    for key in ["set", "append", "revise", "purge"] {
      #expect(coverage[key, default: 0] * 2 >= iterations, "\(key) appeared in \(coverage[key, default: 0]) of \(iterations) cases")
    }
  }

  @Test("should never apply a change before the changes its writer had applied in causal order")
  func shouldRespectCausalOrder() async throws {
    try await forAll(iterations: 30) { generator in
      let replicas = try await replicas(.causal, seed: generator.next())
      try await drive(replicas, &generator)
      try #require(await audit(replicas).causalViolations == 0)
    }
  }

  @Test("should break causal order in writer-order-only mode and still converge")
  func shouldBreakCausalOrderWhenOff() async throws {
    var violations = 0
    try await forAll(iterations: 30) { generator in
      let replicas = try await replicas(.writerOrderOnly, seed: generator.next())
      try await drive(replicas, &generator)
      violations += await audit(replicas).causalViolations
      try await replicas.settle()
      let expected = model(await replicas.records()).digest
      for digest in try await digests(replicas) { try #require(digest == expected) }
    }
    #expect(violations > 0)
  }

  @Test("should only take the next change of a writer in either order", arguments: [CausalReplicaOrder.causal, .writerOrderOnly])
  func shouldKeepWriterOrder(order: CausalReplicaOrder) async throws {
    try await forAll(iterations: 30) { generator in
      let replicas = try await replicas(order, seed: generator.next())
      try await drive(replicas, &generator)
      try #require(await audit(replicas).orderViolations == 0)
      for reader in 0..<replicas.count {
        for writer in 0..<replicas.count where writer != reader {
          try #require(await replicas.appliedCount(reader: reader, writer: writer) <= (await replicas.appliedCount(reader: writer, writer: writer)))
        }
      }
    }
  }

  @Test("should leave the digests unchanged when changes are delivered again")
  func shouldIgnoreRedelivery() async throws {
    try await forAll(iterations: 30) { generator in
      let replicas = try await replicas(.causal, seed: generator.next())
      try await drive(replicas, &generator)
      try await replicas.settle()
      let before = try await digests(replicas)
      for reader in 0..<replicas.count {
        for writer in 0..<replicas.count where writer != reader { try await replicas.redeliver(from: writer, to: reader, count: generator.int(in: 0...50)) }
      }
      try #require(try await digests(replicas) == before)
    }
  }

  @Test("should give the same digest whether changes arrive one at a time or in one batch")
  func shouldIgnoreBatchSize() async throws {
    try await forAll(iterations: 30) { generator in
      let replicas = try await replicas(.causal, count: 4, seed: generator.next())
      var known = [[EntityRef: [String]]](repeating: [:], count: 2)
      for _ in 0..<generator.int(in: 1...12) {
        let writer = generator.int(in: 0...1)
        known[writer] = try await localWrite(replicas, writer, [LocalOperation.random(&generator), LocalOperation.random(&generator)], known: known[writer])
      }
      for (reader, batch) in [(2, 1), (3, Int.max)] {
        for writer in 0...1 { try await replicas.deliver(from: writer, to: reader, batch: batch) }
      }
      let all = try await digests(replicas)
      try #require(all[2] == all[3])
      try #require(all[2] == model(await replicas.records()).digest)
    }
  }

  @Test("should replay a seed exactly, down to every replica's digest and id")
  func shouldBeReproducible() async throws {
    try await forAll(iterations: 20) { generator in
      let seed = generator.next()
      var runs = [(schedule: [CausalReplicaDelivery], digests: [String], ids: [ReplicaID])]()
      for order in [CausalReplicaOrder.causal, .causal] {
        var seeded = SeededGenerator(seed: seed)
        let replicas = try await replicas(order, seed: seed)
        try await drive(replicas, &seeded)
        try await replicas.settle()
        runs.append((await replicas.deliveries(), try await digests(replicas), await replicaIds(replicas)))
      }
      try #require(runs[0].schedule == runs[1].schedule)
      try #require(runs[0].digests == runs[1].digests)
      try #require(runs[0].ids == runs[1].ids)
    }
  }

  @Test("should order the replica ids differently for different seeds")
  func shouldVaryReplicaIdOrderWithSeed() async throws {
    var lowest = Set<Int>()
    for seed in 0..<8 as Range<UInt64> {
      let ids = await replicaIds(try await replicas(.causal, seed: seed))
      #expect(Set(ids).count == ids.count)
      lowest.insert(ids.indices.min { ids[$0] < ids[$1] } ?? -1)
    }
    #expect(lowest.count > 1)
  }

  @Test("should report nothing deliverable without news or while dependencies are missing")
  func shouldReportDeliverable() async throws {
    for order in [CausalReplicaOrder.causal, .writerOrderOnly] {
      let replicas = try await replicas(order)
      #expect(await replicas.isSettled())
      #expect(await replicas.deliverable(from: 0, to: 1) == 0)
      _ = try await localWrite(replicas, 0, [.set(note, ["title": "a"])], known: [:])
      #expect(await replicas.deliverable(from: 0, to: 1) == 1)
      #expect(await replicas.deliverable(from: 1, to: 0) == 0)
      #expect(try await replicas.deliver(from: 0, to: 1) == 1)
      _ = try await localWrite(replicas, 1, [.set(note, ["title": "b"])], known: [:])
      #expect(await replicas.deliverable(from: 1, to: 2) == (order == .causal ? 0 : 1))
      #expect(try await replicas.deliver(from: 1, to: 2) == (order == .causal ? 0 : 1))
      try await replicas.settle()
      #expect(await replicas.isSettled())
      #expect(await replicas.deliverable(from: 1, to: 2) == 0)
    }
  }

  @Test("should limit a delivery to the requested number of changes")
  func shouldHonourLimit() async throws {
    let replicas = try await replicas(.causal)
    _ = try await localWrite(replicas, 0, [.set(note, ["title": "a"]), .append(LocalOperation.messages[0], ["text": "x", "n": 1]), .set(note, ["title": "b"])], known: [:])
    #expect(try await replicas.deliver(from: 0, to: 1, atMost: 2, batch: 1) == 2)
    #expect(await replicas.deliverable(from: 0, to: 1) == 1)
    #expect(try await replicas.deliver(from: 0, to: 1, atMost: 0) == 0)
    #expect(try await replicas.deliver(from: 0, to: 1) == 1)
  }

  @Test("should converge when one replica's clock is hours ahead")
  func shouldConvergeWithSkewedClock() async throws {
    let replicas = try await replicas(.causal)
    await replicas.advanceClock(of: 0, by: .seconds(5 * 3_600))
    _ = try await localWrite(replicas, 0, [.set(note, ["title": "ahead"])], known: [:])
    _ = try await localWrite(replicas, 1, [.set(note, ["title": "behind"])], known: [:])
    try await replicas.settle()
    let states = try await [0, 1, 2].asyncMap { index in try await replicas.store(index).read { try $0.state(of: note) } }
    #expect(states[0] != nil)
    #expect(states[0] == states[1])
    #expect(states[1] == states[2])
    let all = try await digests(replicas)
    #expect(Set(all).count == 1)
  }

  @Test("should call each replica's reconciler for remote changes")
  func shouldUseReconcilerFactory() async throws {
    let counters = (0..<replicaCount).map { _ in CausalCountingReconciler() }
    let replicas = try await replicas(.causal) { counters[$0] }
    for index in 0..<replicaCount { _ = try await localWrite(replicas, index, [.set(note, ["title": .string("r\(index)")])], known: [:]) }
    try await replicas.settle()
    for counter in counters { #expect(counter.remote > 0) }
  }

  @Test("should rethrow a reconciler failure from deliver without counting the change as taken")
  func shouldRethrowReconcilerFailure() async throws {
    let replicas = try await replicas(.causal) { $0 == 1 ? CausalCountingReconciler(failsOnRemote: true) : nil }
    _ = try await localWrite(replicas, 0, [.set(note, ["title": "a"])], known: [:])
    do {
      try await replicas.deliver(from: 0, to: 1)
      Issue.record("deliver should have thrown")
    } catch StoreError.reconcilerFailed {
      #expect(await replicas.deliverable(from: 0, to: 1) == 1)
    }
  }
}

extension Sequence {
  fileprivate func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
    var result = [T]()
    for element in self { result.append(try await transform(element)) }
    return result
  }
}
