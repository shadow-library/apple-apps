import Foundation
import ShadowCore
import ShadowStore

public enum BibleError: ShadowError, Equatable {
  case novelNotFound(UUID)
  case entityNotFound(String)
  case documentNotFound(section: String, slug: String)
  case documentExists(section: String, slug: String)
  case revisionNotFound(String)
  case revisionUnreadable(String)
  case invalidKey(field: String)
  case blank(field: String)
  case noChanges
  case unreadable(EntityRef)
  case store(StoreError)

  public var code: String {
    switch self {
    case .novelNotFound: "PRJ_001"
    case .entityNotFound: "ENT_001"
    case .documentNotFound: "DOC_001"
    case .documentExists: "bible.document_exists"
    case .revisionNotFound: "bible.revision_not_found"
    case .revisionUnreadable: "bible.revision_unreadable"
    case .invalidKey: "bible.invalid_key"
    case .blank: "bible.blank"
    case .noChanges: "bible.no_changes"
    case .unreadable: "bible.unreadable"
    case .store(let error): error.code
    }
  }

  public var errorDescription: String? {
    switch self {
    case .novelNotFound(let novel): "Project \(novel.uuidString) not found"
    case .entityNotFound: "Entity not found"
    case .documentNotFound: "Bible document not found"
    case .documentExists(let section, let slug): "The page \(section)/\(slug) already exists"
    case .revisionNotFound(let revision): "The page has no version \(revision)"
    case .revisionUnreadable(let revision): "Version \(revision) of the page is stored in a form this version cannot read"
    case .invalidKey(let field): "\(field) must not be empty"
    case .blank(let field): "\(field) must not be blank"
    case .noChanges: "At least one field must change"
    case .unreadable(let ref): "\(ref.kind.rawValue)/\(ref.key.rawValue) is stored in a form this version cannot read"
    case .store(let error): error.errorDescription
    }
  }

  public static func == (left: BibleError, right: BibleError) -> Bool {
    left.code == right.code && left.errorDescription == right.errorDescription
  }
}

extension VaultStore {
  public func writeBible<T: Sendable>(_ body: @Sendable (inout WriteTransaction) throws(BibleError) -> T) async throws(BibleError) -> T {
    do {
      return try await write { transaction in try body(&transaction) }
    } catch {
      if case .aborted(let cause) = error, let bible = cause as? BibleError { throw bible }
      throw .store(error)
    }
  }
}
