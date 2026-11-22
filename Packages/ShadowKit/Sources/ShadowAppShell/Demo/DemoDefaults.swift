import Foundation

/// The defaults a demo's screens keep their device choices in, a suite of the app's own (`<app id>.demo`), so the demo never reads or writes a key of the
/// owner's; `DemoSession` empties it on entering and leaving.
public nonisolated enum DemoDefaults {
  public static func suiteName(for identity: AppIdentity) -> String { "\(identity.id).demo" }

  public static func suite(for identity: AppIdentity) -> UserDefaults {
    UserDefaults(suiteName: suiteName(for: identity)) ?? UserDefaults()
  }

  public static func clear(suiteName: String) {
    UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
  }
}
