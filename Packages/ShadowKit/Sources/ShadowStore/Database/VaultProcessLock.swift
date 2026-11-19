import Foundation
import Synchronization

/// An exclusive `flock` on a file beside a vault's database, for work only one process may do on the vault at a time. The kernel drops the lock when its
/// process ends, crash included, so a file left behind never holds the vault. An in-memory store has no file and every acquire succeeds.
public final class VaultProcessLock: Sendable {
  public enum Purpose: String, CaseIterable, Sendable {
    case jobs
  }

  private let descriptor: Mutex<Int32?>

  private init(descriptor: Int32?) {
    self.descriptor = Mutex(descriptor)
  }

  deinit {
    release()
  }

  static func fileName(_ purpose: Purpose, database: String) -> String { "\(database)-\(purpose.rawValue).lock" }

  /// Nil while another process, or another acquire in this one, holds it.
  static func acquire(_ purpose: Purpose, directory: URL?, database: String?) throws(StoreError) -> VaultProcessLock? {
    guard let directory, let database else { return VaultProcessLock(descriptor: nil) }
    let name = fileName(purpose, database: database)
    let path = directory.appending(path: name).path(percentEncoded: false)
    let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw .processLock(path: name, reason: String(cString: strerror(errno))) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let failure = errno
      close(descriptor)
      guard failure == EWOULDBLOCK else { throw .processLock(path: name, reason: String(cString: strerror(failure))) }
      return nil
    }
    return VaultProcessLock(descriptor: descriptor)
  }

  public func release() {
    let taken = descriptor.withLock { held -> Int32? in
      let taken = held
      held = nil
      return taken
    }
    guard let descriptor = taken else { return }
    flock(descriptor, LOCK_UN)
    close(descriptor)
  }
}

extension VaultStore {
  /// Nil while another process holds the vault's lock for `purpose`.
  public func acquireProcessLock(_ purpose: VaultProcessLock.Purpose) throws(StoreError) -> VaultProcessLock? {
    try VaultProcessLock.acquire(purpose, directory: directory, database: databaseName)
  }
}
