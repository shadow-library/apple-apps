import Foundation
import ShadowCore
import ShadowStore

public enum PromiseRef: Hashable, Sendable {
  case thread(String)
  case mystery(String)

  public var key: String {
    switch self {
    case .thread(let key), .mystery(let key): key
    }
  }

  public var kindName: String {
    switch self {
    case .thread: "thread"
    case .mystery: "mystery"
    }
  }
}

public enum DomainError: ShadowError, Equatable {
  case novelNotFound(UUID)
  case novelExists(UUID)
  case wordTargetInverted
  case notesTooLong(words: Int, maximum: Int)
  case unreadableRecords(kind: String, count: Int)
  case volumeNotFound(String)
  case volumeExists(String)
  case volumeNotActive(String)
  case volumeInPlan(volume: String, chapter: Int)
  case milestoneNotFound(String)
  case milestoneExists(String)
  case milestoneReferenced(milestone: String, references: [String])
  case milestoneSubjectUnknown(String)
  case promiseNotFound(PromiseRef)
  case promiseExists(PromiseRef)
  case secretNotFound(String)
  case entityNotFound(String)
  case entityExists(String)
  case documentNotFound(section: String, slug: String)
  case documentExists(section: String, slug: String)
  case revisionNotFound(String)
  case revisionUnreadable(String)
  case entityUnknown(String)
  case unlockMalformed(String)
  case clueNamesTerm(String)
  case cluesUncheckable(String)
  case invalidKey(field: String)
  case blank(field: String)
  case belowMinimum(field: String, minimum: Int)
  case aboveMaximum(field: String, maximum: Int)
  case tooLong(field: String, limit: Int)
  case unknownKind(String)
  case noChanges
  case empty(field: String)
  case chapterNotFound(Int)
  case chapterNotFinal(Int)
  case isolatedWithoutSummary(Int)
  case summaryMissing(Int)
  case draftNotFound(Int?)
  case draftFinal(Int)
  case draftNotApproved(Int)
  case draftStale(chapter: Int, reason: String)
  case draftConflict(chapter: Int, head: String?)
  case draftRevealStale(Int)
  case draftGenerating(Int)
  case notNextChapter(chapter: Int, next: Int)
  case finalizeOutOfOrder(Int)
  case planRevealsLocked(chapter: Int, violations: String)
  case endingPlanned(Int)
  case planClaims(chapter: Int, reason: String)
  case planRevealsHeld(chapter: Int, violations: String)
  case planFinal(Int)
  case endingIncomplete(fields: String)
  case scenesMalformed(String)
  case versionNotFound(chapter: Int, revision: String)
  case versionFinal(Int)
  case versionUnreadable(chapter: Int, revision: String)
  case lifecycleUnavailable(Int?)
  case planStateUnavailable(Int)
  case unreadable(EntityRef)
  case unrestrictedLocked
  case finalizeRefused(FinalizeRefusal)
  case store(StoreError)

  public var code: String {
    switch self {
    case .novelNotFound: "PRJ_001"
    case .novelExists: "library.novel_exists"
    case .wordTargetInverted: "PRJ_010"
    case .notesTooLong: "PRJ_012"
    case .unreadableRecords: "library.unreadable_records"
    case .volumeNotFound: "VOL_001"
    case .volumeExists: "story.volume_exists"
    case .volumeNotActive: "VOL_003"
    case .volumeInPlan: "VOL_002"
    case .milestoneNotFound: "MIL_001"
    case .milestoneExists: "MIL_002"
    case .milestoneReferenced: "MIL_003"
    case .milestoneSubjectUnknown: "MIL_004"
    case .promiseNotFound: "PMS_001"
    case .promiseExists: "PMS_002"
    case .secretNotFound: "FCT_001"
    case .entityNotFound: "ENT_001"
    case .entityExists: "bible.entity_exists"
    case .documentNotFound: "DOC_001"
    case .documentExists: "bible.document_exists"
    case .revisionNotFound: "bible.revision_not_found"
    case .revisionUnreadable: "bible.revision_unreadable"
    case .entityUnknown: "FCT_002"
    case .unlockMalformed: "FCT_005"
    case .clueNamesTerm: "FCT_006"
    case .cluesUncheckable: "story.clues_uncheckable"
    case .invalidKey: "domain.invalid_key"
    case .blank: "domain.blank"
    case .belowMinimum: "domain.below_minimum"
    case .aboveMaximum: "domain.above_maximum"
    case .tooLong: "domain.too_long"
    case .unknownKind: "domain.unknown_kind"
    case .noChanges: "domain.no_changes"
    case .empty: "domain.empty"
    case .chapterNotFound: "CHP_001"
    case .chapterNotFinal: "CHP_006"
    case .isolatedWithoutSummary: "CHP_005"
    case .summaryMissing: "CHP_010"
    case .draftNotFound: "DRF_001"
    case .draftFinal: "DRF_002"
    case .draftNotApproved: "DRF_004"
    case .draftStale: "DRF_007"
    case .draftConflict: "DRF_013"
    case .draftRevealStale: "DRF_017"
    case .draftGenerating: "DRF_019"
    case .notNextChapter: "DRF_018"
    case .finalizeOutOfOrder: "FIN_001"
    case .planRevealsLocked: "PLN_001"
    case .endingPlanned: "PLN_002"
    case .planClaims: "PLN_003"
    case .planRevealsHeld: "PLN_004"
    case .planFinal: "PLN_005"
    case .endingIncomplete: "BRF_003"
    case .scenesMalformed: "BRF_004"
    case .versionNotFound: "VER_001"
    case .versionFinal: "VER_002"
    case .versionUnreadable: "chapters.version_unreadable"
    case .lifecycleUnavailable: "chapters.lifecycle_unavailable"
    case .planStateUnavailable: "chapters.plan_state_unavailable"
    case .unreadable: "domain.unreadable"
    case .unrestrictedLocked: "library.unrestricted_locked"
    case .finalizeRefused(let refusal): refusal.code
    case .store(let error): error.code
    }
  }

  public var errorDescription: String? {
    switch self {
    case .novelNotFound(let novel): "Project \(novel.uuidString) not found"
    case .novelExists(let novel): "A novel with the id \(novel.uuidString) already exists"
    case .wordTargetInverted: "wordTarget.max must be greater than wordTarget.min"
    case .notesTooLong(let words, let maximum): "The notes are \(words) words; keep them to \(maximum) words or fewer"
    case .unreadableRecords(let kind, let count): "\(count) \(kind) records are stored in a form this version cannot read, so the novel cannot be copied faithfully"
    case .volumeNotFound(let volume): "Volume \(volume) not found"
    case .volumeExists(let volume): "A volume with the key \(volume) already exists in the novel"
    case .volumeNotActive(let volume): "Only the active volume’s goal can be marked met — volume \(volume) is not active"
    case .volumeInPlan(let volume, let chapter): "Volume \(volume) is still assigned to the plan for chapter \(chapter) — move or remove the chapter plans in it first"
    case .milestoneNotFound(let milestone): "Milestone \(milestone) not found"
    case .milestoneExists(let milestone): "A milestone with the key \(milestone) already exists in the project"
    case .milestoneReferenced(let milestone, let references): "Milestone \(milestone) is still referenced by \(references.joined(separator: ", ")) — remove those references first"
    case .milestoneSubjectUnknown(let entity): "Milestone subject \(entity) is not an entity of this novel"
    case .promiseNotFound(let promise): "Promise \(promise.kindName) \(promise.key) not found"
    case .promiseExists(let promise): "A \(promise.kindName) with the key \(promise.key) already exists in the project"
    case .secretNotFound(let secret): "Canon fact \(secret) not found"
    case .entityNotFound: "Entity not found"
    case .entityExists(let entity): "An entity with the key \(entity) already exists in the novel"
    case .documentNotFound: "Bible document not found"
    case .documentExists(let section, let slug): "The page \(section)/\(slug) already exists"
    case .revisionNotFound(let revision): "The page has no version \(revision)"
    case .revisionUnreadable(let revision): "Version \(revision) of the page is stored in a form this version cannot read"
    case .entityUnknown(let entity): "Unknown entity key \(entity) referenced by the knowledge operation"
    case .unlockMalformed(let reason): "Unlock condition is malformed — \(reason)"
    case .clueNamesTerm(let reason): "An allowed clue names a give-away term of its fact — \(reason)"
    case .cluesUncheckable(let reason): "The allowed clues could not be checked against the fact's terms — \(reason)"
    case .invalidKey(let field): "\(field) must be a non-empty key"
    case .blank(let field): "\(field) must not be blank"
    case .belowMinimum(let field, let minimum): "\(field) must be at least \(minimum)"
    case .aboveMaximum(let field, let maximum): "\(field) must be at most \(maximum)"
    case .tooLong(let field, let limit): "\(field) must be at most \(limit) characters"
    case .unknownKind(let kind): "Milestone kind \(kind) is not one of rank, event, learned_from, custom"
    case .noChanges: "At least one field must change"
    case .empty(let field): "\(field) must not be empty"
    case .chapterNotFound: "Chapter not found"
    case .chapterNotFinal: "Chapter is not finalized canon — amend is only available once the chapter is finalized"
    case .isolatedWithoutSummary: "Isolated chapter has no summary or continuation state — summarize the chapter before finalizing"
    case .summaryMissing(let chapter): "Chapter \(chapter) has no summary — write one or summarise with AI"
    case .draftNotFound: "Draft not found"
    case .draftFinal: "Draft is already finalized"
    case .draftNotApproved: "Draft is not approved — approve draft before finalizing"
    case .draftStale: "Draft is stale — something it was written against changed; regenerate or edit it, or approve it as written"
    case .draftConflict: "This chapter changed while you were working on it. Reload it and try again."
    case .draftRevealStale: "This draft is stale because a reveal in its plan no longer holds — fix the plan; it cannot be approved as written"
    case .draftGenerating(let chapter):
      "Chapter \(chapter) is being written by the AI right now — wait for it to finish, or cancel it to write the chapter yourself"
    case .notNextChapter(let chapter, let next):
      "Only chapter \(next) can be started now — chapters are written in order, so chapter \(chapter) cannot get a new draft"
    case .finalizeOutOfOrder: "Chapters must be finalized in order"
    case .planRevealsLocked(let chapter, let violations): "The plan for chapter \(chapter) reveals facts that are still locked there: \(violations)"
    case .endingPlanned(let chapter): "Chapter \(chapter) is already planned as the ending — clear its ending flag first"
    case .planClaims(let chapter, let reason): "The plan for chapter \(chapter) cannot claim these milestones: \(reason)"
    case .planRevealsHeld(let chapter, let violations):
      "The plan for chapter \(chapter) reveals facts that are locked there — change the plan before approving or finalizing: \(violations)"
    case .planFinal(let chapter): "Chapter \(chapter) is finalized — its plan can no longer change"
    case .endingIncomplete(let fields): "Ending contract is incomplete — \(fields) must not be empty"
    case .scenesMalformed(let reason): "Chapter plan scenes are malformed — \(reason)"
    case .versionNotFound(let chapter, let revision): "Chapter \(chapter) has no stored version \(revision)"
    case .versionFinal(let chapter): "Chapter \(chapter) is final — its prose is locked, so an earlier version cannot be restored; change it through Amend"
    case .versionUnreadable(let chapter, let revision): "Version \(revision) of chapter \(chapter) is stored in a form this version cannot read"
    case .lifecycleUnavailable(let chapter?): "The state of chapter \(chapter) is not up to date on this device, so it cannot be written, approved or finalized now"
    case .lifecycleUnavailable(nil): "The state of this novel's chapters is not up to date on this device, so no chapter can be started now"
    case .planStateUnavailable(let chapter): "The plans of this novel are not up to date on this device, so the plan for chapter \(chapter) cannot be written now"
    case .unreadable(let ref): "\(ref.kind.rawValue)/\(ref.key.rawValue) is stored in a form this version cannot read"
    case .unrestrictedLocked: "This novel's chats, drafts, final chapters or reviews hold, or may hold, unrestricted text, so it stays unrestricted"
    case .finalizeRefused(let refusal): refusal.message
    case .store(let error): error.errorDescription
    }
  }

  public static func == (left: DomainError, right: DomainError) -> Bool {
    left.code == right.code && left.errorDescription == right.errorDescription
  }
}
