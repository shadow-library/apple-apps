import Foundation
import ShadowStore

public enum NovelForgeStore {
  public static let registry = NovelForgeSchema.registry

  public static func open(at url: URL, wallClock: @escaping @Sendable () -> Date = { Date() }) throws(ProjectionError) -> VaultStore {
    try open(.file(url), wallClock: wallClock)
  }

  public static func openInMemory(wallClock: @escaping @Sendable () -> Date = { Date() }) throws(ProjectionError) -> VaultStore {
    try open(.inMemory, wallClock: wallClock)
  }

  private static func open(_ location: StoreLocation, wallClock: @escaping @Sendable () -> Date) throws(ProjectionError) -> VaultStore {
    let reconciler = try NovelForgeReconciler(registry: registry)
    do {
      return try VaultStore.open(location, registry: registry, migrations: reconciler.migrations, wallClock: wallClock, reconciler: reconciler)
    } catch {
      throw .store(error)
    }
  }
}
