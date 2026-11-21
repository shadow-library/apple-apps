import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowSync

@Suite("VaultMoveNotice", TestTimeLimit.quick)
struct VaultMoveNoticeTests {
  private static let key: VaultKey = {
    guard let key = VaultKey(id: SyncFixture.keyID(1), rawBytes: Data(repeating: 1, count: 32)) else { preconditionFailure("fixture key is valid") }
    return key
  }()

  private static func notice() throws -> VaultMoveNotice {
    let from = ReplicaID(UUID.v7())
    let clock = try #require(HLCTimestamp(wallMillis: 1_700_000_000_000, counter: 2, replica: from))
    return VaultMoveNotice(
      from: from, to: ReplicaID(UUID.v7()), base: try #require(BaseReference(upTo: 0, tag: ContentTag.make(for: Data(), key: key), parts: 3)),
      frontier: [from: clock], target: ["kind": "localFolder", "settings": ["path": "/tmp/vault"]], movedMillis: 1_700_000_000_123)
  }

  @Test
  func shouldOpenWhatItSealsForTheSameVault() throws {
    let notice = try Self.notice()
    let sealed = try VaultMoveNoticeCodec.seal(notice, vault: SyncFixture.vault, with: Self.key)
    #expect(try VaultMoveNoticeCodec.open(sealed, vault: SyncFixture.vault) { $0 == Self.key.id ? Self.key : nil } == notice)
  }

  @Test
  func shouldRefuseANoticeOfAnotherVaultOrWithoutTheKey() throws {
    let sealed = try VaultMoveNoticeCodec.seal(try Self.notice(), vault: SyncFixture.vault, with: Self.key)
    let other = try #require(VaultID("other-vault"))
    #expect(throws: ReplicaFileError.self) { try VaultMoveNoticeCodec.open(sealed, vault: other) { _ in Self.key } }
    #expect(throws: ReplicaFileError.self) { try VaultMoveNoticeCodec.open(sealed, vault: SyncFixture.vault) { _ in nil } }
  }

  @Test
  func shouldRefuseATamperedNotice() throws {
    var sealed = try VaultMoveNoticeCodec.seal(try Self.notice(), vault: SyncFixture.vault, with: Self.key)
    sealed[sealed.index(before: sealed.endIndex)] ^= 0x01
    #expect(throws: ReplicaFileError.self) { try VaultMoveNoticeCodec.open(sealed, vault: SyncFixture.vault) { _ in Self.key } }
  }

  @Test
  func shouldRefuseAFileSealedForAnotherPath() throws {
    let payload = CanonicalJSON.encode(["format": 1, "kind": "moved"])
    let sealed = try VaultFile.seal(payload, path: VaultPath.hint.rawValue, vault: SyncFixture.vault, key: Self.key)
    #expect(throws: ReplicaFileError.self) { try VaultMoveNoticeCodec.open(sealed, vault: SyncFixture.vault) { _ in Self.key } }
  }

  @Test
  func shouldClassifyTheNoticeBesideTheReplicaPrefixes() {
    #expect(VaultPath.classify(VaultPath.moveNotice) == .moveNotice)
    #expect(VaultPath.moveNotice.rawValue.hasPrefix(VaultPath.replicasPrefix))
  }

  @Test
  func shouldRequeueOnlyRecordsAboveTheFrontierOfTheirWriter() async throws {
    let store = try SyncFixture.open()
    let refs = (0..<3).map { EntityRef(kind: SyncFixture.note, key: ReplicaFixture.key("n\($0)")) }
    var clocks: [HLCTimestamp] = []
    for ref in refs {
      clocks.append(try await store.write { transaction in try transaction.set(ref, ["title": "t"]).clock })
    }
    try await store.dropChanges(through: 3)
    let replica = store.replica
    #expect(try await store.requeue(above: [replica: clocks[0]], admitting: { _ in true }) == 2)
    #expect(try await store.requeue(above: [:], admitting: { $0.kind != SyncFixture.note }) == 0)
    #expect(try await store.pendingChanges(limit: 10).count == 2)
  }

  @Test
  func shouldRelayInClockOrderLeaveOutPendingRecordsAndKeepRelayedClocksThroughARebuild() async throws {
    let store = try SyncFixture.open()
    let other = ReplicaID(UUID.v7())
    let remote = try (0..<3).map { index in
      let clock = try #require(HLCTimestamp(wallMillis: 1_700_000_000_000 - Int64(index) * 1_000, counter: 0, replica: other))
      return ChangeRecord(
        id: UUID.v7(), clock: clock, schema: 3, entity: SyncFixture.note, key: ReplicaFixture.key("r\(index)"), kind: .set, fields: ["title": "remote"])
    }
    _ = try await store.applyRemote(remote.map { $0.canonicalBytes() })
    let local = try await store.write { transaction in try transaction.set(EntityRef(kind: SyncFixture.note, key: ReplicaFixture.key("l")), ["title": "local"]) }
    #expect(try await store.requeue(above: [:], admitting: { _ in true }) == 3)
    let lines = try await store.pendingChanges(limit: 10).map(\.line)
    #expect(lines.first == local.canonicalBytes())
    let relayed = try lines.dropFirst().map { try ChangeRecord(json: try CanonicalJSON.decode($0)) }
    #expect(relayed.map(\.clock) == remote.map(\.clock).sorted())
    #expect(try await store.pendingClocks() == [local.clock])
    try await store.remint(to: ReplicaID(UUID.v7()), mode: .rebuild)
    let rebuilt = try await store.pendingChanges(limit: 10).map { try ChangeRecord(json: try CanonicalJSON.decode($0.line)) }
    #expect(rebuilt.count == 4)
    #expect(rebuilt.first?.clock != local.clock)
    #expect(Array(rebuilt.dropFirst()) == relayed)
  }
}
