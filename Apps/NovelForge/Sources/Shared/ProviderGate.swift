import Observation

/// Holds an action that would start AI work on this device while the provider sheet asks for a provider, and runs it once, after one is connected.
@MainActor
@Observable
final class ProviderGate {
  var needsProvider = false
  @ObservationIgnored private var awaiting: (@MainActor () async -> Void)?

  func perform(providerReady: Bool, _ action: @escaping @MainActor () async -> Void) async {
    guard providerReady else {
      awaiting = action
      needsProvider = true
      return
    }
    awaiting = nil
    await action()
  }

  func providerConnected() async {
    guard let action = awaiting else { return }
    awaiting = nil
    await action()
  }
}
