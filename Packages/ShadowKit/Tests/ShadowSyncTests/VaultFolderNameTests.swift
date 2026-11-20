import ShadowSync
import Testing

@Suite("VaultFolderName", TestTimeLimit.quick)
struct VaultFolderNameTests {
  @Test("should accept ASCII names that start with a letter or digit", arguments: ["Novel Forge", "vault-1", "My_Vault.v2", "a", String(repeating: "x", count: 64)])
  func acceptsNames(name: String) {
    #expect(VaultFolderName(name)?.rawValue == name)
  }

  @Test(
    "should refuse names a cloud drive would reject or rewrite",
    arguments: [
      "", " vault", "vault ", ".vault", "vault.", "-vault", "_vault", "va/ult", "va:ult", "va\\ult", "väult", "vault\n", String(repeating: "x", count: 65),
      "CON", "con.txt", "Nul", "COM1", "lpt9.backup", "desktop.ini", "my_vti_folder",
    ]
  )
  func refusesNames(name: String) {
    #expect(VaultFolderName(name) == nil)
  }
}
