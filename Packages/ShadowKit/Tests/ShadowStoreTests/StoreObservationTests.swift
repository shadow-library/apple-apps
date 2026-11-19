import Foundation
import GRDB
import ShadowCore
import ShadowTestSupport
import Synchronization
import Testing

@testable import ShadowStore

private let note = EntityRef(kind: Fixture.note, key: Fixture.key("k1"))
private let other = EntityRef(kind: Fixture.note, key: Fixture.key("k2"))
private let draft = EntityRef(kind: Fixture.draft, key: Fixture.key("d1"))

private struct Rollback: Error {}

private final class Reads: Sendable {
  private let count = Mutex(0)

  var value: Int { count.withLock { $0 } }

  func bump() { count.withLock { $0 += 1 } }
}

private func notes(_ store: VaultStore, reads: Reads = Reads()) -> AsyncThrowingStream<Int, any Error> {
  store.observeReads { transaction in
    reads.bump()
    return try transaction.states(ofKind: Fixture.note, scope: .vault).count
  }
}

@Suite("VaultStore observation")
struct StoreObservationTests {
  @Test("should emit the current value and then each change committed by a write")
  func shouldEmitAfterAWrite() async throws {
    let store = try StoreFixture.open()
    var iterator = notes(store).makeAsyncIterator()
    #expect(try await iterator.next() == 0)
    _ = try await store.write { transaction in try transaction.set(note, ["title": "a"]) }
    #expect(try await iterator.next() == 1)
  }

  @Test("should skip a commit that leaves the value unchanged")
  func shouldSkipUnchangedValues() async throws {
    let store = try StoreFixture.open()
    var iterator = notes(store).makeAsyncIterator()
    #expect(try await iterator.next() == 0)
    _ = try await store.write { transaction in try transaction.set(note, ["title": "a"]) }
    _ = try await store.write { transaction in try transaction.set(note, ["title": "b"]) }
    _ = try await store.write { transaction in try transaction.set(other, ["title": "c"]) }
    var latest = 0
    while latest < 2, let next = try await iterator.next() { latest = next }
    #expect(latest == 2)
  }

  @Test("should emit after a remote apply")
  func shouldEmitAfterARemoteApply() async throws {
    let store = try StoreFixture.open()
    var iterator = notes(store).makeAsyncIterator()
    #expect(try await iterator.next() == 0)
    let change = Fixture.change(.set, other.kind, other.key, clock: Fixture.clock(1, replica: 1), fields: ["title": "remote"])
    _ = try await store.applyRemote([change.canonicalBytes()])
    #expect(try await iterator.next() == 1)
  }

  @Test("should not read again after a rolled back write")
  func shouldIgnoreARollback() async throws {
    let store = try StoreFixture.open()
    let reads = Reads()
    let consumer = Task { for try await _ in notes(store, reads: reads) {} }
    try await settle { reads.value == 1 }
    await #expect(throws: (any Error).self) {
      _ = try await store.write { transaction in
        _ = try transaction.set(note, ["title": "a"])
        throw Rollback()
      }
    }
    try await Task.sleep(for: .milliseconds(300))
    #expect(reads.value == 1)
    consumer.cancel()
  }

  @Test("should stop observing once the consumer is cancelled")
  func shouldRemoveTheObserverOnCancel() async throws {
    let store = try StoreFixture.open()
    let reads = Reads()
    let consumer = Task { for try await _ in notes(store, reads: reads) {} }
    try await settle { reads.value == 1 }
    consumer.cancel()
    try await Task.sleep(for: .milliseconds(300))
    _ = try await store.write { transaction in try transaction.set(note, ["title": "a"]) }
    try await Task.sleep(for: .milliseconds(300))
    #expect(reads.value == 1)
  }

  @Test("should return from observing and cancelling while a write is still running")
  func shouldNotBlockTheCallerOnTheWriter() async throws {
    let store = try StoreFixture.open()
    let reads = Reads()
    let consumer = Task { for try await _ in notes(store, reads: reads) {} }
    try await settle { reads.value == 1 }
    let release = DispatchSemaphore(value: 0)
    let entered = Reads()
    let writing = Task {
      try await store.write { transaction -> Bool in
        entered.bump()
        let released = release.wait(timeout: .now() + 60) == .success
        _ = try transaction.set(note, ["title": "slow"])
        return released
      }
    }
    try await settle { entered.value == 1 }
    _ = notes(store)
    consumer.cancel()
    release.signal()
    #expect(try await writing.value)
  }

  @Test("should load a head without the retained history")
  func shouldNameOnlyTheHeadRevision() async throws {
    let store = try StoreFixture.open(Fixture.v2)
    for index in 0..<20 { _ = try await store.write { transaction in try transaction.revise(draft, body: .string("body \(index)")) } }
    let (full, head) = try await store.read { transaction in (try transaction.state(of: draft), try transaction.stateNamingRevisions(of: draft)) }
    guard case .revisioned(let all)? = full, case .revisioned(let named)? = head else {
      Issue.record("the draft should be revisioned")
      return
    }
    #expect(all.revisions.count > 1)
    #expect(named.revisions.count == 1)
    #expect(named.headRevision == all.headRevision)
    #expect(named.head == all.head)
  }

  private func settle(_ condition: @Sendable () -> Bool) async throws {
    for _ in 0..<2_400 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("the condition never held")
  }
}
