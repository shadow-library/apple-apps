import Foundation
import ShadowCore
import Testing

@testable import ShadowSync

@Suite("VaultStartupState")
struct VaultStartupStateTests {
  struct Row: Sendable, CustomTestStringConvertible {
    let name: String
    let observation: VaultObservation
    let expected: VaultStartupState
    let canWrite: Bool

    var testDescription: String { name }
  }

  private static let vault = fixture(VaultID("vault-one"))
  private static let held = KeyID(fixture(UUID(uuidString: "01930000-0000-7000-8000-000000000001")))
  private static let missing = KeyID(fixture(UUID(uuidString: "01940000-0000-7000-8000-000000000002")))
  private static let writerA = ReplicaID(fixture(UUID(uuidString: "01930000-0000-7000-8000-00000000000a")))
  private static let writerB = ReplicaID(fixture(UUID(uuidString: "01930000-0000-7000-8000-00000000000b")))

  private static func fixture<T>(_ value: T?) -> T {
    guard let value else { preconditionFailure("invalid fixture literal") }
    return value
  }

  private static func observe(
    _ storage: StorageAvailability, vault: VaultID? = vault, held: Set<KeyID> = [], named: [KeyID: Set<ReplicaID>] = [:]
  ) -> VaultObservation {
    VaultObservation(storage: storage, vault: vault, heldKeys: held, namedKeys: named)
  }

  static let rows: [Row] = [
    Row(name: "no storage", observation: observe(.unavailable, vault: nil), expected: .noStorageAccount, canWrite: false),
    Row(name: "no vault", observation: observe(.available, vault: nil), expected: .noVault, canWrite: false),
    Row(name: "no vault, keys held", observation: observe(.available, vault: nil, held: [held]), expected: .noVault, canWrite: false),
    Row(name: "empty ring, empty vault", observation: observe(.available), expected: .awaitingKey(vault: vault), canWrite: false),
    Row(
      name: "empty ring, named keys", observation: observe(.available, named: [missing: [writerA]]), expected: .awaitingKey(vault: vault), canWrite: false),
    Row(
      name: "one named key missing", observation: observe(.available, held: [held], named: [held: [writerA], missing: [writerA, writerB]]),
      expected: .partiallyReadable(vault: vault, missing: [missing: [writerA, writerB]]), canWrite: true),
    Row(
      name: "only unheld keys named", observation: observe(.available, held: [held], named: [missing: [writerB]]),
      expected: .partiallyReadable(vault: vault, missing: [missing: [writerB]]), canWrite: true),
    Row(name: "ring, no files", observation: observe(.available, held: [held]), expected: .ready(vault: vault), canWrite: true),
    Row(
      name: "every named key held", observation: observe(.available, held: [held, missing], named: [held: [writerA], missing: [writerB]]),
      expected: .ready(vault: vault), canWrite: true),
  ]

  @Test("should map each observation to its state", arguments: rows)
  func shouldMapObservation(row: Row) {
    let state = VaultStartupState(row.observation)
    #expect(state == row.expected)
    #expect(state.canWrite == row.canWrite)
  }

  @Test("should apply the rules in order: storage, then vault, then an empty ring, then missing keys")
  func shouldApplyRulesInOrder() {
    let everything = Self.observe(.unavailable, held: [], named: [Self.missing: [Self.writerA]])
    #expect(VaultStartupState(everything) == .noStorageAccount)
    var observation = everything
    observation.storage = .available
    observation.vault = nil
    #expect(VaultStartupState(observation) == .noVault)
    observation.vault = Self.vault
    #expect(VaultStartupState(observation) == .awaitingKey(vault: Self.vault))
    observation.heldKeys = [Self.held]
    #expect(VaultStartupState(observation) == .partiallyReadable(vault: Self.vault, missing: [Self.missing: [Self.writerA]]))
    observation.heldKeys.insert(Self.missing)
    #expect(VaultStartupState(observation) == .ready(vault: Self.vault))
    observation.storage = .unavailable
    #expect(VaultStartupState(observation) == .noStorageAccount)
  }
}
