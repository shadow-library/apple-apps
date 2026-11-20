import Foundation
import ShadowSync
import ShadowSyncCloudKit
import ShadowSyncGoogleDrive
import ShadowSyncOneDrive
import ShadowSyncRuntime
import ShadowSyncS3
import Testing

@Suite("SyncLocationStore", TestTimeLimit.quick)
struct SyncLocationStoreTests {
  private static func allSettings() throws -> [SyncProviderSettings] {
    let folder = try #require(VaultFolderName("Novel Forge"))
    let redirect = try #require(URL(string: "com.shadow.apps.test:/oauth"))
    let s3 = try S3Configuration(
      endpoint: try #require(URL(string: "https://s3.example.com")), region: "eu-west-1", bucket: "vaults", keyPrefix: "people/one", addressingStyle: .path,
      supportsConditionalWrites: true)
    return [
      RuntimeFixture.iCloud,
      .localFolder(SyncLocalFolderSettings(url: URL(filePath: "/tmp/vault folder"), bookmark: Data([1, 2, 3]))),
      .s3(SyncS3Settings(s3)),
      .oneDrive(SyncOneDriveSettings(try OneDriveConfiguration(clientID: "client-one", redirectURI: redirect, vaultFolder: folder, audience: .consumers))),
      .googleDrive(SyncGoogleDriveSettings(try GoogleDriveConfiguration(clientID: "client-two", redirectURI: redirect, vaultFolder: folder))),
    ]
  }

  @Test("should round-trip a location for every provider kind")
  func roundTrips() throws {
    let directory = try TemporaryDirectory()
    let store = try directory.locationStore()
    let settings = try Self.allSettings()
    #expect(settings.map(\.kind) == SyncProviderKind.allCases)
    for (index, settings) in settings.enumerated() {
      let account = index.isMultiple(of: 2) ? SyncAccountBinding(kind: settings.kind, account: "account-\(index)") : nil
      let location = SyncLocation(settings: settings, vault: RuntimeFixture.vault("vault-\(index)"), account: account)

      try store.save(location)

      #expect(try store.load() == .attached(location))
    }
  }

  @Test("should rebuild each provider's configuration from its saved settings")
  func rebuildsConfigurations() throws {
    for settings in try Self.allSettings() {
      switch settings {
      case .iCloud(let iCloud): #expect(try iCloud.configuration().zoneName == "vault-default")
      case .localFolder(let folder): #expect(folder.url.path(percentEncoded: false) == "/tmp/vault folder/")
      case .s3(let s3): #expect(SyncS3Settings(try s3.configuration()) == s3)
      case .oneDrive(let oneDrive): #expect(SyncOneDriveSettings(try oneDrive.configuration()) == oneDrive)
      case .googleDrive(let google): #expect(SyncGoogleDriveSettings(try google.configuration()) == google)
      }
    }
  }

  @Test("should write the documented JSON shape")
  func writesStableShape() throws {
    let directory = try TemporaryDirectory()
    let store = try directory.locationStore()
    let binding = try #require(SyncAccountBinding(digest: String(repeating: "ab", count: 32)))

    try store.save(SyncLocation(settings: RuntimeFixture.iCloud, vault: RuntimeFixture.vault("vault-one"), account: binding))

    let text = String(decoding: try Data(contentsOf: store.url), as: UTF8.self)
    let settings = #"{"containerIdentifier":"iCloud.com.shadow.apps.test","zoneName":"vault-default"}"#
    #expect(text == #"{"account":"\#(binding.digest)","format":1,"kind":"iCloud","settings":\#(settings),"vault":"vault-one"}"#)
  }

  @Test("should read a missing file as first use")
  func missingIsFirstUse() throws {
    let directory = try TemporaryDirectory()

    #expect(try directory.locationStore().load() == .firstUse)
  }

  @Test(
    "should read a corrupt, newer or unknown file as turned off, never as first use",
    arguments: [
      "not json",
      #"{"format":2,"kind":"iCloud","vault":"vault-one","settings":{"containerIdentifier":"iCloud.a","zoneName":"z"}}"#,
      #"{"format":1,"kind":"dropbox","vault":"vault-one","settings":{}}"#,
      #"{"format":1,"kind":"iCloud","vault":"Not A Vault","settings":{"containerIdentifier":"iCloud.a","zoneName":"z"}}"#,
      #"{"format":1,"kind":"iCloud","vault":"vault-one","account":"short","settings":{"containerIdentifier":"iCloud.a","zoneName":"z"}}"#,
      #"{"format":1,"kind":"s3","vault":"vault-one","settings":{"containerIdentifier":"iCloud.a","zoneName":"z"}}"#,
    ])
  func corruptIsTurnedOff(contents: String) throws {
    let directory = try TemporaryDirectory()
    let store = try directory.locationStore()
    try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: store.url)

    #expect(try store.load() == .turnedOff)
  }

  @Test("should report a file it may not read as permission denied and leave locked or not to the caller")
  func unreadableFileIsLocked() throws {
    let directory = try TemporaryDirectory()
    let store = try directory.locationStore()
    try store.save(SyncLocation(settings: RuntimeFixture.iCloud, vault: RuntimeFixture.vault("vault-one"), account: nil))
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: store.url.path(percentEncoded: false))
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.url.path(percentEncoded: false)) }

    let error = try #require(throws: SyncLocationError.self) { try store.load() }
    guard case .permissionDenied = error else { throw RuntimeFixtureFailure("expected permission denied, got \(error)") }
  }

  @Test("should refuse a location file inside a vault directory")
  func refusesVaultDirectory() throws {
    let directory = try TemporaryDirectory()
    let vault = directory.url.appending(path: "Vaults/Default", directoryHint: .isDirectory)

    #expect(throws: SyncLocationError.self) { try SyncLocationStore(url: vault.appending(path: "location.json"), outside: [vault]) }
    #expect(throws: SyncLocationError.self) { try SyncLocationStore(url: vault.appending(path: "nested/../location.json"), outside: [vault]) }
    #expect(throws: Never.self) { try SyncLocationStore(url: directory.url.appending(path: "Vaults/Default-location.json"), outside: [vault]) }
  }

  @Test("should replace a saved location, turn sync off once or twice and turn it on again")
  func replacesAndTurnsOff() throws {
    let directory = try TemporaryDirectory()
    let store = try directory.locationStore()
    let second = SyncLocation(settings: RuntimeFixture.localFolder("b"), vault: RuntimeFixture.vault("vault-two"), account: nil)
    try store.save(SyncLocation(settings: RuntimeFixture.localFolder("a"), vault: RuntimeFixture.vault("vault-one"), account: nil))

    try store.save(second)
    #expect(try store.load() == .attached(second))
    let siblings = try FileManager.default.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path(percentEncoded: false))
    #expect(siblings == ["location.json"])

    try store.turnOff()
    try store.turnOff()
    #expect(try store.load() == .turnedOff)
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path(percentEncoded: false)) == ["location.json.off"])

    try store.save(second)
    #expect(try store.load() == .attached(second))
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path(percentEncoded: false)) == ["location.json"])
  }

  @Test("should let a saved location win over a turned-off mark a crash left beside it")
  func locationWinsOverMark() throws {
    let directory = try TemporaryDirectory()
    let store = try directory.locationStore()
    let location = SyncLocation(settings: RuntimeFixture.localFolder("a"), vault: RuntimeFixture.vault("vault-one"), account: nil)
    try store.save(location)

    try Data().write(to: store.url.appendingPathExtension("off"))

    #expect(try store.load() == .attached(location))
  }

  @Test("should place the default file beside the vaults, not inside one")
  func defaultURL() throws {
    let support = URL(filePath: "/Library/Application Support", directoryHint: .isDirectory)

    let url = SyncLocationStore.defaultURL(applicationSupport: support, bundleIdentifier: "com.shadow.apps.test")

    #expect(url.path(percentEncoded: false) == "/Library/Application Support/com.shadow.apps.test/Sync/location.json")
    #expect(throws: Never.self) { try SyncLocationStore(url: url, outside: [support.appending(path: "com.shadow.apps.test/Vaults/Default")]) }
  }

  @Test("should derive one binding per account and provider and refuse malformed digests")
  func bindings() {
    let one = SyncAccountBinding(kind: .iCloud, account: "user-one")

    #expect(one == SyncAccountBinding(kind: .iCloud, account: "user-one"))
    #expect(one != SyncAccountBinding(kind: .iCloud, account: "user-two"))
    #expect(one != SyncAccountBinding(kind: .oneDrive, account: "user-one"))
    #expect(!one.digest.contains("user-one"))
    #expect(SyncAccountBinding(digest: one.digest) == one)
    #expect(SyncAccountBinding(digest: one.digest.uppercased()) == nil)
    #expect(SyncAccountBinding(digest: "abc") == nil)
  }
}
