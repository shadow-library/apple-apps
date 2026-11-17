import Foundation
import ShadowCore
import ShadowStore

public enum ChatSessionError: ShadowError, Equatable {
  case novelNotFound(UUID)
  /// The novel holds no such chat, or it was deleted.
  case notFound(UUID)
  case unreadable(UUID)
  case record(ChatRecordError)
  case store(StoreError)

  public var code: String {
    switch self {
    case .novelNotFound: "PRJ_001"
    case .notFound: "CHT_001"
    case .unreadable: "chat_session.unreadable"
    case .record(let error): error.code
    case .store(let error): error.code
    }
  }

  public var errorDescription: String? {
    switch self {
    case .novelNotFound(let novel): "Project \(novel.uuidString) not found"
    case .notFound: "Chat session not found"
    case .unreadable: "This chat is stored in a form this version cannot read, so it cannot be changed here"
    case .record(let error): error.errorDescription
    case .store(let error): error.errorDescription
    }
  }

  public static func == (left: ChatSessionError, right: ChatSessionError) -> Bool {
    left.code == right.code && left.errorDescription == right.errorDescription
  }
}
