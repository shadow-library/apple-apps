import Foundation
import NovelForgeCore

nonisolated struct PageAddress: Hashable, Sendable {
  let section: BiblePageSection
  let slug: String
}

nonisolated enum StoryBibleRoute: Hashable {
  case page(PageAddress)
  case entity(String)
}
