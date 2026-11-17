import Foundation
import NovelForgeCore

enum NovelSheet: Identifiable, Equatable {
  case create
  case edit(NovelRecord)
  case clone(NovelRecord)

  var id: String {
    switch self {
    case .create: "create"
    case .edit(let novel): "edit-\(novel.id.uuidString)"
    case .clone(let novel): "clone-\(novel.id.uuidString)"
    }
  }
}
