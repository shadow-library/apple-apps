import Foundation

nonisolated public enum ShadowOneTimeCodeCharacters: Hashable, Sendable, CaseIterable {
  case digits
  case alphanumeric
}

nonisolated public enum ShadowOneTimeCodeSeparator: Hashable, Sendable, CaseIterable {
  case space
  case dash
}

nonisolated public struct ShadowOneTimeCode: Hashable, Sendable {
  public let length: Int
  public let characters: ShadowOneTimeCodeCharacters
  public let groups: [Int]

  public init(length: Int = 6, characters: ShadowOneTimeCodeCharacters = .digits, groups: [Int]? = nil) {
    let length = max(length, 1)
    let groups = (groups ?? Self.defaultGroups(for: length)).filter { $0 > 0 }
    self.length = length
    self.characters = characters
    self.groups = groups.reduce(0, +) == length ? groups : [length]
  }

  public var groupRanges: [Range<Int>] {
    var start = 0
    return groups.map { size in
      defer { start += size }
      return start..<start + size
    }
  }

  public func sanitize(_ input: String) -> String {
    String(input.compactMap(normalized).prefix(length))
  }

  public func isComplete(_ code: String) -> Bool {
    code.count == length
  }

  public func activeIndex(in code: String) -> Int {
    min(code.count, length - 1)
  }

  public func progress(of code: String) -> ShadowOneTimeCodeProgress {
    ShadowOneTimeCodeProgress(code: code, length: length)
  }

  public func edit(from current: String, to proposed: String, replacingCurrent: Bool) -> String {
    guard replacingCurrent, proposed != current else { return sanitize(proposed) }
    guard proposed.count >= current.count else { return "" }
    guard proposed.count > current.count, proposed.hasPrefix(current) else { return sanitize(proposed) }
    return sanitize(String(proposed.dropFirst(current.count)))
  }

  private func normalized(_ character: Character) -> Character? {
    if character.isNumber, let digit = character.wholeNumberValue, (0...9).contains(digit) {
      return Character(String(digit))
    }
    guard characters == .alphanumeric, character.isASCII, character.isLetter else { return nil }
    return Character(character.uppercased())
  }

  private static func defaultGroups(for length: Int) -> [Int] {
    length >= 6 && length.isMultiple(of: 2) ? [length / 2, length / 2] : [length]
  }
}

nonisolated public struct ShadowOneTimeCodeProgress: Hashable, Sendable {
  public let code: String
  public let length: Int

  public var entered: Int { code.count }
  public var isComplete: Bool { code.count == length }
}

nonisolated public struct ShadowOneTimeCodeCompletion: Hashable, Sendable {
  public let format: ShadowOneTimeCode
  public private(set) var completedCode: String?

  public init(format: ShadowOneTimeCode, code: String) {
    self.format = format
    completedCode = format.isComplete(code) ? code : nil
  }

  public mutating func update(_ code: String) -> Bool {
    guard format.isComplete(code) else {
      completedCode = nil
      return false
    }
    guard code != completedCode else { return false }
    completedCode = code
    return true
  }
}
