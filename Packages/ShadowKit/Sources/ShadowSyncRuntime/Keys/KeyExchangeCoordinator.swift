import Foundation
import ShadowSync
import Synchronization

/// The QR key exchange of one vault. The device that needs the keys starts a `KeyExchangeRequester` and shows its payload; the device that holds them
/// scans it with `respond(to:)` and shows the sealed response; the first device scans that, and both show a six-digit code the user compares.
/// Keep one coordinator per vault for the life of the process: it remembers the requests this device answered and refuses them a second time.
public final class KeyExchangeCoordinator: Sendable {
  public let provider: any StorageProvider
  public let ring: KeyRing
  private let answered = Mutex<Set<UUID>>([])

  public init(provider: any StorageProvider, ring: KeyRing) {
    self.provider = provider
    self.ring = ring
  }

  public var vault: VaultID { ring.vault }

  public func request() -> KeyExchangeRequester {
    KeyExchangeRequester(session: KeyExchangeSession(), provider: provider, ring: ring)
  }

  /// Seals the ring to the scanned request. At most `KeyExchangeResponse.maximumKeys` keys travel: those at or above `floor` first, oldest first,
  /// then the newest below it.
  public func respond(to payload: String, floor: KeyID? = nil) throws(KeyExchangeError) -> KeyExchangeResponder {
    let request: KeyExchangeRequest
    do {
      request = try KeyExchangeRequest(encoded: payload)
    } catch {
      throw .envelope(error)
    }
    do {
      try ring.refresh()
    } catch {
      throw KeyExchangeError(error)
    }
    let keys = Self.select(ring.keyIDs, floor: floor).compactMap(ring.key)
    guard !keys.isEmpty else { throw .noRingKey }
    guard answered.withLock({ $0.insert(request.id).inserted }) else { throw .requestReplayed }
    do {
      let (response, code) = try KeyExchangeResponse.make(answering: request, vault: vault, keys: keys)
      return KeyExchangeResponder(requestID: request.id, payload: response.encoded, confirmationCode: code)
    } catch {
      throw .envelope(error)
    }
  }

  static func select(_ keyIDs: [KeyID], floor: KeyID?) -> [KeyID] {
    let sorted = keyIDs.sorted()
    let above = sorted.filter { id in floor.map { id >= $0 } ?? true }
    let below = sorted.filter { id in floor.map { id < $0 } ?? false }.reversed()
    return Array((above + below).prefix(KeyExchangeResponse.maximumKeys)).sorted()
  }
}

extension KeyExchangeCoordinator: CustomReflectable {
  public var customMirror: Mirror {
    Mirror(self, children: ["vault": vault], displayStyle: .class)
  }
}

/// The holding device's side of one exchange. Its code stays hidden until `revealConfirmationCode()`: call that only once the user says the other
/// device has scanned the response, so whoever sees this screen cannot search for a forged response that shows the same code.
public final class KeyExchangeResponder: Sendable {
  public let requestID: UUID
  public let payload: String
  private let confirmationCode: String
  private let revealed = Mutex(false)

  init(requestID: UUID, payload: String, confirmationCode: String) {
    self.requestID = requestID
    self.payload = payload
    self.confirmationCode = confirmationCode
  }

  public var isCodeRevealed: Bool {
    revealed.withLock { $0 }
  }

  public func revealConfirmationCode() -> String {
    revealed.withLock { $0 = true }
    return confirmationCode
  }
}

extension KeyExchangeResponder: CustomReflectable {
  public var customMirror: Mirror {
    Mirror(self, children: ["requestID": requestID, "isCodeRevealed": isCodeRevealed], displayStyle: .class)
  }
}
