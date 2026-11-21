import Foundation
import ShadowSync
import Synchronization

/// A recovery phrase shown to the user and not yet recorded. `RecoverySetup.commit` records it only once the user has typed back the words at
/// `confirmationPositions`; after that the phrase is dropped from memory and cannot be shown again.
public final class PendingRecoveryPhrase: Sendable {
  public static let confirmationCount = 3

  /// One-based positions in the phrase, ascending.
  public let confirmationPositions: [Int]
  private let state: Mutex<RecoveryPhrase?>

  init(secret: RecoverySecret, confirmationPositions: [Int]) {
    self.confirmationPositions = confirmationPositions.sorted()
    state = Mutex(RecoveryPhrase(secret: secret))
  }

  convenience init() {
    var generator = SystemRandomNumberGenerator()
    let positions = Array((1...RecoveryPhrase.wordCount).shuffled(using: &generator).prefix(Self.confirmationCount))
    self.init(secret: .generate(), confirmationPositions: positions)
  }

  /// Nil once the phrase has been recorded.
  public var phrase: RecoveryPhrase? {
    state.withLock { $0 }
  }

  public var isRecorded: Bool {
    state.withLock { $0 == nil }
  }

  func confirmedPhrase(_ confirmation: [Int: String]) throws(RecoveryError) -> RecoveryPhrase {
    guard let phrase else { throw .setupFinished }
    let words = phrase.words
    let wrong = confirmationPositions.filter { position in confirmation[position].map(Self.normalise) != words[position - 1] }
    guard wrong.isEmpty else { throw .confirmationMismatch(positions: wrong) }
    return phrase
  }

  func markRecorded() {
    state.withLock { $0 = nil }
  }

  private static func normalise(_ word: String) -> String {
    word.decomposedStringWithCompatibilityMapping.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

extension PendingRecoveryPhrase: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String { "PendingRecoveryPhrase(redacted)" }
  public var debugDescription: String { description }
}

extension PendingRecoveryPhrase: CustomReflectable {
  public var customMirror: Mirror {
    Mirror(self, children: ["confirmationPositions": confirmationPositions, "isRecorded": isRecorded], displayStyle: .class)
  }
}
