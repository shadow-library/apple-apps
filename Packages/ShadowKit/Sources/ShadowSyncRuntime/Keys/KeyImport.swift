import Foundation
import ShadowSync

/// What became of the keys a recovery or an exchange produced. Only `added` joined the ring in this call.
public struct KeyImport: Sendable, Equatable {
  public let added: [KeyID]
  public let alreadyHeld: [KeyID]
  /// Opened no file at this location, so they were left out; trying again later can confirm them once such a file is uploaded.
  public let unconfirmed: [KeyID]
  /// The keychain already holds other bytes under these ids; the item is write-once, so the received key was refused.
  public let conflicting: [KeyID]

  public var holdsAnyKey: Bool { !added.isEmpty || !alreadyHeld.isEmpty }
}

enum KeyAdmission {
  struct Sorted {
    var held: [KeyID] = []
    var conflicting: [KeyID] = []
    var candidates: [VaultKey] = []
  }

  static func sort(_ keys: [VaultKey], against ring: KeyRing) -> Sorted {
    var sorted = Sorted()
    for key in keys.sorted(by: { $0.id < $1.id }) {
      switch ring.key(key.id).map({ $0.hasSameBytes(as: key) }) {
      case true?: sorted.held.append(key.id)
      case false?: sorted.conflicting.append(key.id)
      case nil: sorted.candidates.append(key)
      }
    }
    return sorted
  }

  /// Inserts each confirmed candidate as its own write-once item; a lock part-way leaves the keys inserted so far, and a retry matches them.
  static func admit(_ sorted: Sorted, confirmed: Set<KeyID>, to ring: KeyRing) throws(KeyRingError) -> KeyImport {
    var added: [KeyID] = []
    var unconfirmed: [KeyID] = []
    var conflicting = sorted.conflicting
    for key in sorted.candidates {
      guard confirmed.contains(key.id) else {
        unconfirmed.append(key.id)
        continue
      }
      do {
        try ring.add(key)
        added.append(key.id)
      } catch {
        guard case .conflictingKey = error else { throw error }
        conflicting.append(key.id)
      }
    }
    return KeyImport(added: added, alreadyHeld: sorted.held, unconfirmed: unconfirmed, conflicting: conflicting.sorted())
  }
}
