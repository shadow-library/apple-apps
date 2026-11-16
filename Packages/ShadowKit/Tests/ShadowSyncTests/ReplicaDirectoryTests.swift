import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowSync

private let writer = ReplicaFixture.replica("01936f3e-9999-7999-8999-999999999999")
private let first = ReplicaFixture.replica("01936f3e-1111-7111-8111-111111111111")
private let second = ReplicaFixture.replica("01936f3e-2222-7222-8222-222222222222")

private func clock(_ millis: Int64) throws -> HLCTimestamp {
  guard let clock = HLCTimestamp(wallMillis: millis, counter: 0, replica: writer) else { throw ReplicaFixtureFailure("clock out of range") }
  return clock
}

private func change(_ ref: EntityRef, _ fields: [String: JSONValue], at millis: Int64 = 1) throws -> ChangeRecord {
  ChangeRecord(id: UUID.v7(), clock: try clock(millis), schema: 3, entity: ref.kind, key: ref.key, kind: .set, fields: fields)
}

private func state(_ records: [ChangeRecord]) -> VaultState {
  var state = VaultState()
  for record in records { state.apply(record, registry: ReplicaFixture.registry) }
  return state
}

private func recipient(_ generator: inout SeededGenerator) throws -> RecoveryRecipient {
  guard let recipient = RecoveryRecipient(publicKey: generator.data(count: 32), sealingKey: generator.data(count: 32)) else { throw ReplicaFixtureFailure("recipient") }
  return recipient
}

private func directory(_ store: VaultStore) async throws -> ReplicaDirectory {
  ReplicaDirectory(state: try await store.loadState(.vault))
}

@Suite("ReplicaDirectory")
struct ReplicaDirectoryTests {
  @Test("should read what the write helpers wrote")
  func shouldReadHelpers() async throws {
    var generator = SeededGenerator(seed: 0xD1)
    let store = try ReplicaFixture.open()
    let recovery = try recipient(&generator)
    let key = KeyID(UUID.v7(using: &generator))
    try await store.write { transaction in
      try ReplicaDirectory.declareActive(first, name: "Phone", platform: "iOS", createdMillis: 10, in: &transaction)
      try ReplicaDirectory.declareActive(second, name: "Mac", platform: "macOS", createdMillis: 20, in: &transaction)
      try ReplicaDirectory.retire(first, successor: second, in: &transaction)
      try ReplicaDirectory.setRecovery(recovery, createdMillis: 30, in: &transaction)
    }
    let empty = try await directory(store)
    try await store.write { transaction in
      try empty.raiseSchemaFloor(to: 4, in: &transaction)
      try empty.raiseKeyFloor(to: key, in: &transaction)
    }
    let read = try await directory(store)
    #expect(read.replicas.map(\.replica) == [first, second])
    let retired = try #require(read.entry(for: first))
    #expect(retired.state == .retired && retired.successor == second && retired.name == "Phone" && retired.platform == "iOS" && retired.created == 10)
    #expect(read.entry(for: second)?.state == .active && read.entry(for: second)?.successor == nil)
    #expect(read.isRetired(first) && !read.isRetired(second) && !read.isRetired(writer))
    #expect(read.minimumSchema == 4 && read.keyFloor == key && read.recovery == recovery)
    #expect(empty.minimumSchema == nil && empty.keyFloor == nil)
  }

  @Test("should write nothing when the state already says the same")
  func shouldWriteNothingTwice() async throws {
    var generator = SeededGenerator(seed: 0xD2)
    let store = try ReplicaFixture.open()
    let recovery = try recipient(&generator)
    let write: @Sendable (inout WriteTransaction) throws -> Void = { transaction in
      try ReplicaDirectory.declareActive(first, name: "Phone", platform: "iOS", createdMillis: 10, in: &transaction)
      try ReplicaDirectory.retire(second, successor: first, in: &transaction)
      try ReplicaDirectory.setRecovery(recovery, createdMillis: 30, in: &transaction)
      try ReplicaDirectory.retireRecovery(recipientID: recovery.id, in: &transaction)
    }
    try await store.write(write)
    let count = try await ReplicaFixture.records(store).count
    try await store.write(write)
    try await store.write { transaction in try ReplicaDirectory.declareActive(first, name: "Phone", platform: "iOS", createdMillis: 99, in: &transaction) }
    #expect(try await ReplicaFixture.records(store).count == count)
    try await store.write { transaction in try ReplicaDirectory.declareActive(first, name: "Renamed", platform: "iOS", createdMillis: 99, in: &transaction) }
    let rename = try #require(try await ReplicaFixture.records(store).last)
    #expect(rename.fields.keys.sorted() == ["name"])
    #expect(try await directory(store).entry(for: first)?.created == 10)
  }

  @Test("should not raise a floor to a value at or below the current one")
  func shouldOnlyRaiseFloors() async throws {
    let store = try ReplicaFixture.open()
    let low = KeyID(UUID.v7(at: ReplicaFixture.start))
    let high = KeyID(UUID.v7(at: ReplicaFixture.start.addingTimeInterval(60)))
    let initial = try await directory(store)
    try await store.write { transaction in
      try initial.raiseSchemaFloor(to: 5, in: &transaction)
      try initial.raiseKeyFloor(to: high, in: &transaction)
    }
    let count = try await ReplicaFixture.records(store).count
    let raised = try await directory(store)
    try await store.write { transaction in
      try raised.raiseSchemaFloor(to: 5, in: &transaction)
      try raised.raiseSchemaFloor(to: 2, in: &transaction)
      try raised.raiseKeyFloor(to: high, in: &transaction)
      try raised.raiseKeyFloor(to: low, in: &transaction)
      try initial.raiseSchemaFloor(to: 5, in: &transaction)
    }
    #expect(try await ReplicaFixture.records(store).count == count)
    #expect(try await directory(store) == raised)
  }

  @Test("should refuse a negative schema floor and keep a floor whose highest member was purged")
  func shouldKeepPurgedFloor() async throws {
    let store = try ReplicaFixture.open()
    let key = KeyID(UUID.v7(at: ReplicaFixture.start))
    let initial = try await directory(store)
    let error = await #expect(throws: StoreError.self) { try await store.write { transaction in try initial.raiseSchemaFloor(to: -1, in: &transaction) } }
    #expect(error?.code == "store.invalid_change")
    try await store.write { transaction in
      try initial.raiseSchemaFloor(to: 3, in: &transaction)
      try initial.raiseSchemaFloor(to: 7, in: &transaction)
      try initial.raiseKeyFloor(to: key, in: &transaction)
    }
    try await store.write { transaction in
      _ = try transaction.purge(SyncKernelSchema.schemaFloorRef(7))
      _ = try transaction.purge(SyncKernelSchema.keyFloorRef(key))
    }
    let purged = try await directory(store)
    #expect(purged.minimumSchema == 7 && purged.keyFloor == key)
    try await store.write { transaction in try initial.raiseSchemaFloor(to: 7, in: &transaction) }
    #expect(try await directory(store) == purged)
  }

  @Test("should keep a retirement in every merge order, grouping and repetition")
  func shouldKeepRetirement() async throws {
    try await forAll(iterations: 60) { generator in
      let stores = [try ReplicaFixture.open(), try ReplicaFixture.open()]
      var retired = false
      for _ in 0..<generator.int(in: 1...8) {
        let store = generator.pick(from: stores)
        let name = generator.asciiString(maxLength: 6)
        let successor = generator.chance(0.5) ? second : nil
        switch generator.int(in: 0...2) {
        case 0:
          try await store.write { transaction in try ReplicaDirectory.declareActive(first, name: name, platform: "iOS", createdMillis: 1, in: &transaction) }
        case 1:
          retired = true
          try await store.write { transaction in try ReplicaDirectory.retire(first, successor: successor, in: &transaction) }
        default:
          try await store.write { transaction in _ = try transaction.set(EntityRef(kind: ReplicaFixture.note, key: ReplicaFixture.key("n1")), ["title": .string(name)]) }
        }
      }
      let left = try await ReplicaFixture.records(stores[0])
      let right = try await ReplicaFixture.records(stores[1])
      let all = left + right
      let sequence = generator.shuffled(all + all.filter { _ in generator.chance(0.3) })
      var merged = VaultState()
      var seenRetirement = false
      for record in sequence {
        merged.apply(record, registry: ReplicaFixture.registry)
        seenRetirement = seenRetirement || (record.entity == SyncKernelSchema.replicaKind && record.fields["state"] == .string("retired"))
        try #require(ReplicaDirectory(state: merged).isRetired(first) == seenRetirement)
      }
      try #require(seenRetirement == retired)
      let grouped = [state(left).merging(state(right)), state(right).merging(state(left)), state(right).merging(state(left)).merging(state(left))]
      for candidate in grouped { try #require(ReplicaDirectory(state: candidate) == ReplicaDirectory(state: merged)) }
    }
  }

  @Test("should only ever raise the floors, whatever the order and repetition of the records and the purges among them")
  func shouldOnlyRiseInAnyOrder() async throws {
    try await forAll(iterations: 40) { generator in
      let stores = [try ReplicaFixture.open(), try ReplicaFixture.open(), try ReplicaFixture.open()]
      let keys = (0..<5).map { index in KeyID(UUID.v7(at: ReplicaFixture.start.addingTimeInterval(Double(index)), using: &generator)) }
      var versions = [Int]()
      var raisedKeys = [KeyID]()
      for _ in 0..<generator.int(in: 1...10) {
        let store = generator.pick(from: stores)
        if !versions.isEmpty, generator.chance(0.3) {
          let refs = [SyncKernelSchema.schemaFloorRef(generator.pick(from: versions)), SyncKernelSchema.keyFloorRef(generator.pick(from: raisedKeys))]
          try await store.write { transaction in
            for ref in refs {
              if case .purged = try transaction.state(of: ref) { continue }
              _ = try transaction.purge(ref)
            }
          }
          continue
        }
        let version = generator.int(in: 0...6)
        let key = generator.pick(from: keys)
        versions.append(version)
        raisedKeys.append(key)
        let current = try await directory(store)
        try await store.write { transaction in
          try current.raiseSchemaFloor(to: version, in: &transaction)
          try current.raiseKeyFloor(to: key, in: &transaction)
        }
      }
      var all = [ChangeRecord]()
      for store in stores { all += try await ReplicaFixture.records(store) }
      var merged = VaultState()
      var previous = ReplicaDirectory(state: merged)
      for record in generator.shuffled(all + all.filter { _ in generator.chance(0.4) }) {
        merged.apply(record, registry: ReplicaFixture.registry)
        let next = ReplicaDirectory(state: merged)
        try #require((next.minimumSchema ?? -1) >= (previous.minimumSchema ?? -1))
        try #require(previous.keyFloor.map { floor in next.keyFloor.map { $0 >= floor } ?? false } ?? true)
        previous = next
      }
      try #require(previous.minimumSchema == versions.max())
      try #require(previous.keyFloor == raisedKeys.max())
    }
  }

  @Test("should skip malformed and foreign entries instead of trapping")
  func shouldSkipMalformed() throws {
    var generator = SeededGenerator(seed: 0xD3)
    let good = try recipient(&generator)
    let other = try recipient(&generator)
    let key = KeyID(UUID.v7(using: &generator))
    let replicaKind = SyncKernelSchema.replicaKind
    let encoded = { (recipient: RecoveryRecipient) -> [String: JSONValue] in
      ["public_key": .string(recipient.publicKey.base64EncodedString()), "sealing_key": .string(recipient.sealingKey.base64EncodedString()), "state": "active", "created": 5]
    }
    let records = [
      try change(SyncKernelSchema.replicaRef(first), ["state": "active", "name": .int(3), "successor": "not-a-replica", "created": "soon"]),
      try change(EntityRef(kind: replicaKind, key: ReplicaFixture.key("not-a-replica")), ["state": "active"]),
      try change(SyncKernelSchema.replicaRef(second), ["name": "no state"]),
      try change(SyncKernelSchema.replicaRef(writer), ["state": "paused"]),
      try change(EntityRef(kind: SyncKernelSchema.schemaFloorKind, key: ReplicaFixture.key("v-09")), ["version": 9]),
      try change(EntityRef(kind: SyncKernelSchema.schemaFloorKind, key: ReplicaFixture.key("w-8")), ["version": 8]),
      try change(EntityRef(kind: SyncKernelSchema.schemaFloorKind, key: ReplicaFixture.key("v--1")), ["version": -1]),
      try change(SyncKernelSchema.schemaFloorRef(2), ["version": 80]),
      try change(SyncKernelSchema.keyFloorRef(key), ["key": "not-a-key"]),
      try change(EntityRef(kind: SyncKernelSchema.keyFloorKind, key: ReplicaFixture.key("k")), ["key": .string(KeyID(UUID.v7(using: &generator)).description)]),
      try change(SyncKernelSchema.recoveryRef(other.id), encoded(good)),
      try change(SyncKernelSchema.recoveryRef(other.id), ["public_key": "%%%", "sealing_key": "AAAA", "state": "active", "created": 9]),
      try change(EntityRef(kind: SyncKernelSchema.recoveryKind, key: ReplicaFixture.key("r")), ["state": "active"]),
      try change(EntityRef(kind: ReplicaFixture.kind("_unknown_kernel"), key: ReplicaFixture.key("x")), ["state": "active"]),
      ChangeRecord(id: UUID.v7(), clock: try clock(2), schema: 3, entity: replicaKind, key: SyncKernelSchema.replicaRef(second).key, kind: .purge, fields: [:]),
    ]
    let read = ReplicaDirectory(state: state(records))
    let entry = try #require(read.entry(for: first))
    #expect(read.replicas.map(\.replica) == [first])
    #expect(entry.state == .active && entry.name == nil && entry.successor == nil && entry.created == nil)
    #expect(read.minimumSchema == 2)
    #expect(read.keyFloor == key)
    #expect(read.recovery == nil)
  }

  @Test("should choose the active recovery recipient with the latest creation, then the highest id, in any order")
  func shouldChooseRecoveryDeterministically() async throws {
    try await forAll(iterations: 30) { generator in
      let recipients = try (0..<4).map { _ in try recipient(&generator) }
      let created = recipients.map { _ in Int64(generator.int(in: 1...3)) }
      let retiredIDs = Set(recipients.filter { _ in generator.chance(0.3) }.map(\.id))
      let store = try ReplicaFixture.open()
      for (recipient, millis) in zip(recipients, created) {
        try await store.write { transaction in try ReplicaDirectory.setRecovery(recipient, createdMillis: millis, in: &transaction) }
      }
      for id in retiredIDs { try await store.write { transaction in try ReplicaDirectory.retireRecovery(recipientID: id, in: &transaction) } }
      let candidates = zip(recipients, created).filter { !retiredIDs.contains($0.0.id) }
      let expected = candidates.max { ($0.1, $0.0.id) < ($1.1, $1.0.id) }?.0
      let records = try await ReplicaFixture.records(store)
      for _ in 0..<3 { try #require(ReplicaDirectory(state: state(generator.shuffled(records))).recovery == expected) }
      try #require(try await directory(store).recovery == expected)
    }
  }
}
