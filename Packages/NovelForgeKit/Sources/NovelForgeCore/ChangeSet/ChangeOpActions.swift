// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:236
struct GenerateChapterAction: Sendable, Equatable {
  var chapter: Int

  init?(_ fields: OpFields) {
    guard let chapter = fields.int("chapter") else { return nil }
    self.chapter = chapter
  }

  func encode(into encoder: inout OpEncoder) {
    encoder.int("chapter", chapter)
  }
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:241
struct AuditBibleAction: Sendable, Equatable {
  init?(_ fields: OpFields) {}

  func encode(into encoder: inout OpEncoder) {}
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:245
struct EnhancePremiseAction: Sendable, Equatable {
  var overview: String?

  init?(_ fields: OpFields) {
    overview = fields.string("overview")
  }

  func encode(into encoder: inout OpEncoder) {
    encoder.string("overview", overview)
  }
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:250
struct JudgeDraftAction: Sendable, Equatable {
  var chapter: Int

  init?(_ fields: OpFields) {
    guard let chapter = fields.int("chapter") else { return nil }
    self.chapter = chapter
  }

  func encode(into encoder: inout OpEncoder) {
    encoder.int("chapter", chapter)
  }
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:255
struct ReviseDraftAction: Sendable, Equatable {
  var chapter: Int
  var note: String

  init?(_ fields: OpFields) {
    guard let chapter = fields.int("chapter"), let note = fields.string("note") else { return nil }
    self.chapter = chapter
    self.note = note
  }

  func encode(into encoder: inout OpEncoder) {
    encoder.int("chapter", chapter)
    encoder.string("note", note)
  }
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:261
struct ApproveDraftAction: Sendable, Equatable {
  var chapter: Int
  var revision: Int?
  var saveSeq: Int?
  var draftId: String?

  init?(_ fields: OpFields) {
    guard let chapter = fields.int("chapter") else { return nil }
    self.chapter = chapter
    revision = fields.int("revision")
    saveSeq = fields.int("saveSeq")
    draftId = fields.string("draftId")
  }

  func encode(into encoder: inout OpEncoder) {
    encoder.int("chapter", chapter)
    encoder.int("revision", revision)
    encoder.int("saveSeq", saveSeq)
    encoder.string("draftId", draftId)
  }
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:269
struct ApplyContinuityAction: Sendable, Equatable {
  var chapter: Int

  init?(_ fields: OpFields) {
    guard let chapter = fields.int("chapter") else { return nil }
    self.chapter = chapter
  }

  func encode(into encoder: inout OpEncoder) {
    encoder.int("chapter", chapter)
  }
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:274
struct ValidateAction: Sendable, Equatable {
  var scope: ValidationScope
  var chapter: Int?

  init?(_ fields: OpFields) {
    guard let scope: ValidationScope = fields.member("scope") else { return nil }
    self.scope = scope
    chapter = fields.int("chapter")
  }

  func encode(into encoder: inout OpEncoder) {
    encoder.string("scope", scope.rawValue)
    encoder.int("chapter", chapter)
  }
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:280
struct FinalizeAction: Sendable, Equatable {
  var upTo: Int?

  init?(_ fields: OpFields) {
    upTo = fields.int("upTo")
  }

  func encode(into encoder: inout OpEncoder) {
    encoder.int("upTo", upTo)
  }
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:285
struct OrganiseNotesAction: Sendable, Equatable {
  init?(_ fields: OpFields) {}

  func encode(into encoder: inout OpEncoder) {}
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:289
struct PlanChapterAction: Sendable, Equatable {
  var chapter: Int?
  var intent: String?
  var direction: String?
  var empty: Bool?

  init?(_ fields: OpFields) {
    chapter = fields.int("chapter")
    intent = fields.string("intent")
    direction = fields.string("direction")
    empty = fields.bool("empty")
  }

  func encode(into encoder: inout OpEncoder) {
    encoder.int("chapter", chapter)
    encoder.string("intent", intent)
    encoder.string("direction", direction)
    encoder.bool("empty", empty)
  }
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:298
struct AdvanceVolumeAction: Sendable, Equatable {
  var volumeKey: String

  init?(_ fields: OpFields) {
    guard let volumeKey = fields.string("volumeKey") else { return nil }
    self.volumeKey = volumeKey
  }

  func encode(into encoder: inout OpEncoder) {
    encoder.string("volumeKey", volumeKey)
  }
}
