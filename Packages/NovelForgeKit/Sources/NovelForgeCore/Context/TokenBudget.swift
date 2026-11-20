import ShadowText

// apps/novel-forge-server/src/modules/ai/context/token-budget.ts
public struct TruncatedText: Sendable, Equatable {
  public let text: String
  public let truncated: Bool

  public init(text: String, truncated: Bool) {
    self.text = text
    self.truncated = truncated
  }
}

public enum BudgetOmissionReason: String, Sendable, Equatable {
  case budget
}

public struct BudgetOmission: Sendable, Equatable {
  public let key: String
  public let reason: BudgetOmissionReason
  public let tokens: Int?

  public init(key: String, reason: BudgetOmissionReason, tokens: Int? = nil) {
    self.key = key
    self.reason = reason
    self.tokens = tokens
  }
}

public struct BudgetResult<Section: BudgetedSection>: Sendable {
  public let fitting: [Section]
  public let omitted: [BudgetOmission]

  public init(fitting: [Section], omitted: [BudgetOmission]) {
    self.fitting = fitting
    self.omitted = omitted
  }
}

public protocol BudgetedSection: Sendable {
  var key: String { get }
  var tokens: Int { get }
  var required: Bool { get }
  var priority: Int? { get }
}

extension BudgetedSection {
  public var required: Bool { false }
  public var priority: Int? { nil }
}

/// Deviation from the reference's exact o200k_base count: a deterministic estimate that never falls as a prefix or suffix grows and errs high.
public func countTokens(_ text: String) -> Int {
  var hundredths = 0
  var kind: RunKind?
  var length = 0
  for scalar in text.unicodeScalars {
    let next = RunKind(scalar.value)
    if next == kind && next.isRun {
      length += 1
      continue
    }
    if let kind { hundredths += kind.cost(length: length) }
    kind = next
    length = 1
  }
  if let kind { hundredths += kind.cost(length: length) }
  return (hundredths + 99) / 100
}

private enum RunKind {
  case letter
  case digit
  case space
  case control
  case symbol
  case wide
  case alphabetic
  case otherBMP
  case astral

  init(_ code: UInt32) {
    switch code {
    case 0x41...0x5A, 0x61...0x7A: self = .letter
    case 0x30...0x39: self = .digit
    case 0x20: self = .space
    case 0x00...0x1F, 0x7F: self = .control
    case 0x21...0x7E: self = .symbol
    case 0x3040...0x30FF, 0x3400...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF: self = .wide
    case 0x80...0x2FFF: self = Self.isLetter(code) ? .alphabetic : .otherBMP
    case 0x10000...: self = .astral
    default: self = .otherBMP
    }
  }

  var isRun: Bool {
    switch self {
    case .letter, .digit, .space, .control, .symbol: true
    case .wide, .alphabetic, .otherBMP, .astral: false
    }
  }

  func cost(length: Int) -> Int {
    switch self {
    case .letter: 110 + 65 * max(0, (length - 2) / 8)
    case .digit: 125 * ((length + 2) / 3)
    case .space: length == 1 ? 0 : 50 + 5 * length
    case .control: 105 + 10 * length
    case .symbol: 80 + 25 * length
    case .wide, .otherBMP: 100 * length
    case .alphabetic: 45 * length
    case .astral: 250 * length
    }
  }

  private static func isLetter(_ code: UInt32) -> Bool {
    guard let scalar = Unicode.Scalar(code) else { return false }
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
    default: return false
    }
  }
}

private enum Separators {
  static let paragraphBreak = compile(#"\n\n+"#)
  static let whitespace = compile(#"\s+"#)

  private static func compile(_ source: String) -> JSRegex {
    do {
      return try JSRegex(source)
    } catch {
      preconditionFailure("invalid constant pattern \(source)")
    }
  }
}

private enum WordRunEnd {
  case head
  case tail
}

public func leadingChars(_ text: String, maxTokens: Int) -> String {
  let chars = text.jsCodePoints
  return chars.prefix(longestFit(of: chars.count, maxTokens: maxTokens) { countTokens(chars.prefix($0).joined()) }).joined()
}

public func trailingChars(_ text: String, maxTokens: Int) -> String {
  let chars = text.jsCodePoints
  return chars.suffix(longestFit(of: chars.count, maxTokens: maxTokens) { countTokens(chars.suffix($0).joined()) }).joined()
}

public func truncateAtParagraph(_ text: String, maxTokens: Int) -> TruncatedText {
  guard maxTokens != 0 else { return TruncatedText(text: "", truncated: true) }
  var accumulated = ""
  var usedTokens = 0
  for paragraph in text.jsSplit(Separators.paragraphBreak) {
    let separator = accumulated.isEmpty ? "" : "\n\n"
    let needed = (accumulated.isEmpty ? 0 : countTokens("\n\n")) + countTokens(paragraph)
    if usedTokens + needed <= maxTokens {
      accumulated += separator + paragraph
      usedTokens += needed
    } else if accumulated.isEmpty {
      return TruncatedText(text: wordRun(paragraph.jsSplit(Separators.whitespace), maxTokens: maxTokens, end: .head), truncated: true)
    } else {
      return TruncatedText(text: accumulated, truncated: true)
    }
  }
  return TruncatedText(text: accumulated, truncated: false)
}

public func truncateAtParagraphTail(_ text: String, maxTokens: Int) -> TruncatedText {
  guard maxTokens != 0 else { return TruncatedText(text: "", truncated: true) }
  var accumulated = ""
  var usedTokens = 0
  for paragraph in text.jsSplit(Separators.paragraphBreak).reversed() {
    let separator = accumulated.isEmpty ? "" : "\n\n"
    let needed = (accumulated.isEmpty ? 0 : countTokens("\n\n")) + countTokens(paragraph)
    if usedTokens + needed <= maxTokens {
      accumulated = paragraph + separator + accumulated
      usedTokens += needed
    } else if accumulated.isEmpty {
      return TruncatedText(text: wordRun(paragraph.jsSplit(Separators.whitespace), maxTokens: maxTokens, end: .tail), truncated: true)
    } else {
      return TruncatedText(text: accumulated, truncated: true)
    }
  }
  return TruncatedText(text: accumulated, truncated: false)
}

public func applyBudget<Section: BudgetedSection>(_ sections: [Section], budgetTokens: Int) -> BudgetResult<Section> {
  var kept = Set<Int>()
  var omitted: [BudgetOmission] = []
  var used = sections.reduce(0) { $0 + ($1.required ? $1.tokens : 0) }
  let byPriority = sections.indices.sorted { left, right in
    let leftPriority = sections[left].priority ?? Int.max
    let rightPriority = sections[right].priority ?? Int.max
    return leftPriority != rightPriority ? leftPriority < rightPriority : left < right
  }
  for index in byPriority {
    let section = sections[index]
    if section.required {
      kept.insert(index)
    } else if used + section.tokens <= budgetTokens {
      kept.insert(index)
      used += section.tokens
    } else {
      omitted.append(BudgetOmission(key: section.key, reason: .budget, tokens: section.tokens))
    }
  }
  if kept.isEmpty, let first = sections.first, budgetTokens > 0 {
    kept.insert(0)
    if let position = omitted.firstIndex(where: { $0.key.jsEquals(first.key) }) { omitted.remove(at: position) }
  }
  return BudgetResult(fitting: sections.indices.filter(kept.contains).map { sections[$0] }, omitted: omitted)
}

private func longestFit(of count: Int, maxTokens: Int, cost: (Int) -> Int) -> Int {
  var fits = 0
  var over = count + 1
  while over - fits > 1 {
    let middle = (fits + over) / 2
    if cost(middle) <= maxTokens {
      fits = middle
    } else {
      over = middle
    }
  }
  return fits
}

private func wordRun(_ words: [String], maxTokens: Int, end: WordRunEnd) -> String {
  func take(_ count: Int) -> ArraySlice<String> { end == .head ? words.prefix(count) : words.suffix(count) }
  let fits = longestFit(of: words.count, maxTokens: maxTokens) { countTokens(take($0).joined(separator: " ")) }
  if fits > 0 { return take(fits).joined(separator: " ") }
  return end == .head ? leadingChars(words.first ?? "", maxTokens: maxTokens) : trailingChars(words.last ?? "", maxTokens: maxTokens)
}
