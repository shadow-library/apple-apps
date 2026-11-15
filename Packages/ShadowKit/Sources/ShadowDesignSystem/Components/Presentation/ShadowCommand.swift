import Foundation
import SwiftUI

nonisolated public struct ShadowCommand: Identifiable, Sendable {
  public let id: String
  public let title: String
  public let subtitle: String?
  public let systemImage: String
  public let shortcut: KeyboardShortcut?
  public let keywords: [String]
  public let perform: @MainActor @Sendable () -> Void

  public init(
    id: String,
    title: String,
    subtitle: String? = nil,
    systemImage: String,
    shortcut: KeyboardShortcut? = nil,
    keywords: [String] = [],
    perform: @escaping @MainActor @Sendable () -> Void
  ) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.systemImage = systemImage
    self.shortcut = shortcut
    self.keywords = keywords
    self.perform = perform
  }
}

nonisolated public struct ShadowCommandSection: Identifiable, Sendable {
  public let id: String
  public let title: String
  public let commands: [ShadowCommand]

  public init(id: String, title: String, commands: [ShadowCommand]) {
    self.id = id
    self.title = title
    self.commands = commands
  }
}

nonisolated public struct ShadowCommandMatch: Hashable, Sendable {
  public let score: Int
  public let matchedOffsets: [Int]

  public init(score: Int, matchedOffsets: [Int]) {
    self.score = score
    self.matchedOffsets = matchedOffsets
  }
}

nonisolated public struct ShadowCommandResult: Identifiable, Sendable {
  public let command: ShadowCommand
  public let match: ShadowCommandMatch

  public var id: String { command.id }
}

nonisolated public struct ShadowCommandResultSection: Identifiable, Sendable {
  public let id: String
  public let title: String
  public let results: [ShadowCommandResult]
}

nonisolated public enum ShadowCommandMatcher {
  enum Tier: Int {
    case keyword = 0
    case fuzzy
    case substring
    case wordPrefix
    case prefix
  }

  static let tierSpan = 1_000
  static let tierCount = 5
  static let wordStartReach = 12

  public static func match(_ query: String, in text: String) -> ShadowCommandMatch? {
    match(ShadowFoldedQuery(query), in: ShadowFoldedText(text))
  }

  public static func match(_ query: String, in command: ShadowCommand) -> ShadowCommandMatch? {
    match(ShadowFoldedQuery(query), in: ShadowIndexedCommand(command))
  }

  static func match(_ query: ShadowFoldedQuery, in command: ShadowIndexedCommand) -> ShadowCommandMatch? {
    if let title = match(query, in: command.title) { return title }
    let keyword = command.keywords.compactMap { match(query, in: $0)?.score }.max()
    return keyword.map { ShadowCommandMatch(score: keywordScore($0), matchedOffsets: []) }
  }

  static func match(_ query: ShadowFoldedQuery, in haystack: ShadowFoldedText) -> ShadowCommandMatch? {
    guard !query.letters.isEmpty else { return ShadowCommandMatch(score: 0, matchedOffsets: []) }
    guard query.letters.count <= haystack.folded.count else { return nil }
    if query.characters.count <= haystack.folded.count, let start = contiguousStart(of: query.characters, in: haystack) {
      let tier: Tier = start == 0 ? .prefix : haystack.isWordStart(at: start) ? .wordPrefix : .substring
      let penalty = min(start * 4 + (haystack.folded.count - query.characters.count), tierSpan - 1)
      let offsets = haystack.originalOffsets(of: Array(start..<start + query.characters.count))
      return ShadowCommandMatch(score: score(tier, tierSpan - 1 - penalty), matchedOffsets: offsets)
    }
    return fuzzy(query.letters, in: haystack)
  }

  static func score(_ tier: Tier, _ inner: Int) -> Int {
    tier.rawValue * tierSpan + min(max(inner, 0), tierSpan - 1)
  }

  static func keywordScore(_ textScore: Int) -> Int {
    let band = tierSpan / tierCount
    return score(.keyword, (textScore / tierSpan) * band + (textScore % tierSpan) / tierCount)
  }

  private static func contiguousStart(of needle: [Character], in haystack: ShadowFoldedText) -> Int? {
    let starts = (0...(haystack.folded.count - needle.count)).filter { start in
      needle.indices.allSatisfy { haystack.folded[start + $0] == needle[$0] }
    }
    return starts.first { haystack.isWordStart(at: $0) } ?? starts.first
  }

  private static func fuzzy(_ needle: [Character], in haystack: ShadowFoldedText) -> ShadowCommandMatch? {
    var indices: [Int] = []
    var cursor = 0
    for position in needle.indices {
      guard let found = nextIndex(for: needle, at: position, in: haystack, from: cursor) else { return nil }
      indices.append(found)
      cursor = found + 1
    }
    var inner = tierSpan / 2
    for (position, index) in indices.enumerated() {
      if haystack.isWordStart(at: index) { inner += 20 }
      if position > 0 {
        let gap = index - indices[position - 1] - 1
        inner += gap == 0 ? 15 : -min(gap, 10)
      } else {
        inner -= min(index, 20)
      }
    }
    return ShadowCommandMatch(score: score(.fuzzy, inner), matchedOffsets: haystack.originalOffsets(of: indices))
  }

  private static func nextIndex(for needle: [Character], at position: Int, in haystack: ShadowFoldedText, from start: Int) -> Int? {
    let folded = haystack.folded
    guard let first = folded[start...].firstIndex(of: needle[position]) else { return nil }
    let reach = min(first + wordStartReach, folded.count - 1)
    let wordStart = (first...reach).first { folded[$0] == needle[position] && haystack.isWordStart(at: $0) }
    guard let wordStart, wordStart != first, isSubsequence(needle[(position + 1)...], of: folded, from: wordStart + 1) else { return first }
    return wordStart
  }

  private static func isSubsequence(_ needle: ArraySlice<Character>, of folded: [Character], from start: Int) -> Bool {
    var cursor = start
    for character in needle {
      guard cursor < folded.count, let found = folded[cursor...].firstIndex(of: character) else { return false }
      cursor = found + 1
    }
    return true
  }

  static func isWordStart(_ offset: Int, in characters: [Character]) -> Bool {
    guard offset > 0 else { return true }
    let previous = characters[offset - 1]
    let current = characters[offset]
    if !(previous.isLetter || previous.isNumber) { return current.isLetter || current.isNumber }
    return previous.isLowercase && current.isUppercase
  }
}

nonisolated struct ShadowFoldedQuery: Sendable {
  let characters: [Character]
  let letters: [Character]

  init(_ query: String) {
    characters = ShadowFoldedText(query.trimmingCharacters(in: .whitespacesAndNewlines)).folded
    letters = characters.filter { !$0.isWhitespace }
  }
}

nonisolated struct ShadowFoldedText: Sendable {
  let characters: [Character]
  let folded: [Character]
  let origins: [Int]

  init(_ text: String) {
    characters = Array(text)
    var folded: [Character] = []
    var origins: [Int] = []
    for (offset, character) in characters.enumerated() {
      for piece in String(character).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil) {
        folded.append(piece)
        origins.append(offset)
      }
    }
    self.folded = folded
    self.origins = origins
  }

  func isWordStart(at index: Int) -> Bool {
    guard index == 0 || origins[index - 1] != origins[index] else { return false }
    return ShadowCommandMatcher.isWordStart(origins[index], in: characters)
  }

  func originalOffsets(of indices: [Int]) -> [Int] {
    var offsets: [Int] = []
    for index in indices where offsets.last != origins[index] {
      offsets.append(origins[index])
    }
    return offsets
  }
}

nonisolated struct ShadowIndexedCommand: Sendable {
  let command: ShadowCommand
  let title: ShadowFoldedText
  let keywords: [ShadowFoldedText]

  init(_ command: ShadowCommand) {
    self.command = command
    title = ShadowFoldedText(command.title)
    keywords = command.keywords.map(ShadowFoldedText.init)
  }
}

nonisolated public struct ShadowCommandIndex: Sendable {
  struct Section: Sendable {
    let id: String
    let title: String
    let commands: [ShadowIndexedCommand]
  }

  let sections: [Section]

  public init(_ sections: [ShadowCommandSection]) {
    self.sections = sections.map { Section(id: $0.id, title: $0.title, commands: $0.commands.map(ShadowIndexedCommand.init)) }
  }

  public func sections(matching query: String) -> [ShadowCommandResultSection] {
    let folded = ShadowFoldedQuery(query)
    return sections.compactMap { section -> ShadowCommandResultSection? in
      let results = Self.results(in: section.commands, matching: folded)
      return results.isEmpty ? nil : ShadowCommandResultSection(id: section.id, title: section.title, results: results)
    }
  }

  static func results(in commands: [ShadowIndexedCommand], matching query: ShadowFoldedQuery) -> [ShadowCommandResult] {
    let ranked: [(order: Int, result: ShadowCommandResult)] = commands.enumerated().compactMap { order, indexed in
      guard let match = ShadowCommandMatcher.match(query, in: indexed) else { return nil }
      return (order, ShadowCommandResult(command: indexed.command, match: match))
    }
    return ranked.sorted(by: isRankedBefore).map(\.result)
  }

  private static func isRankedBefore(_ lhs: (order: Int, result: ShadowCommandResult), _ rhs: (order: Int, result: ShadowCommandResult)) -> Bool {
    let left = lhs.result.match.score
    let right = rhs.result.match.score
    return left == right ? lhs.order < rhs.order : left > right
  }
}

nonisolated public enum ShadowCommandFilter {
  public static func sections(_ sections: [ShadowCommandSection], matching query: String) -> [ShadowCommandResultSection] {
    ShadowCommandIndex(sections).sections(matching: query)
  }

  public static func results(in commands: [ShadowCommand], matching query: String) -> [ShadowCommandResult] {
    ShadowCommandIndex.results(in: commands.map(ShadowIndexedCommand.init), matching: ShadowFoldedQuery(query))
  }
}

nonisolated public struct ShadowCommandCursor: Equatable, Sendable {
  public private(set) var ids: [String]
  public private(set) var selection: String?

  public init(ids: [String] = []) {
    self.ids = ids
    selection = ids.first
  }

  public init(sections: [ShadowCommandResultSection]) {
    self.init(ids: sections.flatMap { $0.results.map(\.id) })
  }

  public var selectedIndex: Int? { selection.flatMap { ids.firstIndex(of: $0) } }

  public mutating func moveDown() {
    move(by: 1)
  }

  public mutating func moveUp() {
    move(by: -1)
  }

  public mutating func select(_ id: String) {
    guard ids.contains(id) else { return }
    selection = id
  }

  public mutating func reconcile(with ids: [String]) {
    self.ids = ids
    if let selection, ids.contains(selection) { return }
    selection = ids.first
  }

  private mutating func move(by step: Int) {
    guard !ids.isEmpty else {
      selection = nil
      return
    }
    guard let index = selectedIndex else {
      selection = step > 0 ? ids.first : ids.last
      return
    }
    selection = ids[(index + step + ids.count) % ids.count]
  }
}
