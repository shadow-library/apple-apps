import Foundation
import ShadowCore
import ShadowStore
import ShadowSync

public enum MemoirVaultError: ShadowError, Equatable {
  case invalidName(String)

  public var code: String {
    switch self {
    case .invalidName: "memoir_vault.invalid_name"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .invalidName(let name):
      "\"\(name)\" cannot name a vault: use 1 to \(MemoirVault.maximumNameLength) ASCII letters, digits, spaces, hyphens or underscores, not starting with a dot or a space and not ending in a store suffix."
    }
  }
}

/// A vault's three stores sit in sibling directories under `directory`, so each directory holds one database and can be excluded from backup on its own:
/// `<name>/vault.sqlite`, `<name>-activity/activity.sqlite` and `<name>-health/health.sqlite`.
public struct MemoirVault: Sendable, Equatable {
  public static let defaultName = "Default"
  public static let maximumNameLength = 64

  public let directory: URL
  public let name: String

  public init(directory: URL, name: String = defaultName) throws(MemoirVaultError) {
    guard Self.isValid(name) else { throw .invalidName(name) }
    self.directory = directory
    self.name = name
  }

  public func databaseURL(_ store: MemoirStoreKind) -> URL {
    directory.appending(path: name + store.directorySuffix, directoryHint: .isDirectory).appending(path: store.databaseName, directoryHint: .notDirectory)
  }

  private static func isValid(_ name: String) -> Bool {
    let bytes = Array(name.utf8)
    guard (1...maximumNameLength).contains(bytes.count), bytes.first != UInt8(ascii: "."), bytes.first != UInt8(ascii: " ") else { return false }
    let allowed: [UInt8] = [UInt8(ascii: " "), UInt8(ascii: "-"), UInt8(ascii: "_")]
    guard bytes.allSatisfy({ CommandPayload.isAlphanumeric($0) || allowed.contains($0) }) else { return false }
    let folded = name.lowercased()
    return !MemoirStoreKind.allCases.contains { !$0.directorySuffix.isEmpty && folded.hasSuffix($0.directorySuffix) }
  }
}

extension MemoirStoreKind {
  var directorySuffix: String {
    switch self {
    case .main: ""
    case .activity: "-activity"
    case .restricted: "-health"
    }
  }

  var databaseName: String {
    switch self {
    case .main: "vault.sqlite"
    case .activity: "activity.sqlite"
    case .restricted: "health.sqlite"
    }
  }
}

/// The only way to open a Memoir store: each kind gets its own registry, its admitted sync classes and its backup policy here and nowhere else. Only the
/// main store holds commands, so only it takes the replay projection.
public enum MemoirStore {
  public static func open(
    _ store: MemoirStoreKind, in vault: MemoirVault, wallClock: @escaping @Sendable () -> Date = { Date() }, projection: MemoirReconciler? = nil
  ) throws(StoreError) -> VaultStore {
    try open(store, at: .file(vault.databaseURL(store)), wallClock: wallClock, projection: projection)
  }

  public static func openInMemory(
    _ store: MemoirStoreKind, wallClock: @escaping @Sendable () -> Date = { Date() }, projection: MemoirReconciler? = nil
  ) throws(StoreError) -> VaultStore {
    try open(store, at: .inMemory, wallClock: wallClock, projection: projection)
  }

  private static func open(
    _ store: MemoirStoreKind, at location: StoreLocation, wallClock: @escaping @Sendable () -> Date, projection: MemoirReconciler?
  ) throws(StoreError) -> VaultStore {
    if store != .main, projection != nil { throw .invalidChange("only the main store holds commands, so only it takes the replay projection") }
    switch store {
    case .main:
      return try VaultStore.open(
        location, registry: MemoirSchema.mainRegistry, migrations: SyncEngine.migrations, wallClock: wallClock, reconciler: projection, backup: .adjustable,
        admittedClasses: [.general])
    case .activity:
      return try VaultStore.open(
        location, registry: MemoirSchema.activityRegistry, migrations: SyncEngine.migrations, wallClock: wallClock, backup: .alwaysExcluded,
        admittedClasses: [.general, .activity])
    case .restricted:
      return try VaultStore.open(
        location, registry: MemoirSchema.restrictedRegistry, migrations: SyncEngine.migrations, wallClock: wallClock, backup: .alwaysExcluded,
        admittedClasses: [.general, .health])
    }
  }
}
