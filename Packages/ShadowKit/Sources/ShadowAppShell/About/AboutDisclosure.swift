import Foundation

/// One line of the About screen's "What leaves this device": the shell words what every app shares, and an app adds its own lines in its own catalog.
public nonisolated struct AboutDisclosure: Identifiable, Sendable {
  public let id: String
  public let systemImage: String
  public let text: LocalizedStringResource

  public init(id: String, systemImage: String, text: LocalizedStringResource) {
    self.id = id
    self.systemImage = systemImage
    self.text = text
  }

  public static func modelProvider(app: AppIdentity) -> AboutDisclosure {
    AboutDisclosure(
      id: "model-provider", systemImage: "sparkles",
      text: LocalizedStringResource(
        "When you use AI, \(app.displayName) sends what the request needs from your own devices straight to the provider you chose, under your own key, and only the kinds of data you allowed in AI settings. OpenRouter passes each request on to the company that runs the model you picked.",
        table: "About", bundle: .shell))
  }

  public static func sync(app: AppIdentity) -> AboutDisclosure {
    AboutDisclosure(
      id: "sync", systemImage: "arrow.triangle.2.circlepath",
      text: LocalizedStringResource(
        "When you turn on sync, your \(app.vaultNoun) is encrypted on this device before it goes to the storage you chose.", table: "About", bundle: .shell))
  }

  public static func keychain(app: AppIdentity) -> AboutDisclosure {
    AboutDisclosure(
      id: "keychain", systemImage: "key",
      text: LocalizedStringResource(
        "While iCloud Keychain is on, \(app.displayName) keeps your AI provider keys, your \(app.vaultNoun)'s sync keys and your storage credentials in it, end-to-end encrypted by Apple.",
        table: "About", bundle: .shell))
  }

  public static func nothingElse(app: AppIdentity) -> AboutDisclosure {
    AboutDisclosure(
      id: "nothing-else", systemImage: "lock",
      text: LocalizedStringResource(
        "Nothing else leaves your devices: \(app.displayName) has no account, analytics or advertising, and its developer receives none of your data.", table: "About",
        bundle: .shell))
  }
}
