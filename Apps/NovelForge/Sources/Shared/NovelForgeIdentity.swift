import ShadowAppShell
import ShadowStore

extension AppIdentity {
  static let novelForge = AppIdentity(
    id: "com.shadow.apps.novelforge", displayName: "Novel Forge", vaultNoun: "library", vaultTitle: "Library", exampleBucketName: "my-novels")
}

typealias NovelForgeVault = VaultModel<VaultStore>

extension VaultModel where Opened == VaultStore {
  var store: VaultStore? { opened }
}
