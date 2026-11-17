import Observation
import ShadowStore

@MainActor
@Observable
final class VaultModel {
  enum State {
    case opening
    case ready(VaultStore)
    case failed(VaultOpenError)
  }

  private(set) var state = State.opening
  private let locate: @Sendable () throws(VaultOpenError) -> StoreLocation
  private var isOpening = false

  init(locate: @escaping @Sendable () throws(VaultOpenError) -> StoreLocation = { try VaultOpener.defaultLocation() }) {
    self.locate = locate
  }

  var store: VaultStore? {
    guard case .ready(let store) = state else { return nil }
    return store
  }

  var failure: VaultOpenError? {
    guard case .failed(let error) = state else { return nil }
    return error
  }

  func open() async {
    guard store == nil, !isOpening else { return }
    isOpening = true
    defer { isOpening = false }
    state = .opening
    do {
      state = .ready(try await VaultOpener.open(try locate()))
    } catch {
      state = .failed(error)
    }
  }
}
