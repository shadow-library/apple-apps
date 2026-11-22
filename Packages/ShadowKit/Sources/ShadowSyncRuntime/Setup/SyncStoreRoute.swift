import Foundation
import ShadowCore
import ShadowSync

/// A store that syncs beside a vault's primary store, at the same location, as a vault of its own: under `stores/<name>/`, with an id derived from the
/// primary vault's, sealed with the primary vault's keys. One key ring, recovery phrase and key exchange cover every store; the primary's listings never
/// reach under `stores/`, and the derived id keeps the route's device marker and files apart from the primary's.
public struct SyncStoreRoute: Hashable, Sendable, CustomStringConvertible {
  public static let maximumNameLength = 32
  static let vaultDomain = "com.shadow.library.shadowsyncruntime.store-route"

  public let name: String

  /// 1 to 32 lower-case ASCII letters, digits and hyphens; the name is part of the stored layout, so it never changes once a store synced under it.
  public init?(_ name: String) {
    let bytes = Array(name.utf8)
    guard (1...Self.maximumNameLength).contains(bytes.count), bytes.allSatisfy(Self.isAllowed) else { return nil }
    self.name = name
  }

  public var description: String { name }

  public var prefix: String { "stores/\(name)/" }

  public func vault(of primary: VaultID) -> VaultID {
    guard let vault = VaultID(derivedID(Self.vaultDomain, "\(primary.rawValue)/\(name)").uuidString.lowercased()) else {
      preconditionFailure("a lower-case UUID is a vault id")
    }
    return vault
  }

  public func location(of primary: SyncLocation) -> SyncLocation {
    SyncLocation(settings: primary.settings, vault: vault(of: primary.vault), account: primary.account)
  }

  private static func isAllowed(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"): true
    default: false
    }
  }
}

/// `base` as a route's engine sees it: keys gain the route's prefix on the way in and lose it on the way out, so the route reads and writes its own vault
/// layout and never lists the primary's.
public struct RoutedStorageProvider: StorageProvider {
  public let base: any StorageProvider
  public let route: SyncStoreRoute

  public init(base: any StorageProvider, route: SyncStoreRoute) {
    self.base = base
    self.route = route
  }

  public var capabilities: StorageCapabilities { base.capabilities }

  public func list(prefix: String, after cursor: ListCursor?) async throws(StorageError) -> ListPage {
    let page: ListPage
    do {
      page = try await base.list(prefix: route.prefix + prefix, after: cursor)
    } catch {
      throw inner(error)
    }
    return ListPage(objects: page.objects.compactMap { object in inner(object.key).map { StorageObject(key: $0, size: object.size) } }, next: page.next)
  }

  public func get(_ key: ObjectKey) async throws(StorageError) -> Data {
    let routed = try outer(key)
    do {
      return try await base.get(routed)
    } catch {
      throw inner(error)
    }
  }

  public func put(_ key: ObjectKey, data: Data, condition: PutCondition) async throws(StorageError) -> PutReceipt {
    let routed = try outer(key)
    do {
      return try await base.put(routed, data: data, condition: condition)
    } catch {
      throw inner(error)
    }
  }

  public func delete(_ keys: [ObjectKey]) async throws(StorageError) {
    var routed: [ObjectKey] = []
    for key in keys { routed.append(try outer(key)) }
    do {
      try await base.delete(routed)
    } catch {
      throw inner(error)
    }
  }

  public func changeNotices() -> AsyncStream<Void> {
    base.changeNotices()
  }

  private func outer(_ key: ObjectKey) throws(StorageError) -> ObjectKey {
    guard let routed = ObjectKey(route.prefix + key.rawValue) else { throw .underlying("the key is too long to store under \(route.prefix)") }
    return routed
  }

  private func inner(_ key: ObjectKey) -> ObjectKey? {
    guard key.hasPrefix(route.prefix) else { return nil }
    return ObjectKey(String(key.rawValue.dropFirst(route.prefix.count)))
  }

  private func inner(_ error: StorageError) -> StorageError {
    switch error {
    case .notFound(let key): .notFound(inner(key) ?? key)
    case .alreadyExists(let key): .alreadyExists(inner(key) ?? key)
    case .keyConflict(let key): .keyConflict(inner(key) ?? key)
    case .tooLarge(let key, let limit): .tooLarge(inner(key) ?? key, limit: limit)
    case .quotaExceeded, .rateLimited, .unauthenticated, .unavailable, .underlying: error
    }
  }
}
