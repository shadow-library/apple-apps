import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowStore

private func writeConcurrently(_ store: VaultStore, tasks: Int) async throws -> [[ChangeRecord]] {
  try await withThrowingTaskGroup(of: [ChangeRecord].self) { group in
    for index in 0..<tasks {
      group.addTask {
        try await store.write { transaction in
          let note = LocalOperation.notes[index % LocalOperation.notes.count]
          let message = EntityRef(kind: Fixture.message, key: Fixture.key("c\(index)"))
          return [try transaction.set(note, ["title": .int(Int64(index))]), try transaction.append(message, item: ["n": .int(Int64(index))])]
        }
      }
    }
    var batches = [[ChangeRecord]]()
    for try await batch in group { batches.append(batch) }
    return batches
  }
}

@Suite("VaultStore concurrency")
struct StoreConcurrencyTests {
  @Test("should give concurrent writes distinct, gap-free sequences and the reference state", arguments: [false, true])
  func shouldSerialiseConcurrentWrites(onDisk: Bool) async throws {
    let directory = TemporaryDirectory()
    let store = try StoreFixture.open(Fixture.v2, at: onDisk ? .file(directory.storeURL) : .inMemory)
    let readers = Task {
      for _ in 0..<20 { _ = try await store.loadState(.vault) }
    }
    let batches = try await writeConcurrently(store, tasks: 64)
    try await readers.value
    let pending = try await store.allPending
    #expect(pending.map(\.sequence) == Array(1...128))
    let byLine = Dictionary(uniqueKeysWithValues: pending.map { ($0.line, $0.sequence) })
    for batch in batches {
      let sequences = batch.compactMap { byLine[$0.canonicalBytes()] }
      #expect(sequences.count == 2 && sequences[1] == sequences[0] + 1)
    }
    let records = batches.flatMap(\.self)
    #expect(Set(records.map(\.clock)).count == records.count)
    #expect(try await store.loadState(.vault).digest == Fixture.state(records, Fixture.v2).digest)
    #expect(try await store.loadState(.own).digest == Fixture.state(records, Fixture.v2).digest)
  }
}
