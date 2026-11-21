import Foundation
import Security
import ShadowKeychain
import ShadowStore
import ShadowSync
import ShadowSyncRuntime
import ShadowSyncS3
import ShadowTestSupport
import Synchronization
import Testing

@testable import NovelForge

/// A settings page over one device's sync: its runtime made by the app's own wiring, so folders go through their bookmarks and S3 through `s3Transport`.
@MainActor
struct SettingsDevice {
  let world: SyncWorld
  let sync: SyncRuntimes
  let store: VaultStore
  let model: SyncSettingsModel

  typealias Override = @Sendable (SyncProviderSettings) -> (any StorageProvider)?

  static func launch(_ world: SyncWorld, override: Override? = nil) async throws -> SettingsDevice {
    let wiring = world.wiring
    let sync = SyncRuntimes(
      factory: { store, trustedClock in
        guard var environment = try? wiring.environment() else { return nil }
        environment.provider = { settings throws(StorageError) in
          if let provider = override?(settings) { return provider }
          return try wiring.provider(for: settings)
        }
        return SyncRuntime(environment: environment, store: store, device: wiring.device, trustedClock: trustedClock, wallClock: SyncEngine.wallClock(preferring: trustedClock))
      }, wiring: wiring)
    let (store, clock) = try SyncWorld.openStore()
    await sync.launch(store, trustedClock: clock)
    let model = SyncSettingsModel(sync: sync)
    await model.refresh()
    return SettingsDevice(world: world, sync: sync, store: store, model: model)
  }

  var runtime: SyncRuntime {
    get throws { try #require(sync.runtime) }
  }

  /// Turns sync on with a folder picked the way the importer hands it over.
  func connect(_ folder: URL, choice: (VaultDiscovery) -> VaultChoice?) async throws -> SyncConnectModel.Finish? {
    model.startConnect()
    let connect = try #require(model.connect)
    await connect.folderPicked(.success(folder))
    guard case .discovered(_, let discovery) = connect.step, let chosen = choice(discovery) else { return nil }
    await connect.attach(chosen)
    guard case .finished(let finish) = connect.step else {
      Issue.record("connecting did not finish: \(connect.step), \(String(describing: connect.failure))")
      return nil
    }
    await model.closeConnect()
    return finish
  }

  func location() throws -> SyncLocationRecord {
    try world.wiring.locationStore().load()
  }

  func shutDown() async {
    await sync.shutDown()
    world.remove()
  }
}

nonisolated enum SettingsFolders {
  static func make(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "NovelForgeSyncSettings-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  static func holdsVault(_ folder: URL) -> Bool {
    FileManager.default.fileExists(atPath: folder.appending(path: VaultPath.hint.rawValue).path(percentEncoded: false))
  }
}

/// A local folder whose reads fail while `failing` is set, as a target that loses its connection after the copy.
nonisolated final class FlakyReads: StorageProvider {
  let inner: LocalFolderProvider
  private let failing = Mutex(true)

  init(root: URL) throws {
    inner = try LocalFolderProvider(root: root)
  }

  func heal() { failing.withLock { $0 = false } }

  var capabilities: StorageCapabilities { inner.capabilities }

  func list(prefix: String, after cursor: ListCursor?) async throws(StorageError) -> ListPage { try await inner.list(prefix: prefix, after: cursor) }

  func get(_ key: ObjectKey) async throws(StorageError) -> Data {
    if failing.withLock({ $0 }), key.hasPrefix(VaultPath.replicasPrefix) { throw .unavailable("the connection dropped") }
    return try await inner.get(key)
  }

  func put(_ key: ObjectKey, data: Data, condition: PutCondition) async throws(StorageError) -> PutReceipt {
    try await inner.put(key, data: data, condition: condition)
  }

  func delete(_ keys: [ObjectKey]) async throws(StorageError) { try await inner.delete(keys) }

  func changeNotices() -> AsyncStream<Void> { inner.changeNotices() }
}

/// Answers the S3 requests of the conditional-write probe and of discovery for an empty bucket.
nonisolated enum S3Answers {
  enum Failure: Sendable {
    case wrongKeys
    case unreachable
  }

  private final class Bucket: Sendable {
    let names = Mutex<Set<String>>([])
  }

  static func transport(honoursConditions: Bool = true, failure: Failure? = nil) -> StubHTTPTransport {
    let bucket = Bucket()
    return StubHTTPTransport { request in try answer(request, bucket: bucket, honoursConditions: honoursConditions, failure: failure) }
  }

  private static func answer(_ request: URLRequest, bucket: Bucket, honoursConditions: Bool, failure: Failure?) throws -> (Data, HTTPURLResponse) {
    switch failure {
    case .unreachable: throw URLError(.cannotFindHost)
    case .wrongKeys: return try StubHTTPTransport.response(to: request, statusCode: 403, data: Data("<Error><Code>InvalidAccessKeyId</Code></Error>".utf8))
    case nil: break
    }
    let path = request.url?.path(percentEncoded: false) ?? "/"
    let query = request.url?.query() ?? ""
    switch request.httpMethod ?? "GET" {
    case "PUT":
      let exists = bucket.names.withLock { !$0.insert(path).inserted }
      let refused = exists && honoursConditions && request.value(forHTTPHeaderField: "If-None-Match") == "*"
      return try StubHTTPTransport.response(to: request, statusCode: refused ? 412 : 200)
    case "POST" where query.contains("delete"):
      bucket.names.withLock { $0.removeAll() }
      return try StubHTTPTransport.response(to: request, statusCode: 200, data: Data("<DeleteResult></DeleteResult>".utf8))
    case "DELETE":
      bucket.names.withLock { _ = $0.remove(path) }
      return try StubHTTPTransport.response(to: request, statusCode: 204)
    case "GET" where query.contains("list-type"):
      return try StubHTTPTransport.response(to: request, statusCode: 200, data: Data("<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>".utf8))
    default:
      return try StubHTTPTransport.response(to: request, statusCode: 404, data: Data("<Error><Code>NoSuchKey</Code></Error>".utf8))
    }
  }
}

/// Answers as the data-protection keychain answers a build without an application identifier: reads find nothing, writes fail with `errSecMissingEntitlement`.
nonisolated final class TeamlessKeychain: SecureStore {
  private static let refused = SecureStoreError.unexpectedStatus(errSecMissingEntitlement)

  func data(forKey key: String) throws(SecureStoreError) -> Data? { nil }
  func setData(_ data: Data, forKey key: String) throws(SecureStoreError) { throw Self.refused }
  func insertData(_ data: Data, forKey key: String) throws(SecureStoreError) -> Bool { throw Self.refused }
  func removeValue(forKey key: String) throws(SecureStoreError) { throw Self.refused }
  func allKeys() throws(SecureStoreError) -> [String] { [] }

  static var stores: SyncSecureStores {
    SyncSecureStores(ring: TeamlessKeychain(), credentials: TeamlessKeychain(), marker: TeamlessKeychain(), tokens: TeamlessKeychain())
  }
}

@MainActor
@Suite("Sync settings", TestTimeLimit.standard)
struct SyncSettingsTests {
  private static let s3Endpoint = "s3.example.com"

  private static func s3Form() -> SyncS3Form {
    var form = SyncS3Form()
    form.endpoint = s3Endpoint
    form.region = "eu-west-1"
    form.bucket = "novels"
    form.keyPrefix = "/shelf/"
    form.accessKeyID = "AKIDEXAMPLE"
    form.secretAccessKey = "wJalrXUtnFEMI/K7MDENG"
    return form
  }

  @Test func shouldBuildTheConfigurationAndKeysFromATypedForm() throws {
    guard case .success(let validated) = Self.s3Form().validate() else {
      Issue.record("a complete form did not validate")
      return
    }
    #expect(validated.configuration.endpoint.absoluteString == "https://s3.example.com")
    #expect(validated.configuration.keyPrefix == "shelf")
    #expect(validated.configuration.bucket == "novels")
    #expect(validated.credentials.accessKeyID == "AKIDEXAMPLE")
  }

  @Test func shouldNameTheFieldToFixInAnInvalidForm() {
    var insecure = Self.s3Form()
    insecure.endpoint = "http://s3.example.com"
    var dotted = Self.s3Form()
    dotted.bucket = "my.novels"
    var region = Self.s3Form()
    region.region = "EU West"
    var keys = Self.s3Form()
    keys.secretAccessKey = "  "

    #expect(Self.field(insecure) == .endpoint)
    #expect(Self.field(dotted) == .bucket)
    #expect(Self.field(region) == .region)
    #expect(Self.field(keys) == .credentials)
    dotted.addressing = .path
    #expect(Self.field(dotted) == nil)
  }

  private static func field(_ form: SyncS3Form) -> SyncS3Form.Field? {
    guard case .failure(let issue) = form.validate() else { return nil }
    return issue.field
  }

  @Test func shouldOfferICloudOnlyWhenSignedForItAndShowOneDriveAndGoogleDriveDisabledWithAReason() {
    let unsigned = SyncProviderOption.all(hasICloud: false)
    let signed = SyncProviderOption.all(hasICloud: true)

    #expect(unsigned.map(\.kind) == SyncProviderKind.allCases)
    #expect(unsigned.first { $0.kind == .iCloud }?.unavailability == .notSignedForICloud)
    #expect(signed.first { $0.kind == .iCloud }?.isAvailable == true)
    for kind in [SyncProviderKind.oneDrive, .googleDrive] {
      let option = unsigned.first { $0.kind == kind }
      #expect(option?.unavailability == .noAppRegistration)
      #expect(option?.reason?.isEmpty == false)
    }
    #expect(unsigned.filter(\.isAvailable).map(\.kind) == [.localFolder, .s3])
  }

  @Test func shouldExplainThatATeamlessBuildCannotSyncAndOfferNothingToConnect() async throws {
    let device = try await SettingsDevice.launch(try SyncWorld(stores: TeamlessKeychain.stores))

    #expect(device.model.overview == .off(nil))
    #expect(device.model.isKeychainRefused)
    #expect(!device.model.canChangeLocation)
    device.model.startConnect()
    #expect(device.model.connect == nil)
    let runtime = try device.runtime
    let settings = device.world.settings
    let refusal = await #expect(throws: SyncStartupError.self) { try await runtime.attach(settings, choice: .create) }
    #expect(refusal == .keychainUnavailable)
    #expect(SyncSettingsErrors.presented(try #require(refusal), kind: .localFolder).headline == SyncSettingsErrors.teamlessHeadline)
    guard case .success(let s3) = Self.s3Form().validate() else {
      Issue.record("the S3 form did not validate")
      return
    }
    let saving = #expect(throws: SyncCredentialError.self) {
      try device.world.wiring.stores.s3Credentials.save(s3.credentials, for: SyncS3Settings(s3.configuration))
    }
    #expect(saving == .keychainUnavailable)
    #expect(SyncSettingsErrors.presented(try #require(saving), kind: .s3).headline == SyncSettingsErrors.teamlessHeadline)
    await device.shutDown()
  }

  @Test func shouldReadEveryLayersKeychainRefusalAsATeamlessBuildAndNothingElse() {
    let refusals: [any Error] = [
      SyncStartupError.keychainUnavailable, SyncStartupError.keyRing(.keychainUnavailable), SyncStartupError.setup(.keyRing(.keychainUnavailable)),
      SyncStartupError.unavailable(.keychainUnavailable), SyncCredentialError.keychainUnavailable, KeyRingError.keychainUnavailable,
      SecureStoreError.unexpectedStatus(errSecMissingEntitlement), SyncMoveError.startup(.keychainUnavailable), SyncMoveError.sync(.keyRing(.keychainUnavailable)),
    ]
    let others: [any Error] = [
      SyncStartupError.deviceLocked, SyncStartupError.keyRing(.store("x")), SyncCredentialError.keychain("x"), SecureStoreError.unexpectedStatus(errSecInteractionNotAllowed),
    ]

    for error in refusals { #expect(SyncSettingsErrors.presented(error, kind: nil).headline == SyncSettingsErrors.teamlessHeadline, "\(error)") }
    for error in others { #expect(SyncSettingsErrors.presented(error, kind: nil).headline != SyncSettingsErrors.teamlessHeadline, "\(error)") }
  }

  @Test func shouldRoundTripASecurityScopedFolderBookmark() throws {
    let folder = try SettingsFolders.make("bookmark")
    defer { try? FileManager.default.removeItem(at: folder) }

    let settings = try LocalFolderAccess.settings(forPicked: folder)
    let resolved = try LocalFolderAccess().resolve(settings)

    #expect(settings.bookmark != nil)
    #expect(settings.path == SyncLocalFolderSettings(url: folder).path)
    #expect(resolved.url.standardizedFileURL.path(percentEncoded: false) == settings.url.standardizedFileURL.path(percentEncoded: false))
    #expect(resolved.refreshed == nil)
  }

  @Test func shouldRenewAStaleBookmarkAndSaveItOverTheAttachedLocation() throws {
    let world = try SyncWorld()
    defer { world.remove() }
    let original = try SettingsFolders.make("stale")
    let moved = original.deletingLastPathComponent().appending(path: original.lastPathComponent + "-moved", directoryHint: .isDirectory)
    defer {
      try? FileManager.default.removeItem(at: original)
      try? FileManager.default.removeItem(at: moved)
    }
    let settings = try LocalFolderAccess.settings(forPicked: original)
    let vault = try #require(VaultID("vault-stale"))
    try world.wiring.locationStore().save(SyncLocation(settings: .localFolder(settings), vault: vault, account: nil))
    try FileManager.default.moveItem(at: original, to: moved)

    _ = try world.wiring.provider(for: .localFolder(settings))

    guard case .attached(let saved) = try world.wiring.locationStore().load(), case .localFolder(let renewed) = saved.settings else {
      Issue.record("the location is no longer an attached folder")
      return
    }
    #expect(saved.vault == vault)
    #expect(renewed.path == SyncLocalFolderSettings(url: moved).path)
    #expect(renewed.bookmark != settings.bookmark)
    #expect(try LocalFolderAccess().resolve(renewed).refreshed == nil)
  }

  @Test func shouldReportABookmarkThatNoLongerResolves() {
    let broken = SyncLocalFolderSettings(url: FileManager.default.temporaryDirectory, bookmark: Data("not a bookmark".utf8))

    #expect(throws: StorageError.self) { try LocalFolderAccess().resolve(broken) }
  }

  @Test func shouldRefuseAFolderInsideTheAppsOwnDataAndStayOnTheListWhenTheImporterFails() async throws {
    let device = try await SettingsDevice.launch(try SyncWorld())
    device.model.startConnect()
    let connect = try #require(device.model.connect)
    let ownData = device.world.wiring.paths.vaultDirectory
    try FileManager.default.createDirectory(at: ownData, withIntermediateDirectories: true)

    await connect.folderPicked(.success(ownData))
    #expect(connect.failure != nil)
    #expect(connect.step == .choosing)

    await connect.folderPicked(.failure(CocoaError(.fileReadNoPermission)))
    #expect(connect.failure != nil)
    #expect(connect.step == .choosing)
    #expect(try device.location() == .firstUse)
    await device.shutDown()
  }

  @Test func shouldCreateAVaultInAnEmptyFolderOnlyAfterTheExplicitChoice() async throws {
    let device = try await SettingsDevice.launch(try SyncWorld())
    #expect(device.model.overview == .off(nil))
    device.model.startConnect()
    let connect = try #require(device.model.connect)

    await connect.folderPicked(.success(device.world.folder))

    guard case .discovered(.localFolder(let picked), .empty) = connect.step else {
      Issue.record("an empty folder was not offered for a new vault: \(connect.step)")
      return
    }
    #expect(picked.bookmark != nil)
    #expect(try device.location() == .firstUse)
    #expect(!SettingsFolders.holdsVault(device.world.folder))

    await connect.attach(.create)

    #expect(connect.step == .finished(.attached(.vault(.ready(vault: try Self.attachedVault(device))))))
    #expect(SettingsFolders.holdsVault(device.world.folder))
    await device.model.closeConnect()
    guard case .attached(let location, _) = device.model.overview else {
      Issue.record("the overview does not show the attached folder: \(device.model.overview)")
      return
    }
    #expect(location.kind == .localFolder)
    await device.shutDown()
  }

  @Test func shouldOfferToJoinTheVaultFoundInAFolder() async throws {
    let first = try await SettingsDevice.launch(try SyncWorld())
    _ = try await first.connect(first.world.folder) { _ in .create }
    let vault = try Self.attachedVault(first)
    let second = try await SettingsDevice.launch(try SyncWorld(storage: first.world.folder))

    let finish = try await second.connect(first.world.folder) { discovery in
      #expect(discovery == .found(vault))
      return .join(vault)
    }

    #expect(finish == .attached(.vault(.awaitingKey(vault: vault))))
    #expect(try Self.attachedVault(second) == vault)
    await second.shutDown()
    await first.shutDown()
  }

  @Test func shouldProbeThenSaveTheKeysAndKeepTheProbesAnswerBeforeLookingAtTheBucket() async throws {
    let device = try await SettingsDevice.launch(try SyncWorld(s3Transport: S3Answers.transport()))
    device.model.startConnect()
    let connect = try #require(device.model.connect)
    await connect.choose(.s3)
    connect.s3 = Self.s3Form()

    await connect.submitS3()

    guard case .discovered(.s3(let settings), .empty) = connect.step else {
      Issue.record("the bucket was not looked at: \(connect.step), \(String(describing: connect.failure))")
      return
    }
    #expect(settings.supportsConditionalWrites)
    #expect(!connect.conditionalWritesUnsupported)
    #expect(settings.keyPrefix == "shelf")
    #expect(try device.world.wiring.stores.s3Credentials.load(for: settings)?.accessKeyID == "AKIDEXAMPLE")

    connect.cancel()
    #expect(try device.world.wiring.stores.s3Credentials.load(for: settings) == nil)
    await device.shutDown()
  }

  @Test func shouldPutBackEveryS3KeyAPassSavedWhenItFinishesWithAnotherStorage() async throws {
    let device = try await SettingsDevice.launch(try SyncWorld(s3Transport: S3Answers.transport()))
    device.model.startConnect()
    let connect = try #require(device.model.connect)
    var saved: [SyncS3Settings] = []
    for bucket in ["novels", "drafts"] {
      await connect.choose(.s3)
      connect.s3 = Self.s3Form()
      connect.s3.bucket = bucket
      await connect.submitS3()
      guard case .discovered(.s3(let settings), _) = connect.step else {
        Issue.record("the bucket \(bucket) was not looked at: \(connect.step)")
        return
      }
      saved.append(settings)
      connect.back()
    }
    #expect(try saved.allSatisfy { try device.world.wiring.stores.s3Credentials.load(for: $0) != nil })

    await connect.folderPicked(.success(device.world.folder))
    await connect.attach(.create)
    guard case .finished = connect.step else {
      Issue.record("the folder was not attached: \(connect.step)")
      return
    }
    await device.model.closeConnect()

    #expect(try saved.allSatisfy { try device.world.wiring.stores.s3Credentials.load(for: $0) == nil })
    guard case .attached(let location) = try device.location() else {
      Issue.record("nothing is attached")
      return
    }
    #expect(location.kind == .localFolder)
    await device.shutDown()
  }

  @Test func shouldCancelAnIdlePassAndPutBackItsKeysWhenThePageGoesAway() async throws {
    let device = try await SettingsDevice.launch(try SyncWorld(s3Transport: S3Answers.transport()))
    device.model.startConnect()
    let connect = try #require(device.model.connect)
    await connect.choose(.s3)
    connect.s3 = Self.s3Form()
    await connect.submitS3()
    guard case .discovered(.s3(let settings), _) = connect.step else {
      Issue.record("the bucket was not looked at: \(connect.step)")
      return
    }

    device.model.leave()

    #expect(device.model.connect == nil)
    #expect(try device.world.wiring.stores.s3Credentials.load(for: settings) == nil)
    #expect(try device.location() == .firstUse)
    await device.shutDown()
  }

  @Test func shouldKeepAnUnsupportedConditionalWriteAnswerAndWarn() async throws {
    let device = try await SettingsDevice.launch(try SyncWorld(s3Transport: S3Answers.transport(honoursConditions: false)))
    device.model.startConnect()
    let connect = try #require(device.model.connect)
    await connect.choose(.s3)
    connect.s3 = Self.s3Form()

    await connect.submitS3()

    guard case .discovered(.s3(let settings), .empty) = connect.step else {
      Issue.record("the bucket was not looked at: \(connect.step)")
      return
    }
    #expect(!settings.supportsConditionalWrites)
    #expect(connect.conditionalWritesUnsupported)
    await device.shutDown()
  }

  @Test(arguments: [S3Answers.Failure.wrongKeys, .unreachable])
  func shouldTellWrongKeysFromAnUnreachableEndpointAndSaveNothing(failure: S3Answers.Failure) async throws {
    let device = try await SettingsDevice.launch(try SyncWorld(s3Transport: S3Answers.transport(failure: failure)))
    device.model.startConnect()
    let connect = try #require(device.model.connect)
    await connect.choose(.s3)
    connect.s3 = Self.s3Form()

    await connect.submitS3()

    #expect(connect.step == .s3Form)
    let shown = try #require(connect.failure)
    let expected =
      failure == .wrongKeys
      ? SyncSettingsErrors.presented(StorageError.unauthenticated, kind: .s3)
      : SyncSettingsErrors.presented(StorageError.unavailable("unreachable"), kind: .s3)
    #expect(shown.headline == expected.headline)
    #expect(try device.world.wiring.stores.credentials.allKeys().isEmpty)
    await device.shutDown()
  }

  @Test func shouldDisconnectAfterAnInPageConfirmationAndKeepTheLibraryAndTheSyncedCopy() async throws {
    let device = try await SettingsDevice.launch(try SyncWorld())
    _ = try await device.connect(device.world.folder) { _ in .create }
    let novel = try await LibraryService(store: device.store).create(title: "Ashfall", notes: "kept")
    await device.model.refresh()

    device.model.confirm(.disconnect)
    #expect(device.model.confirmation == .disconnect)
    #expect(try device.location() != .turnedOff(.disconnected))
    await device.model.disconnect()

    #expect(device.model.overview == .off(.disconnected))
    #expect(device.model.notice == .disconnected)
    #expect(device.model.confirmation == nil)
    #expect(try await LibraryService(store: device.store).notes(novel: novel) == "kept")
    #expect(SettingsFolders.holdsVault(device.world.folder))
    #expect(try await device.runtime.currentPhase == .detached)
    await device.shutDown()
  }

  @Test func shouldMoveTheLibraryBetweenTwoFolders() async throws {
    let device = try await SettingsDevice.launch(try SyncWorld())
    _ = try await device.connect(device.world.folder) { _ in .create }
    _ = try await LibraryService(store: device.store).create(title: "Ashfall", notes: "")
    try await SyncWorld.until("the novel is uploaded") { try await SyncWorld.isUploaded(device.store) }
    let target = try SettingsFolders.make("target")
    defer { try? FileManager.default.removeItem(at: target) }
    await device.model.refresh()

    device.model.startMove()
    let connect = try #require(device.model.connect)
    await connect.folderPicked(.success(target))
    guard case .confirmingMove(.localFolder) = connect.step else {
      Issue.record("the empty folder was not offered for the move: \(connect.step), \(String(describing: connect.failure))")
      return
    }
    await connect.move()

    guard case .finished(.moved(let location)) = connect.step else {
      Issue.record("the move did not finish: \(connect.step), \(String(describing: connect.failure))")
      return
    }
    #expect(location.settings.kind == .localFolder)
    #expect(SettingsFolders.holdsVault(target))
    await device.model.closeConnect()
    guard case .attached(let attached, _) = device.model.overview, case .localFolder(let folder) = attached.settings else {
      Issue.record("the overview does not show the new folder: \(device.model.overview)")
      return
    }
    #expect(folder.path == SyncLocalFolderSettings(url: target).path)
    #expect(SettingsFolders.holdsVault(device.world.folder))
    await device.shutDown()
  }

  @Test func shouldRefuseToMoveIntoAFolderThatHoldsALibrary() async throws {
    let device = try await SettingsDevice.launch(try SyncWorld())
    _ = try await device.connect(device.world.folder) { _ in .create }
    let other = try await SettingsDevice.launch(try SyncWorld())
    _ = try await other.connect(other.world.folder) { _ in .create }
    await device.model.refresh()

    device.model.startMove()
    let connect = try #require(device.model.connect)
    await connect.folderPicked(.success(other.world.folder))

    #expect(connect.step == .choosing)
    #expect(connect.failure?.headline == SyncSettingsErrors.presented(SyncMoveError.targetHoldsVault, kind: .localFolder).headline)
    await other.shutDown()
    await device.shutDown()
  }

  @Test func shouldOfferToContinueOrAbandonAnInterruptedMoveAndFinishItWhenContinued() async throws {
    let target = try SettingsFolders.make("flaky")
    defer { try? FileManager.default.removeItem(at: target) }
    let flaky = try FlakyReads(root: target)
    let targetPath = SyncLocalFolderSettings(url: target).path
    let device = try await SettingsDevice.launch(try SyncWorld()) { settings in
      guard case .localFolder(let folder) = settings, folder.path == targetPath else { return nil }
      return flaky
    }
    _ = try await device.connect(device.world.folder) { _ in .create }
    await device.model.refresh()
    device.model.startMove()
    let connect = try #require(device.model.connect)
    await connect.folderPicked(.success(target))
    await connect.move()

    #expect(connect.failure != nil)
    await device.model.closeConnect()
    guard case .moving(.movingOut(_, let journaled)?) = device.model.overview else {
      Issue.record("the interrupted move is not offered: \(device.model.overview)")
      return
    }
    #expect(journaled.kind == .localFolder)

    flaky.heal()
    await device.model.continueMove()

    #expect(device.model.failure == nil)
    guard case .attached(let attached, _) = device.model.overview, case .localFolder(let folder) = attached.settings else {
      Issue.record("the continued move did not finish: \(device.model.overview), \(String(describing: device.model.failure))")
      return
    }
    #expect(folder.path == targetPath)
    await device.shutDown()
  }

  @Test func shouldAbandonAnInterruptedMoveAndSyncWhereItWas() async throws {
    let target = try SettingsFolders.make("abandoned")
    defer { try? FileManager.default.removeItem(at: target) }
    let flaky = try FlakyReads(root: target)
    let targetPath = SyncLocalFolderSettings(url: target).path
    let device = try await SettingsDevice.launch(try SyncWorld()) { settings in
      guard case .localFolder(let folder) = settings, folder.path == targetPath else { return nil }
      return flaky
    }
    _ = try await device.connect(device.world.folder) { _ in .create }
    await device.model.refresh()
    device.model.startMove()
    let connect = try #require(device.model.connect)
    await connect.folderPicked(.success(target))
    await connect.move()
    await device.model.closeConnect()

    device.model.confirm(.abandonMove)
    await device.model.abandonMove()

    #expect(device.model.notice == .moveAbandoned)
    guard case .attached(let attached, _) = device.model.overview, case .localFolder(let folder) = attached.settings else {
      Issue.record("the abandoned move left no attached location: \(device.model.overview), \(String(describing: device.model.failure))")
      return
    }
    #expect(folder.path == SyncLocalFolderSettings(url: device.world.folder).path)
    await device.shutDown()
  }

  @Test func shouldFollowAMoveAnotherDeviceMadeIntoAFolderPickedHere() async throws {
    let (mover, follower, target) = try await Self.movedByAnotherDevice()
    defer { try? FileManager.default.removeItem(at: target) }
    guard case .attached(_, .vaultMoved(let notice)?) = follower.model.overview else {
      Issue.record("the follower was not told of the move: \(follower.model.overview)")
      return
    }

    await follower.model.startFollow(notice)
    let connect = try #require(follower.model.connect)
    #expect(connect.isImporterPresented)
    await connect.folderPicked(.success(target))

    guard case .finished(.moved(let location)) = connect.step else {
      Issue.record("following did not finish: \(connect.step), \(String(describing: connect.failure))")
      return
    }
    #expect(location.settings.kind == .localFolder)
    await follower.model.closeConnect()
    guard case .attached(let attached, _) = follower.model.overview, case .localFolder(let folder) = attached.settings else {
      Issue.record("the follower does not show the new folder: \(follower.model.overview)")
      return
    }
    #expect(folder.path == SyncLocalFolderSettings(url: target).path)
    await follower.shutDown()
    await mover.shutDown()
  }

  @Test func shouldStayAtTheOldLocationAfterAnotherDeviceMovedTheLibrary() async throws {
    let (mover, follower, target) = try await Self.movedByAnotherDevice()
    defer { try? FileManager.default.removeItem(at: target) }

    follower.model.confirm(.stayAfterMove)
    await follower.model.stayAfterMove()

    #expect(follower.model.notice == .stayed)
    #expect(follower.model.failure == nil)
    guard case .attached(let attached, let phase) = follower.model.overview, case .localFolder(let folder) = attached.settings else {
      Issue.record("the follower left its location: \(follower.model.overview)")
      return
    }
    #expect(folder.path == SyncLocalFolderSettings(url: mover.world.folder).path)
    if case .vaultMoved? = phase { Issue.record("the move notice still stops sync here") }
    await follower.shutDown()
    await mover.shutDown()
  }

  /// Two devices share a folder and a keychain; the first moves the library to a new folder and the second hears of it.
  private static func movedByAnotherDevice() async throws -> (SettingsDevice, SettingsDevice, URL) {
    let keychain = InMemoryKeychain()
    let mover = try await SettingsDevice.launch(try SyncWorld(keychain: keychain.device("mac")))
    _ = try await mover.connect(mover.world.folder) { _ in .create }
    let vault = try attachedVault(mover)
    let follower = try await SettingsDevice.launch(try SyncWorld(keychain: keychain.device("phone"), storage: mover.world.folder))
    _ = try await follower.connect(mover.world.folder) { _ in .join(vault) }
    keychain.deliver()
    let runtime = try follower.runtime
    try await SyncWorld.until("the follower has the key") {
      await runtime.foreground()
      return await runtime.currentPhase?.canSync == true
    }

    let target = try SettingsFolders.make("moved")
    await mover.model.refresh()
    mover.model.startMove()
    let connect = try #require(mover.model.connect)
    await connect.folderPicked(.success(target))
    await connect.move()
    guard case .finished(.moved) = connect.step else {
      Issue.record("the first device did not move: \(connect.step), \(String(describing: connect.failure))")
      return (mover, follower, target)
    }
    await mover.model.closeConnect()

    try await SyncWorld.until("the follower hears of the move", within: .seconds(30)) {
      await runtime.changeNotice()
      guard case .vaultMoved? = await runtime.currentPhase else { return false }
      return true
    }
    await follower.model.refresh()
    return (mover, follower, target)
  }

  private static func attachedVault(_ device: SettingsDevice) throws -> VaultID {
    guard case .attached(let location) = try device.location() else { throw SettingsTestError.notAttached }
    return location.vault
  }
}

nonisolated enum SettingsTestError: Error {
  case notAttached
}
