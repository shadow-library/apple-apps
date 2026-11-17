import Foundation
import NovelForgeCore

enum BibleKindFilter: String, CaseIterable, Hashable, Identifiable {
  case all
  case records
  case guides

  var id: Self { self }

  var label: LocalizedStringResource {
    switch self {
    case .all: LocalizedStringResource("All kinds", table: "StoryBible")
    case .records: LocalizedStringResource("Records", table: "StoryBible")
    case .guides: LocalizedStringResource("Pages", table: "StoryBible")
    }
  }
}

struct BibleEntry: Identifiable, Equatable {
  enum Content: Equatable {
    case page(PageSummary)
    case entity(EntityRecord)
  }

  let content: Content
  let topic: BibleTopic
  let name: String
  let summary: String

  var id: String {
    switch content {
    case .page(let page): "page:\(page.section.rawValue)/\(page.slug)"
    case .entity(let entity): "entity:\(entity.entity)"
    }
  }

  var route: StoryBibleRoute {
    switch content {
    case .page(let page): .page(PageAddress(section: page.section, slug: page.slug))
    case .entity(let entity): .entity(entity.entity)
    }
  }

  var isPage: Bool {
    guard case .page = content else { return false }
    return true
  }

  fileprivate var entityType: EntityType? {
    guard case .entity(let entity) = content else { return nil }
    return entity.type.knownType ?? .concept
  }

  fileprivate var rank: Int {
    guard case .entity(let entity) = content else { return 0 }
    return entity.significance == .known(.major) ? 0 : 1
  }

  fileprivate func searchText() -> String {
    switch content {
    case .page(let page): "\(name) \(page.slug) \(summary)"
    case .entity(let entity): "\(name) \(entity.entity) \(entity.status ?? "") \(summary)"
    }
  }
}

enum BibleSubgroupKey: Hashable {
  case type(EntityType)
  case groups
  case guides
}

struct BibleSubgroup: Identifiable, Equatable {
  let key: BibleSubgroupKey
  let entries: [BibleEntry]

  var id: BibleSubgroupKey { key }

  var label: LocalizedStringResource {
    switch key {
    case .type(let type): type.pluralLabel
    case .groups: LocalizedStringResource("Groups", table: "StoryBible")
    case .guides: LocalizedStringResource("Guides", table: "StoryBible")
    }
  }
}

struct BibleGroup: Identifiable, Equatable {
  let topic: BibleTopic
  let subgroups: [BibleSubgroup]

  var id: BibleTopic { topic }
  var entries: [BibleEntry] { subgroups.flatMap(\.entries) }
}

struct BibleCatalogue: Equatable {
  static let empty = BibleCatalogue(pages: [], entities: [])

  let entries: [BibleEntry]
  let emptyPages: [PageSummary]

  init(pages: [PageSummary], entities: [EntityRecord], stages: BibleStages? = nil) {
    let records = entities.map { BibleEntry(content: .entity($0), topic: BibleTopics.topic(of: $0), name: $0.name, summary: BibleTopics.excerpt(of: $0)) }
    let guides = pages.filter { !$0.isEmpty }.map {
      BibleEntry(content: .page($0), topic: BibleTopics.topic(of: $0, stages: stages), name: $0.title, summary: $0.excerpt ?? "")
    }
    entries = records + guides
    emptyPages = pages.filter(\.isEmpty)
  }

  var isEmpty: Bool { entries.isEmpty && emptyPages.isEmpty }

  func groups(kind: BibleKindFilter, query: String) -> [BibleGroup] {
    let matching = entries.filter { entry in
      switch kind {
      case .all: true
      case .records: !entry.isPage
      case .guides: entry.isPage
      }
    }
    .filter { Self.matches($0.searchText(), query: query) }
    return BibleTopic.allCases.compactMap { topic in
      let members = matching.filter { $0.topic == topic }
      let subgroups = Self.subgroups(of: members, in: topic)
      return subgroups.isEmpty ? nil : BibleGroup(topic: topic, subgroups: subgroups)
    }
  }

  func matchingEmptyPages(kind: BibleKindFilter, query: String) -> [PageSummary] {
    guard kind != .records else { return [] }
    return emptyPages.filter { Self.matches("\($0.title) \($0.slug)", query: query) }
  }

  static func matches(_ text: String, query: String) -> Bool {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return true }
    return text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
  }

  private static func subgroups(of members: [BibleEntry], in topic: BibleTopic) -> [BibleSubgroup] {
    let records: [BibleSubgroup] = EntityType.allCases.map { type in
      let key: BibleSubgroupKey = type == .concept && (topic == .people || topic == .factions) ? .groups : .type(type)
      return BibleSubgroup(key: key, entries: members.filter { $0.entityType == type }.sorted(by: precedes))
    }
    let guides = BibleSubgroup(key: .guides, entries: members.filter(\.isPage).sorted(by: precedes))
    return (records + [guides]).filter { !$0.entries.isEmpty }
  }

  private static func precedes(_ left: BibleEntry, _ right: BibleEntry) -> Bool {
    if left.rank != right.rank { return left.rank < right.rank }
    return left.name.localizedStandardCompare(right.name) == .orderedAscending
  }
}
