// apps/novel-forge-server/src/modules/refinement/change-set/op-specs.ts:11
public enum BriefWriteMode: String, CaseIterable, Codable, Sendable {
  case standard
  case external
}

// apps/novel-forge-server/src/modules/refinement/change-set/op-specs.ts:12
public enum ContentMode: String, CaseIterable, Codable, Sendable {
  case standard
  case unrestricted
}

// apps/novel-forge-server/src/modules/refinement/change-set/op-specs.ts:14
public enum EntityType: String, CaseIterable, Codable, Sendable {
  case character
  case faction
  case location
  case powerRule = "power_rule"
  case item
  case concept
}

// apps/novel-forge-server/src/modules/refinement/change-set/op-specs.ts:15
public enum MilestoneKind: String, CaseIterable, Codable, Sendable {
  case rank
  case event
  case learnedFrom = "learned_from"
  case custom
}

// apps/novel-forge-server/src/modules/refinement/change-set/op-specs.ts:17
enum PromiseKind: String, CaseIterable, Codable, Sendable {
  case thread
  case mystery
}

// apps/novel-forge-server/src/modules/refinement/change-set/op-specs.ts:18
enum PromiseOpStatus: String, CaseIterable, Codable, Sendable {
  case open
  case paidOff = "paid_off"
}

// apps/novel-forge-server/src/modules/refinement/change-set/op-specs.ts:169
enum ValidationScope: String, CaseIterable, Codable, Sendable {
  case novel
  case chapter
}

// apps/novel-forge-server/src/database/schemas/plan.ts:11
enum VolumeState: String, CaseIterable, Codable, Sendable {
  case notStarted = "not_started"
  case active
  case goalMet = "goal_met"
}

// apps/novel-forge-server/src/database/schemas/story.ts:14
public enum ThreadStatus: String, CaseIterable, Codable, Sendable {
  case open
  case closed
  case dropped
}

// apps/novel-forge-server/src/database/schemas/story.ts:15
public enum MysteryStatus: String, CaseIterable, Codable, Sendable {
  case open
  case resolved
  case dropped
}

// apps/novel-forge-server/src/database/schemas/ledger.ts:44
public enum LedgerEntryKind: String, CaseIterable, Codable, Sendable {
  case decision
  case direction
  case rejected
  case backlog
  case system
}

// apps/novel-forge-server/src/database/schemas/ledger.ts:45
public enum LedgerDecidedBy: String, CaseIterable, Codable, Sendable {
  case author
  case system
}

// apps/novel-forge-server/src/database/schemas/ledger.ts:46
public enum LedgerRejectionScope: String, CaseIterable, Codable, Sendable {
  case never
  case notNow = "not_now"
  case notThisVersion = "not_this_version"
}
