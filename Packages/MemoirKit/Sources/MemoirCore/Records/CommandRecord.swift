import Foundation
import ShadowCore
import ShadowStore

public enum MemoirCommandError: ShadowError, Equatable {
  case idNotVersion7
  case malformedType
  case payloadKey(path: String)
  case payloadText(path: String)
  case payloadTooDeep
  case payloadNumber(path: String)
  case payloadMeasurement(path: String)
  case utcOffsetOutOfRange(Int)
  case instantOutOfRange(Int64)
  case issuedOnMismatch(expected: LocalDate, actual: LocalDate)
  case rulesetVersionOutOfRange(Int)
  case emptyNote

  public var code: String {
    switch self {
    case .idNotVersion7: "memoir_command.id_not_version_7"
    case .malformedType: "memoir_command.malformed_type"
    case .payloadKey: "memoir_command.payload_key"
    case .payloadText: "memoir_command.payload_text"
    case .payloadTooDeep: "memoir_command.payload_too_deep"
    case .payloadNumber: "memoir_command.payload_number"
    case .payloadMeasurement: "memoir_command.payload_measurement"
    case .utcOffsetOutOfRange: "memoir_command.utc_offset_out_of_range"
    case .instantOutOfRange: "memoir_command.instant_out_of_range"
    case .issuedOnMismatch: "memoir_command.issued_on_mismatch"
    case .rulesetVersionOutOfRange: "memoir_command.ruleset_version_out_of_range"
    case .emptyNote: "memoir_command.empty_note"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .idNotVersion7: "A command id must be a version 7 UUID."
    case .malformedType: "A command type is two or more dot-separated words of ASCII letters and digits, each starting with a lower-case letter."
    case .payloadKey(let path): "The payload key at \(path) is not an identifier."
    case .payloadText(let path): "The payload string at \(path) is not a token; content text belongs in a record the command names by id."
    case .payloadTooDeep: "The payload nests deeper than \(CommandPayload.maximumDepth) levels."
    case .payloadNumber(let path): "The payload holds a number at \(path), which is not a key that takes one; values belong in a record of the metric's class."
    case .payloadMeasurement(let path): "The payload names a measurement or threshold at \(path); it belongs in a record of the metric's class."
    case .utcOffsetOutOfRange(let minutes): "A UTC offset of \(minutes) minutes is outside ±\(MemoirCommand.maximumOffsetMinutes)."
    case .instantOutOfRange(let millis): "The instant \(millis) ms falls outside the years 0000 to 9999."
    case .issuedOnMismatch(let expected, let actual): "The command says it was issued on \(actual), but its instant and offset fall on \(expected)."
    case .rulesetVersionOutOfRange(let version): "Ruleset version \(version) is not a version; versions start at 1."
    case .emptyNote: "A command note holds text."
    }
  }
}

public struct CommandType: Hashable, Sendable, StoredValue, CustomStringConvertible {
  public static let maximumLength = 64

  public let name: String

  public init(_ name: String) throws(MemoirCommandError) {
    let words = Array(name.utf8).split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
    guard name.utf8.count <= Self.maximumLength, words.count >= 2, words.allSatisfy(Self.isWord) else { throw .malformedType }
    self.name = name
  }

  public init?(stored: JSONValue) {
    guard let text = stored.stringValue, let type = try? CommandType(text) else { return nil }
    self = type
  }

  public var stored: JSONValue { .string(name) }

  public var description: String { name }

  private static func isWord(_ word: ArraySlice<UInt8>) -> Bool {
    guard let first = word.first, (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(first) else { return false }
    return word.allSatisfy { CommandPayload.isAlphanumeric($0) }
  }
}

/// A payload never carries the owner's words, a measured value, or a threshold of an activity- or health-class metric; those live in records of the
/// metric's class, named by id or date. Strings are tokens, digit-only strings are refused, and integers appear only under ``integerKeys``.
public struct CommandPayload: Hashable, Sendable, StoredValue {
  public static let maximumDepth = 8
  public static let maximumTokenLength = 64
  /// Schedule minutes, counts and calendar positions: outcome-class integers a command may carry.
  public static let integerKeys: Set<String> = [
    "billingDay", "count", "customIntervalDays", "dayOfMonth", "daysOfWeek", "durationMinutes", "interval", "leadMinutes", "ordinal", "returnerThresholdDays",
    "startTimeMinutes", "toMin", "weekStart", "weekday",
  ]
  /// Keys that name a measurement or a metric threshold, refused whatever they hold.
  public static let measurementKeys: Set<String> = ["defaultValue", "healthThreshold", "kg", "kilograms", "threshold", "value"]

  public let members: [String: JSONValue]

  public init(_ members: [String: JSONValue] = [:]) throws(MemoirCommandError) {
    try Self.validate(.object(members), path: "payload", depth: 1, integersAllowed: false)
    self.members = members
  }

  public init?(stored: JSONValue) {
    guard let members = stored.objectValue, let payload = try? CommandPayload(members) else { return nil }
    self = payload
  }

  public var stored: JSONValue { .object(members) }

  public static func == (lhs: CommandPayload, rhs: CommandPayload) -> Bool {
    sameJSON(lhs.stored, rhs.stored)
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(CanonicalJSON.encode(stored))
  }

  static func isAlphanumeric(_ byte: UInt8) -> Bool {
    (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
  }

  private static func validate(_ value: JSONValue, path: String, depth: Int, integersAllowed: Bool) throws(MemoirCommandError) {
    switch value {
    case .null, .bool:
      return
    case .int:
      guard integersAllowed else { throw .payloadNumber(path: path) }
    case .string(let text):
      guard isToken(text) else { throw .payloadText(path: path) }
      guard !isNumeral(text) else { throw .payloadNumber(path: path) }
    case .array(let elements):
      guard depth < maximumDepth else { throw .payloadTooDeep }
      for (index, element) in elements.enumerated() { try validate(element, path: "\(path)[\(index)]", depth: depth + 1, integersAllowed: integersAllowed) }
    case .object(let members):
      guard depth <= maximumDepth else { throw .payloadTooDeep }
      for (key, member) in members.sorted(by: { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }) {
        guard isIdentifier(key) else { throw .payloadKey(path: path) }
        guard !measurementKeys.contains(key) else { throw .payloadMeasurement(path: "\(path).\(key)") }
        try validate(member, path: "\(path).\(key)", depth: depth + 1, integersAllowed: integerKeys.contains(key))
      }
    }
  }

  private static func isNumeral(_ text: String) -> Bool {
    let digits = text.utf8.drop { $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: "+") }
    return !digits.isEmpty && digits.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
  }

  private static func isIdentifier(_ key: String) -> Bool {
    let bytes = Array(key.utf8)
    guard (1...maximumTokenLength).contains(bytes.count), let first = bytes.first, isAlphanumeric(first), !(UInt8(ascii: "0")...UInt8(ascii: "9")).contains(first) else {
      return false
    }
    return bytes.allSatisfy { isAlphanumeric($0) || $0 == UInt8(ascii: "_") }
  }

  private static func isToken(_ text: String) -> Bool {
    let bytes = Array(text.utf8)
    let punctuation: [UInt8] = [UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: ":"), UInt8(ascii: "/"), UInt8(ascii: "+")]
    return (1...maximumTokenLength).contains(bytes.count) && bytes.allSatisfy { isAlphanumeric($0) || punctuation.contains($0) }
  }
}

public struct Occurrence: Hashable, Sendable, StoredValue {
  public let quest: UUID
  public let date: LocalDate

  public init(quest: UUID, date: LocalDate) {
    self.quest = quest
    self.date = date
  }

  public init?(stored: JSONValue) {
    guard
      let occurrence = MemberReader<OccurrenceMember>.nested(
        stored, { reader throws(MemoirUnreadable) in Occurrence(quest: try reader.required(.quest), date: try reader.required(.date)) })
    else { return nil }
    self = occurrence
  }

  public var stored: JSONValue {
    var members = RecordMembers<OccurrenceMember>()
    members.put(.quest, quest)
    members.put(.date, date)
    return members.json
  }
}

/// Everything that moves hero state. It records what the issuing device knew; replay reads these fields and never the device's clock or zone data.
public struct MemoirCommand: AppendedMemoirRecord {
  public static let kind = MemoirKind.command
  public static let maximumOffsetMinutes = 18 * 60

  private static let millisPerMinute: Int64 = 60_000
  private static let millisPerDay: Int64 = 86_400_000

  public let id: UUID
  public let type: CommandType
  public let payload: CommandPayload
  public let instantMillis: Int64
  public let utcOffsetMinutes: Int
  public let issuedOn: LocalDate
  public let occurrence: Occurrence?
  public let rulesetVersion: Int

  public init(
    id: UUID, type: CommandType, payload: CommandPayload, instantMillis: Int64, utcOffsetMinutes: Int, issuedOn: LocalDate, occurrence: Occurrence? = nil,
    rulesetVersion: Int
  ) throws(MemoirCommandError) {
    guard id.v7Timestamp != nil else { throw .idNotVersion7 }
    guard rulesetVersion >= 1 else { throw .rulesetVersionOutOfRange(rulesetVersion) }
    let expected = try Self.localDate(instantMillis: instantMillis, utcOffsetMinutes: utcOffsetMinutes)
    guard expected == issuedOn else { throw .issuedOnMismatch(expected: expected, actual: issuedOn) }
    self.id = id
    self.type = type
    self.payload = payload
    self.instantMillis = instantMillis
    self.utcOffsetMinutes = utcOffsetMinutes
    self.issuedOn = issuedOn
    self.occurrence = occurrence
    self.rulesetVersion = rulesetVersion
  }

  public init(id: UUID, reading reader: MemberReader<CommandMember>) throws(MemoirUnreadable) {
    let type: CommandType = try reader.required(.type)
    let payload: CommandPayload = try reader.required(.payload)
    let instantMillis: Int64 = try reader.required(.instantMillis)
    let utcOffsetMinutes: Int = try reader.required(.utcOffsetMinutes)
    let issuedOn: LocalDate = try reader.required(.issuedOn)
    let occurrence: Occurrence? = try reader.optional(.occurrence)
    let rulesetVersion: Int = try reader.required(.rulesetVersion)
    do throws(MemoirCommandError) {
      try self.init(
        id: id, type: type, payload: payload, instantMillis: instantMillis, utcOffsetMinutes: utcOffsetMinutes, issuedOn: issuedOn, occurrence: occurrence,
        rulesetVersion: rulesetVersion)
    } catch {
      throw .command(error)
    }
  }

  public static func localDate(instantMillis: Int64, utcOffsetMinutes: Int) throws(MemoirCommandError) -> LocalDate {
    guard abs(utcOffsetMinutes) <= maximumOffsetMinutes else { throw .utcOffsetOutOfRange(utcOffsetMinutes) }
    let (local, overflow) = instantMillis.addingReportingOverflow(Int64(utcOffsetMinutes) * millisPerMinute)
    guard !overflow else { throw .instantOutOfRange(instantMillis) }
    let days = local >= 0 ? local / millisPerDay : -((-(local + 1)) / millisPerDay) - 1
    guard let date = LocalDate(daysSinceEpoch: Int(days)) else { throw .instantOutOfRange(instantMillis) }
    return date
  }

  public var members: RecordMembers<CommandMember> {
    var members = RecordMembers<CommandMember>()
    members.put(.type, type)
    members.put(.payload, payload)
    members.put(.instantMillis, instantMillis)
    members.put(.utcOffsetMinutes, utcOffsetMinutes)
    members.put(.issuedOn, issuedOn)
    members.put(.occurrence, occurrence)
    members.put(.rulesetVersion, rulesetVersion)
    return members
  }
}

/// Text the owner attached to a command (a reason note, a reflection), kept under the command's own id so the command stays free of it.
public struct CommandNoteRecord: AppendedMemoirRecord {
  public static let kind = MemoirKind.commandNote

  public let command: UUID
  public let text: String

  public init(command: UUID, text: String) throws(MemoirCommandError) {
    guard !text.isEmpty else { throw .emptyNote }
    self.command = command
    self.text = text
  }

  public init(id: UUID, reading reader: MemberReader<CommandNoteMember>) throws(MemoirUnreadable) {
    let text: String = try reader.required(.text)
    do throws(MemoirCommandError) {
      try self.init(command: id, text: text)
    } catch {
      throw .command(error)
    }
  }

  public var id: UUID { command }

  public var members: RecordMembers<CommandNoteMember> {
    var members = RecordMembers<CommandNoteMember>()
    members.put(.text, text)
    return members
  }
}
