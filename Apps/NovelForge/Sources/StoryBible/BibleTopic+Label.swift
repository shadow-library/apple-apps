import Foundation
import NovelForgeCore

extension BibleTopic {
  var label: LocalizedStringResource {
    switch self {
    case .core: LocalizedStringResource("Story core", table: "StoryBible")
    case .people: LocalizedStringResource("People", table: "StoryBible")
    case .factions: LocalizedStringResource("Factions & peoples", table: "StoryBible")
    case .places: LocalizedStringResource("Places", table: "StoryBible")
    case .power: LocalizedStringResource("Power & rules", table: "StoryBible")
    case .lore: LocalizedStringResource("Lore & history", table: "StoryBible")
    case .objects: LocalizedStringResource("Objects", table: "StoryBible")
    case .author: LocalizedStringResource("Author-only", table: "StoryBible")
    }
  }
}
