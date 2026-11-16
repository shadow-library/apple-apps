import Foundation
import ShadowCore

public struct RecordState: Sendable, Equatable {
  public let fields: [ExactString: FieldState]

  public subscript(field name: String) -> FieldState? {
    fields[ExactString(name)]
  }

  func joined(with other: RecordState) -> RecordState {
    RecordState(fields: fields.merging(other.fields) { $0.joined(with: $1) })
  }
}

public struct AppendedState: Sendable, Equatable {
  public let item: [String: JSONValue]
  public let clock: HLCTimestamp

  public static func == (lhs: AppendedState, rhs: AppendedState) -> Bool {
    lhs.clock == rhs.clock && CanonicalJSON.encode(.object(lhs.item)) == CanonicalJSON.encode(.object(rhs.item))
  }

  func joined(with other: AppendedState) -> AppendedState {
    guard clock == other.clock else { return clock < other.clock ? self : other }
    return CanonicalJSON.encode(.object(other.item)).lexicographicallyPrecedes(CanonicalJSON.encode(.object(item))) ? other : self
  }
}

public struct RevisionedState: Sendable, Equatable {
  public let fields: [ExactString: FieldState]
  public let head: FieldState?
  public let marks: [ExactString: FieldState]
  public let revisions: [ExactString: RevisionItem]

  init(fields: [ExactString: FieldState], head: FieldState?, marks: [ExactString: FieldState], revisions: [ExactString: RevisionItem]) {
    self.fields = fields
    self.head = head
    self.marks = marks
    self.revisions = revisions
  }

  public subscript(field name: String) -> FieldState? {
    fields[ExactString(name)]
  }

  public subscript(mark name: String) -> FieldState? {
    marks[ExactString(name)]
  }

  public var headRevision: String? {
    head?.value.stringValue
  }

  public var nextGeneration: Int64 {
    guard let highest = revisions.values.map(\.generation).max() else { return 0 }
    return highest == Int64.max ? highest : highest + 1
  }

  public var isEmpty: Bool {
    fields.isEmpty && head == nil && marks.isEmpty && revisions.isEmpty
  }

  public var namedRevisions: Set<ExactString> {
    Set(([head].compactMap(\.self) + Array(marks.values)).compactMap(\.value.stringValue).map(ExactString.init(_:)))
  }

  func joined(with other: RevisionedState) -> RevisionedState {
    let joinedHead =
      switch (head, other.head) {
      case (let mine?, let theirs?): mine.joined(with: theirs)
      default: head ?? other.head
      }
    return RevisionedState(
      fields: fields.merging(other.fields) { $0.joined(with: $1) }, head: joinedHead, marks: marks.merging(other.marks) { $0.joined(with: $1) },
      revisions: revisions.merging(other.revisions) { mine, _ in mine })
  }

  func with(fields: [ExactString: FieldState]? = nil, revisions: [ExactString: RevisionItem]? = nil) -> RevisionedState {
    RevisionedState(fields: fields ?? self.fields, head: head, marks: marks, revisions: revisions ?? self.revisions)
  }
}

public struct PurgedState: Sendable, Equatable {
  public let clock: HLCTimestamp

}

public enum EntityState: Sendable, Equatable {
  case record(RecordState)
  case appended(AppendedState)
  case revisioned(RevisionedState)
  case purged(PurgedState)

  public func joined(with other: EntityState) -> EntityState {
    switch (self, other) {
    case (.purged(let mine), .purged(let theirs)): return .purged(PurgedState(clock: min(mine.clock, theirs.clock)))
    case (.purged, _): return self
    case (_, .purged): return other
    case (.record(let mine), .record(let theirs)): return .record(mine.joined(with: theirs))
    case (.appended(let mine), .appended(let theirs)): return .appended(mine.joined(with: theirs))
    case (.revisioned(let mine), .revisioned(let theirs)): return .revisioned(mine.joined(with: theirs))
    default: return shapeName.utf8.lexicographicallyPrecedes(other.shapeName.utf8) ? other : self
    }
  }

  var shapeName: String {
    switch self {
    case .record: "record"
    case .appended: "appended"
    case .revisioned: "revisioned"
    case .purged: "purged"
    }
  }
}
