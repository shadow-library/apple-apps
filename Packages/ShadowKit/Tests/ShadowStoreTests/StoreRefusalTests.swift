import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowStore

private let note = EntityRef(kind: Fixture.note, key: Fixture.key("k1"))
private let purgedNote = EntityRef(kind: Fixture.note, key: Fixture.key("k2"))
private let message = EntityRef(kind: Fixture.message, key: Fixture.key("m1"))
private let draft = EntityRef(kind: Fixture.draft, key: Fixture.key("d1"))
private let purgedDraft = EntityRef(kind: Fixture.draft, key: Fixture.key("d2"))
private let tag = EntityRef(kind: Fixture.tag, key: Fixture.key("t1"))

private struct Refusal: Sendable, CustomTestStringConvertible {
  let name: String
  let code: String
  let attempt: @Sendable (inout WriteTransaction, String) throws -> Void

  var testDescription: String { name }
}

private let refusals: [Refusal] = [
  Refusal(name: "set on an undeclared kind", code: "store.invalid_change") { transaction, _ in _ = try transaction.set(tag, ["label": "x"]) },
  Refusal(name: "purge of an undeclared kind", code: "store.invalid_change") { transaction, _ in _ = try transaction.purge(tag) },
  Refusal(name: "set of an undeclared field", code: "store.invalid_change") { transaction, _ in _ = try transaction.set(note, ["title": "t", "pinned": true]) },
  Refusal(name: "set of a value outside the monotone order", code: "store.invalid_change") { transaction, _ in _ = try transaction.set(note, ["status": "archived"]) },
  Refusal(name: "set of a field with no value", code: "store.invalid_change") { transaction, _ in _ = try transaction.set(note, [:]) },
  Refusal(name: "set of head", code: "store.invalid_change") { transaction, revision in _ = try transaction.set(draft, ["head": .string(revision)]) },
  Refusal(name: "set of a mark", code: "store.invalid_change") { transaction, revision in _ = try transaction.set(draft, ["approved": .string(revision)]) },
  Refusal(name: "set on an appended kind", code: "store.invalid_change") { transaction, _ in _ = try transaction.set(message, ["text": "x"]) },
  Refusal(name: "append on a record kind", code: "store.invalid_change") { transaction, _ in _ = try transaction.append(note, item: ["text": "x"]) },
  Refusal(name: "append over an existing item", code: "store.invalid_change") { transaction, _ in _ = try transaction.append(message, item: ["text": "y"]) },
  Refusal(name: "revise on a record kind", code: "store.invalid_change") { transaction, _ in _ = try transaction.revise(note, body: "b") },
  Refusal(name: "revise with an undeclared mark", code: "store.invalid_change") { transaction, _ in _ = try transaction.revise(draft, body: "b", marks: ["reviewed"]) },
  Refusal(name: "revise with a repeated mark", code: "store.invalid_change") { transaction, _ in _ = try transaction.revise(draft, body: "b", marks: ["approved", "approved"]) },
  Refusal(name: "revise with an unknown parent", code: "store.unknown_revision") { transaction, _ in _ = try transaction.revise(draft, body: "b", parent: .revision("v:00")) },
  Refusal(name: "reassert of an unknown revision", code: "store.unknown_revision") { transaction, _ in _ = try transaction.reassert(draft, revision: "v:00", head: true) },
  Refusal(name: "reassert of another entity's revision", code: "store.unknown_revision") { transaction, revision in
    _ = try transaction.reassert(EntityRef(kind: Fixture.outline, key: draft.key), revision: revision, head: true)
  },
  Refusal(name: "set on a purged entity", code: "store.entity_purged") { transaction, _ in _ = try transaction.set(purgedNote, ["title": "t"]) },
  Refusal(name: "purge of a purged entity", code: "store.entity_purged") { transaction, _ in _ = try transaction.purge(purgedNote) },
  Refusal(name: "revise on a purged entity", code: "store.entity_purged") { transaction, _ in _ = try transaction.revise(purgedDraft, body: "b") },
  Refusal(name: "reassert on a purged entity", code: "store.entity_purged") { transaction, revision in _ = try transaction.reassert(purgedDraft, revision: revision, head: true) },
  Refusal(name: "a change above the size limit", code: "store.change_too_large") { transaction, _ in
    _ = try transaction.set(note, ["title": .string(String(repeating: "x", count: VaultStore.maximumChangeBytes))])
  },
]

private struct Snapshot: Equatable {
  let vault: String
  let own: String
  let pending: [LoggedChange]

  init(_ store: VaultStore) async throws {
    vault = try await store.loadState(.vault).digest
    own = try await store.loadState(.own).digest
    pending = try await store.allPending
  }
}

private func seeded() async throws -> (VaultStore, String) {
  let store = try StoreFixture.open(Fixture.v1)
  let revision = try await store.write { transaction in
    _ = try transaction.set(note, ["title": "t"])
    _ = try transaction.append(message, item: ["text": "x"])
    let (_, revision) = try transaction.revise(draft, body: "b")
    _ = try transaction.revise(purgedDraft, body: "b")
    _ = try transaction.set(purgedNote, ["title": "t"])
    _ = try transaction.purge(purgedNote)
    _ = try transaction.purge(purgedDraft)
    return revision
  }
  return (store, revision)
}

private struct Rollback: Error {}

@Suite("VaultStore refusals")
struct StoreRefusalTests {
  @Test("should refuse an invalid local write and leave state, log, sequence and scopes unchanged", arguments: refusals)
  fileprivate func shouldRefuse(_ refusal: Refusal) async throws {
    let (store, revision) = try await seeded()
    let before = try await Snapshot(store)
    let (code, changes) = try await store.write { transaction in
      do {
        try refusal.attempt(&transaction, revision)
        return (String?.none, transaction.changes)
      } catch {
        return ((error as? StoreError)?.code, transaction.changes)
      }
    }
    #expect(code == refusal.code)
    #expect(changes.isEmpty)
    #expect(try await Snapshot(store) == before)
    let next = try await store.write { transaction in try transaction.set(note, ["title": "after"]) }
    #expect(try await store.allPending.last == LoggedChange(sequence: Int64(before.pending.count) + 1, line: next.canonicalBytes()))
  }

  @Test("should report the refused write's error from the transaction and keep nothing")
  func shouldRefuseWithoutCatching() async throws {
    let (store, _) = try await seeded()
    let before = try await Snapshot(store)
    await #expect(throws: StoreError.self) {
      try await store.write { transaction in
        _ = try transaction.set(note, ["title": "kept only if the transaction commits"])
        _ = try transaction.set(tag, ["label": "x"])
      }
    }
    #expect(try await Snapshot(store) == before)
  }

  @Test("should roll back every write of a body that throws after several successful writes")
  func shouldRollBackThrowingBody() async throws {
    let (store, _) = try await seeded()
    let before = try await Snapshot(store)
    do {
      try await store.write { transaction in
        _ = try transaction.set(note, ["title": "lost"])
        _ = try transaction.append(EntityRef(kind: Fixture.message, key: Fixture.key("m3")), item: ["text": "lost"])
        _ = try transaction.revise(draft, body: "lost")
        _ = try transaction.purge(note)
        throw Rollback()
      }
      Issue.record("the write should have thrown")
    } catch StoreError.aborted(let underlying) {
      #expect(underlying is Rollback)
    }
    #expect(try await Snapshot(store) == before)
    let next = try await store.write { transaction in try transaction.set(note, ["title": "next"]) }
    #expect(try await store.allPending.last == LoggedChange(sequence: Int64(before.pending.count) + 1, line: next.canonicalBytes()))
  }
}
