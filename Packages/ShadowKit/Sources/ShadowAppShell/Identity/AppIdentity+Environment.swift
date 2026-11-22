import SwiftUI

extension EnvironmentValues {
  /// Set by each public shell view from the runtime it was given, so the views inside it name the right app.
  var appIdentity: AppIdentity {
    get { self[AppIdentityKey.self] }
    set { self[AppIdentityKey.self] = newValue }
  }
}

private struct AppIdentityKey: EnvironmentKey {
  /// Reached only by a shell view shown outside the public view that names the app; its words would read "Your  is…".
  static var defaultValue: AppIdentity {
    assertionFailure("A shell view was shown without the app's identity in its environment")
    return AppIdentity(id: "", displayName: "", vaultNoun: "", vaultTitle: "", exampleBucketName: "")
  }
}
