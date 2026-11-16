import ShadowCore
import ShadowStore

public enum UnreadableReason: ShadowError, Equatable {
  case wrongShape
  case identity(EntityRef)
  case missing(field: String)
  case invalid(field: String)
  case naturalKey(NovelForgeKeyError)
  case unknownSection(String)

  public var code: String {
    switch self {
    case .wrongShape: "record.wrong_shape"
    case .identity: "record.identity"
    case .missing: "record.missing_field"
    case .invalid: "record.invalid_field"
    case .naturalKey: "record.natural_key"
    case .unknownSection: "record.unknown_section"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .wrongShape: "The stored state is not a record."
    case .identity(let ref): "\(ref.kind)/\(ref.key) does not identify a record of this kind."
    case .missing(let field): "The stored record has no \"\(field)\" field."
    case .invalid(let field): "The stored record's \"\(field)\" field has the wrong type."
    case .naturalKey(let error): "The stored natural key is unusable: \(error.errorDescription ?? error.code)"
    case .unknownSection(let section): "The page belongs to the section \"\(section)\", which this version does not know."
    }
  }
}

public struct RecordEntry<Record: Sendable & Equatable>: Sendable, Equatable {
  public let record: Record
  public let isRemoved: Bool

  public init(record: Record, isRemoved: Bool) {
    self.record = record
    self.isRemoved = isRemoved
  }
}

public enum RecordReading<Record: Sendable & Equatable>: Sendable, Equatable {
  case absent
  case readable(RecordEntry<Record>)
  case unreadable(UnreadableReason)

  public var entry: RecordEntry<Record>? {
    guard case .readable(let entry) = self else { return nil }
    return entry
  }
}

public struct RecordListing<Record: Sendable & Equatable>: Sendable, Equatable {
  public let entries: [RecordEntry<Record>]
  public let unreadable: Int
  public let unattributed: Int

  public init(entries: [RecordEntry<Record>], unreadable: Int, unattributed: Int = 0) {
    self.entries = entries
    self.unreadable = unreadable
    self.unattributed = unattributed
  }

  public var live: [Record] { entries.filter { !$0.isRemoved }.map(\.record) }
}
