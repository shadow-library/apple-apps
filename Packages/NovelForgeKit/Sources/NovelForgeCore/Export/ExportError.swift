import Foundation
import ShadowCore
import ShadowStore

public enum ExportError: ShadowError, Equatable {
  case novelNotFound(UUID)
  case noChapters
  case unreadableChapters(count: Int)
  case archiveTooManyEntries(count: Int)
  case archiveEntryTooLarge(name: String, bytes: Int)
  case archiveTooLarge(bytes: Int)
  case archiveNameInvalid(String)
  case archiveDuplicateName(String)
  case store(StoreError)

  public var code: String {
    switch self {
    case .novelNotFound: "PRJ_001"
    case .noChapters: "EXP_001"
    case .unreadableChapters: "export.unreadable_chapters"
    case .archiveTooManyEntries: "export.archive_too_many_entries"
    case .archiveEntryTooLarge: "export.archive_entry_too_large"
    case .archiveTooLarge: "export.archive_too_large"
    case .archiveNameInvalid: "export.archive_name_invalid"
    case .archiveDuplicateName: "export.archive_duplicate_name"
    case .store(let error): error.code
    }
  }

  public var errorDescription: String? {
    switch self {
    case .novelNotFound(let novel): "Project \(novel.uuidString) not found"
    case .noChapters: "Nothing to export — this project has no chapters yet"
    case .unreadableChapters(let count): "\(count) final chapters are stored in a form this version cannot read, so the export would leave them out"
    case .archiveTooManyEntries(let count): "The package would hold \(count) files; a plain archive holds at most 65535"
    case .archiveEntryTooLarge(let name, let bytes): "\(name) is \(bytes) bytes; a plain archive holds at most 4 GiB per file"
    case .archiveTooLarge(let bytes): "The package would be \(bytes) bytes; a plain archive holds at most 4 GiB"
    case .archiveNameInvalid(let name): "\(name.isEmpty ? "An empty name" : name) cannot be a file name in the package"
    case .archiveDuplicateName(let name): "\(name) appears twice in the package"
    case .store(let error): error.errorDescription
    }
  }

  public static func == (left: ExportError, right: ExportError) -> Bool {
    left.code == right.code && left.errorDescription == right.errorDescription
  }
}
