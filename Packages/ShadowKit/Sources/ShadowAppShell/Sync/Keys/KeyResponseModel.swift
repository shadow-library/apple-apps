import Foundation
import Observation
import ShadowSync
import ShadowSyncRuntime

/// The device that holds the key: it takes in the other device's request, shows the key sealed to it as a QR code, and shows its six-digit code only
/// after the user says the other device has scanned that answer, so nobody who sees the answer on screen can search for a forged one with the same code.
@MainActor
@Observable
final class KeyResponseModel {
  enum Step: Equatable {
    case awaitingRequest
    case answering
    case showingResponse(payload: String)
    case showingCode(payload: String, code: String)
  }

  let vault: VaultID
  private(set) var step = Step.awaitingRequest
  private(set) var failure: PresentedError?
  @ObservationIgnored private let source: SyncKeyServicesSource
  @ObservationIgnored private var responder: KeyExchangeResponder?

  @ObservationIgnored private let errors: SyncKeysErrors

  init(vault: VaultID, source: SyncKeyServicesSource, app: AppIdentity) {
    errors = SyncKeysErrors(app: app)
    self.vault = vault
    self.source = source
  }

  /// Nil until the user has confirmed the other device scanned the answer.
  var code: String? {
    guard case .showingCode(_, let code) = step else { return nil }
    return code
  }

  func received(_ text: String) async {
    guard step == .awaitingRequest else { return }
    failure = nil
    step = .answering
    let payload = text.trimmingCharacters(in: .whitespacesAndNewlines)
    do throws(SyncKeysError) {
      let responder = try await source.perform(for: vault) { access throws(SyncKeysError) in
        try await SyncKeysError.exchange { () async throws(KeyExchangeError) in try await access.respond(to: payload) }
      }
      self.responder = responder
      step = .showingResponse(payload: responder.payload)
    } catch {
      failure = errors.presented(error)
      step = .awaitingRequest
    }
  }

  func otherDeviceScanned() {
    guard case .showingResponse(let payload) = step, let responder else { return }
    step = .showingCode(payload: payload, code: responder.revealConfirmationCode())
  }

  func cancel() {
    responder = nil
  }
}
