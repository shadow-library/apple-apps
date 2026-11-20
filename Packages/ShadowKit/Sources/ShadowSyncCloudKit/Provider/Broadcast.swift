import Foundation
import Synchronization

final class Broadcast<Element: Sendable>: Sendable {
  private let continuations = Mutex<[UUID: AsyncStream<Element>.Continuation]>([:])
  private let policy: AsyncStream<Element>.Continuation.BufferingPolicy

  init(policy: AsyncStream<Element>.Continuation.BufferingPolicy = .unbounded) {
    self.policy = policy
  }

  func stream() -> AsyncStream<Element> {
    let (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: policy)
    let id = UUID()
    continuation.onTermination = { [weak self] _ in self?.continuations.withLock { _ = $0.removeValue(forKey: id) } }
    continuations.withLock { $0[id] = continuation }
    return stream
  }

  func yield(_ element: Element) {
    for continuation in continuations.withLock({ Array($0.values) }) { continuation.yield(element) }
  }

  func finish() {
    for continuation in continuations.withLock({ Array($0.values) }) { continuation.finish() }
  }
}
