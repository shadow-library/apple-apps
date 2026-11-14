import Foundation

nonisolated public enum ShadowTokenComparison: Hashable, Sendable, CaseIterable {
  case caseInsensitive
  case caseSensitive
}

nonisolated public enum ShadowTokenOutcome: Hashable, Sendable {
  case added
  case empty
  case duplicate(index: Int)
  case limitReached
  case invalid

  public var isRejection: Bool {
    switch self {
    case .added, .empty: false
    case .duplicate, .limitReached, .invalid: true
    }
  }
}

nonisolated public enum ShadowTokenDeletion: Hashable, Sendable {
  case none
  case selected(index: Int)
  case removed(index: Int)
}

nonisolated public struct ShadowTokenRules<Value: Hashable & Sendable>: Sendable {
  public let label: @Sendable (Value) -> String
  public let parse: @Sendable (String) -> Value?
  public var separators: Set<Character>
  public var maximumCount: Int?
  public var comparison: ShadowTokenComparison
  public var suggestionLimit: Int

  public init(
    label: @escaping @Sendable (Value) -> String,
    parse: @escaping @Sendable (String) -> Value?,
    separators: Set<Character> = [",", "\n"],
    maximumCount: Int? = nil,
    comparison: ShadowTokenComparison = .caseInsensitive,
    suggestionLimit: Int = 6
  ) {
    self.label = label
    self.parse = parse
    self.separators = separators
    self.maximumCount = maximumCount.map { max($0, 0) }
    self.comparison = comparison
    self.suggestionLimit = max(suggestionLimit, 0)
  }

  public func duplicateIndex(of value: Value, in tokens: [Value]) -> Int? {
    let key = key(for: value)
    return tokens.firstIndex { $0 == value || self.key(for: $0) == key }
  }

  public func isAtLimit(_ tokens: [Value]) -> Bool {
    maximumCount.map { tokens.count >= $0 } ?? false
  }

  public func suggestions(from candidates: [Value], matching text: String, excluding tokens: [Value]) -> [Value] {
    let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty, !isAtLimit(tokens) else { return [] }
    let matches = candidates.filter { duplicateIndex(of: $0, in: tokens) == nil && label($0).localizedStandardContains(query) }
    let prefixed = matches.filter { label($0).range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil }
    let rest = matches.filter { label($0).range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) == nil }
    return Array((prefixed + rest).prefix(suggestionLimit))
  }

  private func key(for value: Value) -> String {
    let label = label(value)
    return comparison == .caseInsensitive ? label.folding(options: .caseInsensitive, locale: nil) : label
  }
}

nonisolated extension ShadowTokenRules where Value == String {
  public init(
    separators: Set<Character> = [",", "\n"],
    maximumCount: Int? = nil,
    comparison: ShadowTokenComparison = .caseInsensitive,
    suggestionLimit: Int = 6
  ) {
    self.init(
      label: { $0 }, parse: { $0 }, separators: separators, maximumCount: maximumCount, comparison: comparison, suggestionLimit: suggestionLimit)
  }
}

nonisolated public struct ShadowTokenEntry<Value: Hashable & Sendable>: Hashable, Sendable {
  public var tokens: [Value]
  public var text: String
  public var selection: Int?

  public init(tokens: [Value] = [], text: String = "", selection: Int? = nil) {
    self.tokens = tokens
    self.text = text
    self.selection = selection.flatMap { tokens.indices.contains($0) ? $0 : nil }
  }

  @discardableResult
  public mutating func type(_ newText: String, rules: ShadowTokenRules<Value>) -> [ShadowTokenOutcome] {
    selection = nil
    let pieces = newText.split(omittingEmptySubsequences: false) { rules.separators.contains($0) }
    guard pieces.count > 1, let remainder = pieces.last else {
      text = newText
      return []
    }
    var outcomes: [ShadowTokenOutcome] = []
    var rejected: String?
    for piece in pieces.dropLast() {
      text = String(piece)
      let outcome = commit(rules: rules)
      outcomes.append(outcome)
      if outcome == .invalid || outcome == .limitReached { rejected = String(piece) }
    }
    text = remainder.isEmpty ? (rejected ?? "") : String(remainder)
    return outcomes
  }

  @discardableResult
  public mutating func commit(rules: ShadowTokenRules<Value>) -> ShadowTokenOutcome {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      text = ""
      return .empty
    }
    guard let value = rules.parse(trimmed) else { return .invalid }
    let outcome = add(value, rules: rules)
    if outcome != .limitReached { text = "" }
    return outcome
  }

  @discardableResult
  public mutating func add(_ value: Value, rules: ShadowTokenRules<Value>) -> ShadowTokenOutcome {
    if let index = rules.duplicateIndex(of: value, in: tokens) {
      selection = index
      return .duplicate(index: index)
    }
    guard !rules.isAtLimit(tokens) else { return .limitReached }
    tokens.append(value)
    selection = nil
    return .added
  }

  @discardableResult
  public mutating func deleteBackward() -> ShadowTokenDeletion {
    guard text.isEmpty, !tokens.isEmpty else { return .none }
    guard let selection else {
      selection = tokens.count - 1
      return .selected(index: tokens.count - 1)
    }
    remove(at: selection)
    return .removed(index: selection)
  }

  public mutating func remove(at index: Int) {
    guard tokens.indices.contains(index) else { return }
    tokens.remove(at: index)
    guard let current = selection else { return }
    if current == index {
      selection = nil
    } else if current > index {
      selection = current - 1
    }
  }
}
