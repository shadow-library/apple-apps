import Foundation
import OSLog
import ShadowCore
import ShadowSync
import Synchronization

/// The side of one exchange that needs the keys. It opens exactly one response; a key from it joins the ring only after the user has entered the
/// code the other device shows, which is what authenticates the response, and the key has opened a file at this location, which refuses a key that
/// opens nothing here. A mismatched code ends the exchange with nothing added.
public final class KeyExchangeRequester: Sendable {
  private static let logger = Logger(category: "KeyExchangeRequester")

  private enum State: Sendable {
    case awaitingResponse
    case opening
    case awaitingConfirmation(KeyExchangeResult)
    case confirmed(KeyExchangeResult)
    case finished
    case aborted
  }

  private let session: KeyExchangeSession
  private let provider: any StorageProvider
  private let ring: KeyRing
  private let state = Mutex(State.awaitingResponse)

  init(session: KeyExchangeSession, provider: any StorageProvider, ring: KeyRing) {
    self.session = session
    self.provider = provider
    self.ring = ring
  }

  public var requestID: UUID { session.request.id }

  /// The text to show as a QR code; it carries a one-time public key and nothing secret.
  public var payload: String { session.request.encoded }

  /// True until a response opened or the exchange ended: a failed `receive` that leaves it true can be followed by another scan.
  public var isAwaitingResponse: Bool {
    state.withLock { state in
      guard case .awaitingResponse = state else { return false }
      return true
    }
  }

  /// Opens the scanned response and returns the code to show beside the other device's. A response to another request leaves the exchange waiting;
  /// any other failure spends it.
  public func receive(_ responseText: String) throws(KeyExchangeError) -> String {
    let response: KeyExchangeResponse
    do {
      response = try KeyExchangeResponse(encoded: responseText)
    } catch {
      throw .envelope(error)
    }
    try state.withLock { state throws(KeyExchangeError) in
      switch state {
      case .awaitingResponse: state = .opening
      case .opening, .awaitingConfirmation, .confirmed: throw .envelope(.sessionSpent)
      case .finished: throw .exchangeFinished
      case .aborted: throw .exchangeAborted
      }
    }
    let result: KeyExchangeResult
    do {
      result = try session.open(response, expecting: ring.vault)
    } catch {
      state.withLock { $0 = error == .requestMismatch ? .awaitingResponse : .aborted }
      throw .envelope(error)
    }
    let isOpen = state.withLock { state in
      guard case .opening = state else { return false }
      state = .awaitingConfirmation(result)
      return true
    }
    guard isOpen else { throw .exchangeAborted }
    return result.confirmationCode
  }

  /// `code` is what the other device shows, as the user entered it. Once it has matched, calling again retries the keys that opened no file yet.
  public func accept(confirmingCode code: String) async throws(KeyExchangeError) -> KeyImport {
    let entered = code.filter { !$0.isWhitespace }
    let result = try state.withLock { state throws(KeyExchangeError) -> KeyExchangeResult in
      switch state {
      case .awaitingResponse, .opening: throw .awaitingResponse
      case .finished: throw .exchangeFinished
      case .aborted: throw .exchangeAborted
      case .awaitingConfirmation(let result), .confirmed(let result):
        guard entered == result.confirmationCode else {
          state = .aborted
          throw .codeMismatch
        }
        state = .confirmed(result)
        return result
      }
    }
    let imported = try await admit(result.keys)
    Self.logger.info("Received keys by exchange added=\(imported.added.count, privacy: .public) unconfirmed=\(imported.unconfirmed.count, privacy: .public)")
    if imported.unconfirmed.isEmpty { state.withLock { $0 = .finished } }
    guard imported.holdsAnyKey || imported.unconfirmed.isEmpty else { throw .keysUnconfirmed(imported.unconfirmed) }
    return imported
  }

  public func cancel() {
    abort()
  }

  private func abort() {
    state.withLock { state in
      if case .finished = state { return }
      state = .aborted
    }
  }

  private func admit(_ keys: [VaultKey]) async throws(KeyExchangeError) -> KeyImport {
    do {
      try ring.refresh()
    } catch {
      throw KeyExchangeError(error)
    }
    let sorted = KeyAdmission.sort(keys, against: ring)
    let confirmed: Set<KeyID>
    do {
      confirmed = try await HeldFiles.survey(provider, vault: ring.vault).confirm(sorted.candidates)
    } catch {
      throw .storage(error)
    }
    do {
      return try KeyAdmission.admit(sorted, confirmed: confirmed, to: ring)
    } catch {
      throw KeyExchangeError(error)
    }
  }
}

extension KeyExchangeRequester: CustomReflectable {
  public var customMirror: Mirror {
    Mirror(self, children: ["requestID": requestID], displayStyle: .class)
  }
}
