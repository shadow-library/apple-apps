nonisolated enum ShadowTokenTextInput {
  // TextField reports no change for Backspace on empty text, so an empty field holds a zero-width space that Backspace can delete.
  static let sentinel = "\u{200B}"

  enum Change: Hashable {
    case none
    case backspaceOnEmpty
    case text(String)
  }

  struct Interpretation: Hashable {
    let change: Change
    let raw: String?
  }

  static func raw(for text: String) -> String {
    text.isEmpty ? sentinel : text
  }

  static func clean(_ raw: String) -> String {
    raw.replacing(sentinel, with: "")
  }

  static func interpret(_ raw: String, currentText: String) -> Interpretation {
    if raw.isEmpty, currentText.isEmpty { return Interpretation(change: .backspaceOnEmpty, raw: sentinel) }
    let clean = clean(raw)
    return Interpretation(change: clean == currentText ? .none : .text(clean), raw: normalized(raw, for: clean))
  }

  static func normalized(_ raw: String, for text: String) -> String? {
    if text.isEmpty { return raw == sentinel ? nil : sentinel }
    return clean(raw) == text ? nil : text
  }
}
