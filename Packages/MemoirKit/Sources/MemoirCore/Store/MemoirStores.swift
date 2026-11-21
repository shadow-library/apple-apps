import Foundation
import ShadowStore
import ShadowSync

/// A vault's three stores, opened together so a write can only reach the store of its class: `store(of:)` is the one route from a sync class to a store.
public struct MemoirStores: Sendable {
  public let main: VaultStore
  public let activity: VaultStore
  public let restricted: VaultStore

  public static func open(in vault: MemoirVault, wallClock: @escaping @Sendable () -> Date = { Date() }) throws(StoreError) -> MemoirStores {
    MemoirStores(
      main: try MemoirStore.open(.main, in: vault, wallClock: wallClock), activity: try MemoirStore.open(.activity, in: vault, wallClock: wallClock),
      restricted: try MemoirStore.open(.restricted, in: vault, wallClock: wallClock))
  }

  public static func openInMemory(wallClock: @escaping @Sendable () -> Date = { Date() }) throws(StoreError) -> MemoirStores {
    MemoirStores(
      main: try MemoirStore.openInMemory(.main, wallClock: wallClock), activity: try MemoirStore.openInMemory(.activity, wallClock: wallClock),
      restricted: try MemoirStore.openInMemory(.restricted, wallClock: wallClock))
  }

  public func store(_ kind: MemoirStoreKind) -> VaultStore {
    switch kind {
    case .main: main
    case .activity: activity
    case .restricted: restricted
    }
  }

  public func store(of syncClass: SyncClass) -> VaultStore {
    store(MemoirStoreKind(holding: syncClass))
  }
}
