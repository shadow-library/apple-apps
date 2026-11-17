import Foundation
import NovelForgeCore

extension NovelRecord {
  var displayTitle: String {
    let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? name : trimmed
  }

  var hasDistinctName: Bool { name != displayTitle }
}
