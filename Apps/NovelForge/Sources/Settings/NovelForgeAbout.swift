import ShadowAppShell

extension AboutDisclosure {
  static var novelForge: [AboutDisclosure] { [.modelProvider(app: .novelForge), .sync(app: .novelForge), .keychain(app: .novelForge), .nothingElse(app: .novelForge)] }
}
