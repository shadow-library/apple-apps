import Synchronization

/// CloudKit's production environment allows one sync engine per database, so one live `CKZoneClient` per container in a process.
final class CloudKitEngineClaim: Sendable {
  private static let claimed = Mutex<Set<String>>([])

  let container: String

  private init(container: String) {
    self.container = container
  }

  static func claim(_ container: String) -> CloudKitEngineClaim? {
    claimed.withLock { $0.insert(container).inserted } ? CloudKitEngineClaim(container: container) : nil
  }

  deinit {
    Self.claimed.withLock { _ = $0.remove(container) }
  }
}
