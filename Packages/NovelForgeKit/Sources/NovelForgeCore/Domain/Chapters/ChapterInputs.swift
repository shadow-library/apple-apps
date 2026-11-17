import Foundation
import ShadowCore

/// A plan's knowledge contract as the author writes it (apps/novel-forge-server/src/modules/ai/schemas/knowledge-contract.schema.ts:16).
public struct PlanKnowledge: Sendable, Equatable, JSONWritable {
  public var pov: [String]
  public var learns: [KnowledgeReveal]

  public init(pov: [String], learns: [KnowledgeReveal] = []) {
    self.pov = pov
    self.learns = learns
  }

  public var json: JSONValue {
    let learned = learns.map { JSONValue.object(["entityKey": .string($0.entityKey), "factKey": .string($0.factKey)]) }
    return .object(["pov": pov.json, "learns": .array(learned)])
  }
}

/// The author's edit of a chapter plan (apps/novel-forge-server/src/modules/generation/generation.dto.ts:102): `.keep` leaves a field as it is, as an
/// omitted member does; a blank title keeps the title.
public struct PlanEdit: Sendable, Equatable {
  public var body: String
  public var title: String?
  public var chapterPurpose: FieldChange<String> = .keep
  public var pov: FieldChange<String> = .keep
  public var guidance: FieldChange<String> = .keep
  public var endingContract: FieldChange<ChapterEndingContract?> = .keep
  public var knowledge: FieldChange<PlanKnowledge> = .keep
  public var direction: FieldChange<String?> = .keep
  public var contentMode: FieldChange<StoredEnum<ContentMode>?> = .keep
  public var scenes: FieldChange<[PlanScene]?> = .keep
  public var claimedMilestones: FieldChange<[String]?> = .keep
  public var isEnding: FieldChange<Bool> = .keep

  public init(body: String, title: String? = nil) {
    self.body = body
    self.title = title
  }
}

/// The author's own text for a draft (generation.dto.ts:182); a nil title or summary keeps the stored one.
public struct DraftEdit: Sendable, Equatable {
  public var title: String?
  public var body: String
  public var summary: String?

  public init(title: String? = nil, body: String, summary: String? = nil) {
    self.title = title
    self.body = body
    self.summary = summary
  }
}

/// Pasted prose (generation.dto.ts:253); a nil title, summary or isolation keeps the stored one.
public struct DraftImport: Sendable, Equatable {
  public var prose: String
  public var title: String?
  public var summary: String?
  public var isolated: Bool?

  public init(prose: String, title: String? = nil, summary: String? = nil, isolated: Bool? = nil) {
    self.prose = prose
    self.title = title
    self.summary = summary
    self.isolated = isolated
  }
}

/// Replacement prose for a final chapter (apps/novel-forge-server/src/modules/generation/chapter-amend.dto.ts:6); a nil title or note keeps the stored one.
public struct ChapterAmendment: Sendable, Equatable {
  public var content: String
  public var title: String?
  public var note: String?

  public init(content: String, title: String? = nil, note: String? = nil) {
    self.content = content
    self.title = title
    self.note = note
  }
}

/// How the author approves (generation.dto.ts:212): `asWritten` approves a stale draft over the stale cause the author saw.
public enum ApprovalIntent: Sendable, Equatable {
  case standard
  case asWritten(seen: StaleCause)
}

public enum DraftSaveOutcome: Sendable, Equatable {
  /// A revision was written; the editor rests on it from now on.
  case committed(revision: String)
  /// The text is kept in this device's working copy over the revision named, to be committed later.
  case held(base: String)
  case unchanged(revision: String)

  public var base: String {
    switch self {
    case .committed(let revision), .held(let revision), .unchanged(let revision): revision
    }
  }
}

public struct DraftVersion: Sendable, Equatable {
  public let revision: String
  /// Nil when this version cannot read the revision.
  public let source: StoredEnum<DraftSource>?
  public let restoredFrom: String?
  public let isCurrent: Bool
  public let isApproved: Bool
  public let isolated: Bool
  public let created: HLCTimestamp
}
