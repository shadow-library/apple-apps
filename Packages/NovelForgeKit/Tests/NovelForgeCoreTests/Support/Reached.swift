import Synchronization

/// The cases one property test saw, kept by that test alone so a gate never counts what a test running beside it reached.
final class Reached: Sendable {
  private let seen = Mutex(Set<String>())

  var all: Set<String> { seen.withLock { $0 } }

  func insert(_ fact: String) {
    seen.withLock { _ = $0.insert(fact) }
  }

  func record(_ facts: Set<String>) {
    seen.withLock { $0.formUnion(facts) }
  }
}
