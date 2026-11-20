import ShadowCore

public enum RecoveryPhraseError: ShadowError, Equatable {
  case wrongWordCount(found: Int)
  case unknownWord(position: Int)
  case badChecksum

  public var code: String {
    switch self {
    case .wrongWordCount: "recovery-phrase.wrong-word-count"
    case .unknownWord: "recovery-phrase.unknown-word"
    case .badChecksum: "recovery-phrase.bad-checksum"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .wrongWordCount(let found): "A recovery phrase has \(RecoveryPhrase.wordCount) words, not \(found)."
    case .unknownWord(let position): "Word \(position) is not in the recovery word list."
    case .badChecksum: "The recovery phrase is not valid; a word is wrong or out of order."
    }
  }
}
