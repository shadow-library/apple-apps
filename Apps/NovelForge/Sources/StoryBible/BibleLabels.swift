import Foundation
import NovelForgeCore

extension EntityType {
  var label: LocalizedStringResource {
    switch self {
    case .character: LocalizedStringResource("Character", table: "StoryBible")
    case .faction: LocalizedStringResource("Faction", table: "StoryBible")
    case .location: LocalizedStringResource("Location", table: "StoryBible")
    case .powerRule: LocalizedStringResource("Power rule", table: "StoryBible")
    case .item: LocalizedStringResource("Item", table: "StoryBible")
    case .concept: LocalizedStringResource("Concept", table: "StoryBible")
    }
  }

  var pluralLabel: LocalizedStringResource {
    switch self {
    case .character: LocalizedStringResource("Characters", table: "StoryBible")
    case .faction: LocalizedStringResource("Factions", table: "StoryBible")
    case .location: LocalizedStringResource("Locations", table: "StoryBible")
    case .powerRule: LocalizedStringResource("Power rules", table: "StoryBible")
    case .item: LocalizedStringResource("Items", table: "StoryBible")
    case .concept: LocalizedStringResource("Concepts", table: "StoryBible")
    }
  }

  var systemImage: String {
    switch self {
    case .character: "person"
    case .faction: "flag"
    case .location: "mappin.and.ellipse"
    case .powerRule: "bolt"
    case .item: "diamond"
    case .concept: "lightbulb"
    }
  }
}

extension EntitySignificance {
  var label: LocalizedStringResource {
    switch self {
    case .major: LocalizedStringResource("Major", table: "StoryBible")
    case .minor: LocalizedStringResource("Minor", table: "StoryBible")
    }
  }
}

extension BiblePageSection {
  var label: LocalizedStringResource {
    switch self {
    case .project: LocalizedStringResource("Core", table: "StoryBible")
    case .world: LocalizedStringResource("World", table: "StoryBible")
    case .power: LocalizedStringResource("Power", table: "StoryBible")
    case .plot: LocalizedStringResource("Plot", table: "StoryBible")
    case .storyState: LocalizedStringResource("Where things stand", table: "StoryBible")
    case .ai: LocalizedStringResource("Notes for the AI", table: "StoryBible")
    case .lore: LocalizedStringResource("Lore", table: "StoryBible")
    }
  }
}

extension StoredEnum where Value == EntityType {
  var knownType: EntityType? {
    guard case .known(let type) = self else { return nil }
    return type
  }
}

extension StoredEnum where Value == EntitySignificance {
  var knownSignificance: EntitySignificance? {
    guard case .known(let significance) = self else { return nil }
    return significance
  }
}
