import Foundation
import OSLog
import ShadowCore
import ShadowStore
import ShadowSync

/// Whether the attachment a `SyncKeyAccess` was opened for is still the runtime's; `gone` carries the runtime's phase now.
enum SyncKeyAttachmentStanding: Sendable, Equatable {
  case current
  case gone(SyncPhase?)
}

/// The key services of the attached vault for the screens that bring a key to this device or give it up: phrase recovery, the QR exchange and the
/// recovery phrase. It works while the vault awaits its key, when no engine runs yet. Every call that reaches storage first checks that the runtime
/// still attaches the vault where this access was opened, so one held across a disconnect, a move or an account change reaches nothing. A key that
/// joins the ring makes the runtime evaluate again, so the phase leaves `awaitingKey` without waiting for the next key check.
public struct SyncKeyAccess: Sendable {
  private static let logger = Logger(category: "SyncKeyAccess")

  public let vault: VaultID
  private let attachment: SyncAttachment
  private let store: VaultStore
  private let wallClock: @Sendable () -> Date
  private let standing: @Sendable () async -> SyncKeyAttachmentStanding
  private let imported: @Sendable () async -> Void

  init(
    attachment: SyncAttachment, store: VaultStore, wallClock: @escaping @Sendable () -> Date, standing: @escaping @Sendable () async -> SyncKeyAttachmentStanding,
    imported: @escaping @Sendable () async -> Void
  ) {
    vault = attachment.vault
    self.attachment = attachment
    self.store = store
    self.wallClock = wallClock
    self.standing = standing
    self.imported = imported
  }

  /// False while the ring holds no key of the vault: such a device can only ask for one, by phrase or by exchange, and cannot set up a phrase.
  public var holdsKey: Bool { !attachment.ring.keyIDs.isEmpty }

  public func recoveryStatus() async throws(RecoveryError) -> RecoveryStatus {
    if case .gone(let phase) = await standing() { throw .unavailable(phase) }
    return try await recoverySetup.status()
  }

  /// A new phrase to show once; record it with `commitRecoveryPhrase(_:confirming:)`.
  public func beginRecoveryPhrase() -> PendingRecoveryPhrase {
    recoverySetup.begin()
  }

  /// See `RecoverySetup.commit(_:confirming:)`; throws `noRingKey` while this device holds no key.
  public func commitRecoveryPhrase(_ pending: PendingRecoveryPhrase, confirming confirmation: [Int: String]) async throws(RecoveryError) -> RecoverySetupOutcome {
    if case .gone(let phase) = await standing() { throw .unavailable(phase) }
    return try await recoverySetup.commit(pending, confirming: confirmation)
  }

  public func recover(with phrase: RecoveryPhrase) async throws(RecoveryError) -> KeyImport {
    if case .gone(let phase) = await standing() { throw .unavailable(phase) }
    let result = try await attachment.phraseRecovery.recover(phrase)
    if result.holdsAnyKey { await imported() }
    return result
  }

  /// The requesting side of the exchange: show `payload` as a QR code, scan the response, compare the codes.
  public func requestKeys() -> SyncKeyRequest {
    SyncKeyRequest(requester: attachment.keyExchange.request(), standing: standing, imported: imported)
  }

  /// The holding side: seals the ring to the scanned request, the keys at or above the vault's key floor first.
  public func respond(to payload: String) async throws(KeyExchangeError) -> KeyExchangeResponder {
    if case .gone(let phase) = await standing() { throw .unavailable(phase) }
    let floor = await keyFloor()
    return try attachment.keyExchange.respond(to: payload, floor: floor)
  }

  /// The attachment's one `RecoverySetup`, shared with the runtime's reconciliation so their calls run one at a time.
  private var recoverySetup: RecoverySetup {
    attachment.recoverySetup(store: store, wallClock: wallClock)
  }

  private func keyFloor() async -> KeyID? {
    do {
      return try await store.read { transaction in try ReplicaDirectory.read(in: transaction).keyFloor }
    } catch {
      Self.logger.warning("Key floor not read for an exchange code=\(error.code, privacy: .public)")
      return nil
    }
  }
}

/// One exchange on the requesting side; see `KeyExchangeRequester`. Accepting keys that join the ring makes the runtime evaluate again.
public final class SyncKeyRequest: Sendable {
  private let requester: KeyExchangeRequester
  private let standing: @Sendable () async -> SyncKeyAttachmentStanding
  private let imported: @Sendable () async -> Void

  init(requester: KeyExchangeRequester, standing: @escaping @Sendable () async -> SyncKeyAttachmentStanding, imported: @escaping @Sendable () async -> Void) {
    self.requester = requester
    self.standing = standing
    self.imported = imported
  }

  public var requestID: UUID { requester.requestID }

  public var payload: String { requester.payload }

  public func receive(_ responseText: String) throws(KeyExchangeError) -> String {
    try requester.receive(responseText)
  }

  public func accept(confirmingCode code: String) async throws(KeyExchangeError) -> KeyImport {
    if case .gone(let phase) = await standing() { throw .unavailable(phase) }
    let result = try await requester.accept(confirmingCode: code)
    if result.holdsAnyKey { await imported() }
    return result
  }

  public func cancel() {
    requester.cancel()
  }
}

extension SyncKeyRequest: CustomReflectable {
  public var customMirror: Mirror {
    Mirror(self, children: ["requestID": requestID], displayStyle: .class)
  }
}

public enum RecoveryStanding: Sendable, Equatable {
  case notSetUp
  case active(createdMillis: Int64)
  /// Another device recorded a different phrase after the one the user wrote down, so that phrase no longer recovers new keys.
  case replaced(byRecipientID: String)
}

extension RecoveryStatus {
  /// `recipientID` is the `RecoverySetupOutcome.recipientID` of the phrase the user holds, or nil when this device has none to compare.
  public func standing(ofRecipient recipientID: String?) -> RecoveryStanding {
    switch self {
    case .notSetUp: return .notSetUp
    case .active(let current, let created):
      guard let recipientID, recipientID != current else { return .active(createdMillis: created) }
      return .replaced(byRecipientID: current)
    }
  }
}
