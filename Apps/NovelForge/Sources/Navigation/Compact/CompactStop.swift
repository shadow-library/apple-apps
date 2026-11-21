import Foundation

enum CompactStop: Hashable, Sendable {
  case section(NovelSection)
  case pending
}
