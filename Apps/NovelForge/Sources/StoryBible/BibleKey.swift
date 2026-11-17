import Foundation

nonisolated enum BibleKey {
  static func slug(from text: String) -> String {
    var result = ""
    var separated = false
    for character in text.lowercased() {
      guard character.isLetter || character.isNumber else {
        separated = true
        continue
      }
      if separated && !result.isEmpty { result.append("-") }
      separated = false
      result.append(character)
    }
    return result.precomposedStringWithCanonicalMapping
  }
}
