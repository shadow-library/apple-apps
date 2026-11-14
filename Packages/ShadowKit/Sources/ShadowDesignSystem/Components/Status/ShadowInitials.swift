import Foundation

nonisolated public enum ShadowInitials {
  public static func make(from name: String) -> String {
    let initials = name.split(whereSeparator: \.isWhitespace).compactMap(initial(of:))
    guard let first = initials.first else { return "" }
    guard initials.count > 1, let last = initials.last else { return first }
    return first + last
  }

  private static func initial(of word: Substring) -> String? {
    guard let character = word.first(where: isInitialCandidate) else { return nil }
    let uppercased = String(character).uppercased()
    return uppercased.count > 1 && character.isLetter ? String(uppercased.prefix(1)) : uppercased
  }

  private static func isInitialCandidate(_ character: Character) -> Bool {
    if character.isLetter || character.isNumber { return true }
    guard let scalar = character.unicodeScalars.first else { return false }
    return scalar.properties.isEmojiPresentation || (scalar.properties.isEmoji && scalar.value > 0xFF)
  }
}
