import Foundation
import OSLog
import ShadowCore
import ShadowStore
import ShadowSync

public enum RecoveryStatus: Sendable, Equatable {
  case notSetUp
  /// `recipientID` names the phrase without revealing it; a device that set up another phrase at the same time sees its own id replaced.
  case active(recipientID: String, createdMillis: Int64)
}

public struct RecoverySetupOutcome: Sendable, Equatable {
  public let recipientID: String
  public let sealed: [KeyID]
  public let retiredRecipients: [String]
  /// False when a copy of a key that arrived during the setup, or the removal of the replaced phrase's copies, failed; `reconcile()` finishes them.
  public let isComplete: Bool
}

public struct RecoveryReconciliation: Sendable, Equatable {
  public let sealed: [KeyID]
  public let retiredRecipients: [String]
  public let deleted: [ObjectKey]

  public static let unchanged = RecoveryReconciliation(sealed: [], retiredRecipients: [], deleted: [])
}

/// Sets up the recovery phrase of one vault and keeps its sealed copies in step with the ring through `RecoveryCopies`. Copies are put before the
/// recipient is recorded, so any device that sees the record finds every key the setting-up device held. Calls run one at a time; keep one per vault,
/// as `SyncAttachment.recoverySetup(store:)` does.
public actor RecoverySetup {
  private static let logger = Logger(category: "RecoverySetup")
  private static let maximumSealPasses = 3

  public nonisolated let vault: VaultID
  private let store: VaultStore
  private let ring: KeyRing
  private let copies: RecoveryCopies
  private let wallClock: @Sendable () -> Date
  private var isBusy = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  public init(store: VaultStore, provider: any StorageProvider, ring: KeyRing, wallClock: @escaping @Sendable () -> Date = { Date() }) {
    vault = ring.vault
    self.store = store
    self.ring = ring
    copies = RecoveryCopies(store: store, provider: provider, ring: ring)
    self.wallClock = wallClock
  }

  public func status() async throws(RecoveryError) -> RecoveryStatus {
    let directory = try await readDirectory()
    guard let recipient = directory.recovery, let entry = directory.recoveries.first(where: { $0.recipientID == recipient.id }) else { return .notSetUp }
    return .active(recipientID: recipient.id, createdMillis: entry.created)
  }

  public nonisolated func begin() -> PendingRecoveryPhrase {
    PendingRecoveryPhrase()
  }

  /// Records `pending` as the vault's recovery phrase once `confirmation` holds the words at its confirmation positions. Every other recorded phrase
  /// is retired and its copies of the ring's keys are deleted. A failure before the record leaves `pending` open, so the same phrase can be committed again.
  public func commit(_ pending: PendingRecoveryPhrase, confirming confirmation: [Int: String]) async throws(RecoveryError) -> RecoverySetupOutcome {
    await acquire()
    defer { release() }
    let phrase = try pending.confirmedPhrase(confirmation)
    try refreshRing()
    guard !ring.keyIDs.isEmpty else { throw .noRingKey }
    let recipient = RecoveryKey(secret: phrase.secret, vault: vault).recipient
    var sealed: [KeyID]
    do {
      sealed = try await copies.seal(ring.keyIDs, to: recipient)
    } catch {
      throw RecoveryError(error)
    }
    let millis = Int64((wallClock().timeIntervalSince1970 * 1000).rounded(.down))
    let retired: [String]
    do {
      retired = try await store.write { transaction in
        let directory = try ReplicaDirectory.read(in: transaction)
        try ReplicaDirectory.setRecovery(recipient, createdMillis: millis, in: &transaction)
        let others = directory.recoveries.filter { $0.state == .active && $0.recipientID != recipient.id }.map(\.recipientID)
        for other in others { try ReplicaDirectory.retireRecovery(recipientID: other, in: &transaction) }
        return others
      }
    } catch {
      throw RecoveryError(error)
    }
    pending.markRecorded()
    Self.logger.info("Recorded a recovery phrase recipient=\(recipient.id, privacy: .public) keys=\(sealed.count, privacy: .public)")
    var isComplete = true
    do {
      sealed += try await sealArrivals(to: recipient)
    } catch {
      Self.logger.error("Could not seal a key that arrived during the setup error=\(error.code, privacy: .public)")
      isComplete = false
    }
    do {
      _ = try await copies.deleteInactive()
    } catch {
      Self.logger.error("Could not delete the replaced phrase's copies error=\(error.code, privacy: .public)")
      isComplete = false
    }
    return RecoverySetupOutcome(recipientID: recipient.id, sealed: Array(Set(sealed)).sorted(), retiredRecipients: retired.sorted(), isComplete: isComplete)
  }

  /// Call when a key joins the ring and after a download brings recovery records: retires a recipient a concurrent setup superseded, seals the ring
  /// keys this device has not sealed to the active recipient, and deletes the copies of ring keys under every other recorded recipient.
  public func reconcile() async throws(RecoveryError) -> RecoveryReconciliation {
    await acquire()
    defer { release() }
    try refreshRing()
    let directory = try await readDirectory()
    let superseded = directory.recoveries.filter { $0.state == .active && $0.recipientID != directory.recovery?.id }.map(\.recipientID)
    if !superseded.isEmpty {
      do {
        try await store.write { transaction in
          for recipientID in superseded { try ReplicaDirectory.retireRecovery(recipientID: recipientID, in: &transaction) }
        }
      } catch {
        throw RecoveryError(error)
      }
    }
    let sealed: [KeyID]
    let deleted: [ObjectKey]
    do {
      sealed = try await copies.sealToActive()
      deleted = try await copies.deleteInactive()
    } catch {
      throw RecoveryError(error)
    }
    if !sealed.isEmpty || !deleted.isEmpty || !superseded.isEmpty {
      Self.logger.info(
        "Reconciled recovery copies sealed=\(sealed.count, privacy: .public) deleted=\(deleted.count, privacy: .public) retired=\(superseded.count, privacy: .public)")
    }
    return RecoveryReconciliation(sealed: sealed, retiredRecipients: superseded.sorted(), deleted: deleted)
  }

  private func sealArrivals(to recipient: RecoveryRecipient) async throws(RecoveryError) -> [KeyID] {
    var added: [KeyID] = []
    for _ in 0..<Self.maximumSealPasses {
      try refreshRing()
      let sealed: [KeyID]
      do {
        sealed = try await copies.seal(ring.keyIDs, to: recipient)
      } catch {
        throw RecoveryError(error)
      }
      guard !sealed.isEmpty else { break }
      added += sealed
    }
    return added
  }

  private func refreshRing() throws(RecoveryError) {
    do {
      try ring.refresh()
    } catch {
      throw RecoveryError(error)
    }
  }

  private func readDirectory() async throws(RecoveryError) -> ReplicaDirectory {
    do {
      return try await store.read { transaction in try ReplicaDirectory.read(in: transaction) }
    } catch {
      throw RecoveryError(error)
    }
  }

  private func acquire() async {
    while isBusy { await withCheckedContinuation { waiters.append($0) } }
    isBusy = true
  }

  private func release() {
    isBusy = false
    guard !waiters.isEmpty else { return }
    waiters.removeFirst().resume()
  }
}
