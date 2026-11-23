import SwiftUI

extension EnvironmentValues {
  /// Set by each public shell view through `appIdentity(_:)` from the runtime it was given, so the views inside it name the right app.
  var appIdentity: AppIdentity {
    guard let identity = self[AppIdentityKey.self] else {
      assertionFailure("A shell view was shown without the app's identity in its environment")
      return AppIdentity(id: "", displayName: "", vaultNoun: "", vaultTitle: "", exampleBucketName: "")
    }
    return identity
  }

  fileprivate var namedAppIdentity: AppIdentity? {
    get { self[AppIdentityKey.self] }
    set { self[AppIdentityKey.self] = newValue }
  }
}

extension View {
  /// Writes to optional storage: the Swift runtime of iOS 26 reads a key path's current value before setting it, which `appIdentity` refuses at the root.
  func appIdentity(_ identity: AppIdentity) -> some View {
    environment(\.namedAppIdentity, identity)
  }
}

private struct AppIdentityKey: EnvironmentKey {
  static var defaultValue: AppIdentity? { nil }
}
