import Synchronization

/// The owner's declaration on this device that they are an adult, which unrestricted writing needs besides the build's flag. It can only withhold what
/// `UnrestrictedWriting.isAvailable` allows, and engines read it at each decision, so a withdrawal holds from the next turn, job or apply.
public final class AgeGate: Sendable {
  private let passed: Mutex<Bool>

  public init(passed: Bool) {
    self.passed = Mutex(passed)
  }

  public var isPassed: Bool { passed.withLock { $0 } }

  public func update(passed: Bool) {
    self.passed.withLock { $0 = passed }
  }
}
