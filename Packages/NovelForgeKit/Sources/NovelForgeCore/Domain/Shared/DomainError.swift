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
  case documentNotFound(section: String, slug: String)
  case documentExists(section: String, slug: String)
  case revisionNotFound(String)
  case revisionUnreadable(String)
  case entityUnknown(String)
  case unlockMalformed(String)
  case invalidKey(field: String)
  case blank(field: String)
  case belowMinimum(field: String, minimum: Int)
  case tooLong(field: String, limit: Int)
  case unknownKind(String)
  case noChanges
  case unreadable(EntityRef)
  case store(StoreError)

  public var code: String {
    switch self {
    case .novelNotFound: "PRJ_001"
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
    case .documentNotFound: "DOC_001"
    case .documentExists: "bible.document_exists"
    case .revisionNotFound: "bible.revision_not_found"
    case .revisionUnreadable: "bible.revision_unreadable"
    case .entityUnknown: "FCT_002"
    case .unlockMalformed: "FCT_005"
    case .invalidKey: "domain.invalid_key"
    case .blank: "domain.blank"
    case .belowMinimum: "domain.below_minimum"
    case .tooLong: "domain.too_long"
    case .unknownKind: "domain.unknown_kind"
    case .noChanges: "domain.no_changes"
    case .unreadable: "domain.unreadable"
    case .store(let error): error.code
    }
  }

  public var errorDescription: String? {
    switch self {
    case .novelNotFound(let novel): "Project \(novel.uuidString) not found"
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
    case .documentNotFound: "Bible document not found"
    case .documentExists(let section, let slug): "The page \(section)/\(slug) already exists"
    case .revisionNotFound(let revision): "The page has no version \(revision)"
    case .revisionUnreadable(let revision): "Version \(revision) of the page is stored in a form this version cannot read"
    case .entityUnknown(let entity): "Unknown entity key \(entity) referenced by the knowledge operation"
    case .unlockMalformed(let reason): "Unlock condition is malformed — \(reason)"
    case .invalidKey(let field): "\(field) must be a non-empty key"
    case .blank(let field): "\(field) must not be blank"
    case .belowMinimum(let field, let minimum): "\(field) must be at least \(minimum)"
    case .tooLong(let field, let limit): "\(field) must be at most \(limit) characters"
    case .unknownKind(let kind): "Milestone kind \(kind) is not one of rank, event, learned_from, custom"
    case .noChanges: "At least one field must change"
    case .unreadable(let ref): "\(ref.kind.rawValue)/\(ref.key.rawValue) is stored in a form this version cannot read"
    case .store(let error): error.errorDescription
    }
  }

  public static func == (left: DomainError, right: DomainError) -> Bool {
    left.code == right.code && left.errorDescription == right.errorDescription
  }
}
