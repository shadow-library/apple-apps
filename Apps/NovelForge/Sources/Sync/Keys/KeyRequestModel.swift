import Foundation
import Observation
import ShadowSync
import ShadowSyncRuntime

/// The requesting side of one exchange, as `SyncKeyRequest` offers it.
protocol KeyRequesting: AnyObject, Sendable {
  var payload: String { get }
  var isAwaitingResponse: Bool { get }
  func receive(_ responseText: String) throws(KeyExchangeError) -> String
  func accept(confirmingCode code: String) async throws(KeyExchangeError) -> KeyImport
  func cancel()
}

extension SyncKeyRequest: KeyRequesting {}

/// The device that needs the key: it shows its request as a QR code, takes in the other device's answer, and adds the key only once the user has typed
/// the code the other device shows. This device's own code is never shown, so the user cannot confirm by copying it from the same screen.
@MainActor
@Observable
final class KeyRequestModel {
  static let codeLength = 6

  enum Step: Equatable {
    case showingRequest(payload: String)
    case enteringCode
    case adding
    case finished(added: Int)
    /// Nothing was added; a new exchange starts from the beginning on both devices.
    case ended(PresentedError)
  }

  let vault: VaultID
  private(set) var step: Step
  private(set) var failure: PresentedError?
  var code = "" {
    didSet {
      let digits = String(code.filter(\.isASCIIDigit).prefix(Self.codeLength))
      if digits != code { code = digits }
    }
  }
  @ObservationIgnored private var request: (any KeyRequesting)?

  init(vault: VaultID, request: any KeyRequesting) {
    self.vault = vault
    self.request = request
    step = .showingRequest(payload: request.payload)
  }

  var canAdd: Bool { step == .enteringCode && code.count == Self.codeLength }

  /// The other device's answer, scanned or pasted. A failure that leaves the request awaiting its response (a code that cannot be read, of the wrong
  /// kind, or answering another request) keeps waiting; any other ends the exchange.
  func received(_ text: String) {
    guard case .showingRequest = step, let request else { return }
    failure = nil
    do throws(KeyExchangeError) {
      _ = try request.receive(text.trimmingCharacters(in: .whitespacesAndNewlines))
      step = .enteringCode
    } catch {
      guard request.isAwaitingResponse else { return end(error) }
      failure = SyncKeysErrors.presented(.exchange(error))
    }
  }

  func add() async {
    guard canAdd, let request else { return }
    failure = nil
    step = .adding
    do throws(KeyExchangeError) {
      let imported = try await request.accept(confirmingCode: code)
      self.request = nil
      code = ""
      step = .finished(added: imported.added.count)
    } catch {
      guard case .keysUnconfirmed = error else { return end(error) }
      failure = SyncKeysErrors.presented(.exchange(error))
      step = .enteringCode
    }
  }

  func cancel() {
    request?.cancel()
    request = nil
    code = ""
  }

  private func end(_ error: KeyExchangeError) {
    request?.cancel()
    request = nil
    code = ""
    step = .ended(SyncKeysErrors.presented(.exchange(error)))
  }
}

extension Character {
  fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
