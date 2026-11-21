import Foundation
import Observation
import ShadowSync
import ShadowSyncRuntime
import ShadowSyncS3

/// One pass through choosing a storage: turning sync on (with an explicit create or join, except on iCloud), moving the library to another storage, or
/// following a move another device made. Nothing is attached, moved or followed until the last step, and cancelling puts back any S3 keys it saved.
@MainActor
@Observable
final class SyncConnectModel {
  enum Purpose: Equatable {
    case connect
    case move
    /// `target` is the new location as the notice names it, without this device's folder access or keys.
    case follow(target: SyncProviderSettings)
  }

  enum Work: Equatable {
    case checking
    case attaching
    case moving
    case following
  }

  enum Finish: Equatable {
    case attached(SyncPhase)
    case moved(SyncLocation)
    case superseded(VaultMoveNotice)
  }

  enum Step: Equatable {
    case choosing
    case s3Form
    case discovered(SyncProviderSettings, VaultDiscovery)
    case confirmingMove(SyncProviderSettings)
    case working(Work)
    case finished(Finish)
  }

  private struct SavedKeys {
    let settings: SyncS3Settings
    let previous: S3Credentials?
  }

  let purpose: Purpose
  let options: [SyncProviderOption]
  private(set) var step = Step.choosing
  var s3 = SyncS3Form()
  private(set) var s3Issue: SyncS3Form.Issue?
  /// The S3 storage answered that it does not honour conditional writes; two devices setting up at the same moment could then both win.
  private(set) var conditionalWritesUnsupported = false
  var isImporterPresented = false
  var failure: PresentedError?

  private let runtime: SyncRuntime
  private let wiring: SyncWiring
  /// Every S3 keychain item this pass wrote, by item name, with what it held before the first write.
  private var savedKeys: [String: SavedKeys] = [:]

  init(purpose: Purpose, runtime: SyncRuntime, wiring: SyncWiring) {
    self.purpose = purpose
    self.runtime = runtime
    self.wiring = wiring
    options = SyncProviderOption.all(hasICloud: wiring.cloudKit != nil)
  }

  var isWorking: Bool {
    guard case .working = step else { return false }
    return true
  }

  /// For a follow: goes straight to what the notice's storage needs on this device.
  func begin() async {
    guard case .follow(let target) = purpose else { return }
    switch target {
    case .iCloud(let settings):
      guard wiring.cloudKit?.settings == settings else {
        failure = PresentedError(headline: SyncProviderOption(kind: .iCloud, unavailability: .notSignedForICloud).reason ?? "", detail: nil)
        return
      }
      await check(target)
    case .localFolder:
      isImporterPresented = true
    case .s3(let settings):
      let stored: S3Credentials?
      do throws(SyncCredentialError) {
        stored = try wiring.stores.s3Credentials.load(for: settings)
      } catch {
        stored = nil
      }
      s3 = SyncS3Form(settings)
      if stored == nil {
        step = .s3Form
      } else {
        await check(target)
      }
    case .oneDrive, .googleDrive:
      failure = PresentedError(headline: SyncProviderOption(kind: target.kind, unavailability: .noAppRegistration).reason ?? "", detail: nil)
    }
  }

  func choose(_ kind: SyncProviderKind) async {
    guard !isWorking, options.first(where: { $0.kind == kind })?.isAvailable == true else { return }
    failure = nil
    switch kind {
    case .iCloud:
      guard let cloudKit = wiring.cloudKit else { return }
      await check(.iCloud(cloudKit.settings))
    case .localFolder:
      isImporterPresented = true
    case .s3:
      s3Issue = nil
      step = .s3Form
    case .oneDrive, .googleDrive:
      return
    }
  }

  func folderPicked(_ result: Result<URL, any Error>) async {
    switch result {
    case .failure(let error):
      failure = SyncSettingsErrors.presented(StorageError.unavailable(error.localizedDescription), kind: .localFolder)
    case .success(let url):
      guard !holdsAppData(url) else {
        failure = PresentedError(headline: String(localized: "Choose a folder outside Novel Forge's own data.", table: "SyncSettings"), detail: nil)
        return
      }
      do throws(StorageError) {
        await check(.localFolder(try LocalFolderAccess.settings(forPicked: url)))
      } catch {
        failure = SyncSettingsErrors.presented(error, kind: .localFolder)
      }
    }
  }

  func s3Edited() {
    s3Issue = nil
  }

  /// Probes the storage with the typed keys before saving anything, so wrong keys or an unreachable endpoint leave the keychain as it was.
  func submitS3() async {
    guard !isWorking else { return }
    failure = nil
    let validated: SyncS3Form.Validated
    switch s3.validate() {
    case .failure(let issue):
      s3Issue = issue
      return
    case .success(let value):
      validated = value
    }
    s3Issue = nil
    step = .working(.checking)
    let supported: Bool
    do throws(StorageError) {
      supported = try await wiring.s3Provider(validated.configuration, credentials: validated.credentials).probeConditionalWrites()
    } catch {
      step = .s3Form
      failure = SyncSettingsErrors.presented(error, kind: .s3)
      return
    }
    conditionalWritesUnsupported = !supported
    let settings = SyncS3Settings(validated.configuration.withConditionalWrites(supported))
    do throws(SyncCredentialError) {
      try saveKeys(validated.credentials, for: settings)
    } catch {
      step = .s3Form
      failure = SyncSettingsErrors.presented(error, kind: .s3)
      return
    }
    await check(.s3(settings))
  }

  func attach(_ choice: VaultChoice) async {
    guard case .discovered(let settings, _) = step else { return }
    await attach(settings, choice: choice)
  }

  func move() async {
    guard case .confirmingMove(let settings) = step else { return }
    failure = nil
    step = .working(.moving)
    do throws(SyncMoveError) {
      finish(try await runtime.moveVault(to: settings))
    } catch {
      step = .confirmingMove(settings)
      failure = SyncSettingsErrors.presented(error, kind: settings.kind)
    }
  }

  func back() {
    guard !isWorking else { return }
    failure = nil
    s3Issue = nil
    step = .choosing
  }

  /// Puts back every S3 item this pass saved, unless the attached location or a move in progress now names it.
  func cancel() {
    defer { savedKeys = [:] }
    let named = namedKeyItems()
    for (item, saved) in savedKeys where !named.contains(item) {
      do throws(SyncCredentialError) {
        if let previous = saved.previous {
          try wiring.stores.s3Credentials.save(previous, for: saved.settings)
        } else {
          try wiring.stores.s3Credentials.remove(for: saved.settings)
        }
      } catch {
        failure = SyncSettingsErrors.presented(error, kind: .s3)
      }
    }
  }

  private func check(_ settings: SyncProviderSettings) async {
    failure = nil
    if case .follow = purpose {
      await follow(settings)
      return
    }
    step = .working(.checking)
    let discovery: VaultDiscovery
    do throws(SyncStartupError) {
      discovery = try await runtime.discover(settings)
    } catch {
      step = settings.kind == .s3 ? .s3Form : .choosing
      failure = SyncSettingsErrors.presented(error, kind: settings.kind)
      return
    }
    switch (purpose, discovery, settings.kind) {
    case (.move, .empty, _): step = .confirmingMove(settings)
    case (.move, _, _):
      step = settings.kind == .s3 ? .s3Form : .choosing
      failure = SyncSettingsErrors.presented(SyncMoveError.targetHoldsVault, kind: settings.kind)
    case (_, .empty, .iCloud): await attach(settings, choice: .create)
    case (_, .found(let vault), .iCloud): await attach(settings, choice: .join(vault))
    default: step = .discovered(settings, discovery)
    }
  }

  private func attach(_ settings: SyncProviderSettings, choice: VaultChoice) async {
    failure = nil
    step = .working(.attaching)
    do throws(SyncStartupError) {
      step = .finished(.attached(try await runtime.attach(settings, choice: choice)))
    } catch {
      failure = SyncSettingsErrors.presented(error, kind: settings.kind)
      switch error {
      case .setup(.vaultMismatch), .setup(.vaultNotFound): await check(settings)
      default: step = settings.kind == .iCloud ? .choosing : .discovered(settings, Self.discovery(for: choice))
      }
    }
  }

  private func follow(_ settings: SyncProviderSettings) async {
    step = .working(.following)
    do throws(SyncMoveError) {
      finish(try await runtime.followMove(to: settings))
    } catch {
      step = settings.kind == .s3 ? .s3Form : .choosing
      failure = SyncSettingsErrors.presented(error, kind: settings.kind)
    }
  }

  private func finish(_ outcome: SyncMoveOutcome) {
    switch outcome {
    case .moved(_, let location): step = .finished(.moved(location))
    case .superseded(let notice): step = .finished(.superseded(notice))
    }
  }

  private func saveKeys(_ credentials: S3Credentials, for settings: SyncS3Settings) throws(SyncCredentialError) {
    let store = wiring.stores.s3Credentials
    let previous: S3Credentials?
    do {
      previous = try store.load(for: settings)
    } catch {
      guard error == .unreadable else { throw error }
      previous = nil
    }
    let item = S3CredentialStore.itemName(for: settings)
    if savedKeys[item] == nil { savedKeys[item] = SavedKeys(settings: settings, previous: previous) }
    try store.save(credentials, for: settings)
  }

  /// The S3 items the attached location and a move in progress use; when either cannot be read, every item this pass saved counts as used.
  private func namedKeyItems() -> Set<String> {
    let everything = Set(savedKeys.keys)
    guard let store = try? wiring.locationStore(), let record = try? store.load() else { return everything }
    let journal: SyncMoveJournal?
    do throws(SyncMoveError) {
      journal = try SyncMoveJournalStore(beside: store).load()
    } catch {
      return everything
    }
    var named: Set<String> = []
    if case .attached(let location) = record, case .s3(let settings) = location.settings { named.insert(S3CredentialStore.itemName(for: settings)) }
    if case .s3(let settings)? = journal?.target.settings { named.insert(S3CredentialStore.itemName(for: settings)) }
    return named
  }

  /// The app's own files (the vault, the location file, CloudKit's index) must never sit in a sync folder, nor a sync folder in them.
  private func holdsAppData(_ url: URL) -> Bool {
    let picked = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
    let own = wiring.paths.location.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().pathComponents
    return picked.starts(with: own) || own.starts(with: picked)
  }

  private static func discovery(for choice: VaultChoice) -> VaultDiscovery {
    switch choice {
    case .create: .empty
    case .join(let vault): .found(vault)
    }
  }
}
