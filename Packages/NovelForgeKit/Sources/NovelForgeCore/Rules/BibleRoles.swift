import Foundation
import ShadowText

// apps/novel-forge-server/src/modules/eval/bible-readiness.ts:54
struct BibleRole: Sendable, Equatable {
  let stage: BibleStage
  let label: String
  let address: String
  let coveredBy: [String]

  var covered: Bool { !coveredBy.isEmpty }
}

public struct BibleStages: Sendable, Equatable {
  private let byAddress: [JSString: BibleStage]

  init(byAddress: [JSString: BibleStage]) {
    self.byAddress = byAddress
  }

  public func stage(of page: PageSummary) -> BibleStage? {
    byAddress[JSString(BibleRoles.address(section: page.section, slug: page.slug))]
  }
}

// apps/novel-forge-server/src/modules/eval/bible-readiness.ts; a page stands for a document row: its derived title, and `isEmpty` for `!hasText(body)`
enum BibleRoles {
  // bible-readiness.ts:150
  static func roles(pages: [PageSummary], entities: [EntityRecord], volumes: [VolumeRecord]) -> [BibleRole] {
    bibleManifest.map { chapter in
      let documents = pages.filter { !$0.isEmpty && serves($0, chapter) }.map { address(section: $0.section, slug: $0.slug) }
      let records = recordCoverage(of: chapter.stage, entities: entities, volumes: volumes).map { [$0] } ?? []
      return BibleRole(stage: chapter.stage, label: chapter.role.label, address: address(section: chapter.section, slug: chapter.slug), coveredBy: documents + records)
    }
  }

  // platform/apps/novel-forge-web/src/lib/bible-topics.ts:252: a document covering several roles files under the earliest in manifest order
  static func stages(of roles: [BibleRole]) -> BibleStages {
    var stages = [JSString: BibleStage]()
    for role in roles {
      for covering in role.coveredBy {
        let key = JSString(covering)
        if let current = stages[key], rank(current) <= rank(role.stage) { continue }
        stages[key] = role.stage
      }
    }
    return BibleStages(byAddress: stages)
  }

  static func stages(pages: [PageSummary], entities: [EntityRecord], volumes: [VolumeRecord]) -> BibleStages {
    stages(of: roles(pages: pages, entities: entities, volumes: volumes))
  }

  // bible-readiness.ts:122
  static func address(section: BiblePageSection, slug: String) -> String {
    "\(section.rawValue)/\(slug)"
  }

  // bible-readiness.ts:86
  private static func recordCoverage(of stage: BibleStage, entities: [EntityRecord], volumes: [VolumeRecord]) -> String? {
    switch stage {
    case .factionsAndLocations:
      let factions = entities.count { $0.type == .known(.faction) }
      let locations = entities.count { $0.type == .known(.location) }
      guard factions > 0 else { return nil }
      return "\(plural(factions, "faction record")) and \(plural(locations, "location record"))"
    case .characters:
      let characters = entities.filter { $0.type == .known(.character) }
      guard !characters.allSatisfy({ $0.significance == .known(.minor) }) else { return nil }
      return plural(characters.count, "character record")
    case .volumes:
      let planned = volumes.count { !($0.objective ?? "").jsTrim().isEmpty }
      guard planned > 0 else { return nil }
      return "\(plural(planned, "volume")) with goals"
    case .foundation, .world, .power, .plot:
      return nil
    }
  }

  // bible-readiness.ts:114
  private static func plural(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
  }

  // bible-readiness.ts:130
  private static func serves(_ page: PageSummary, _ chapter: BibleChapterSpec) -> Bool {
    if page.section == chapter.section, page.slug.jsEquals(chapter.slug) { return true }
    guard chapter.role.sections.contains(page.section) else { return false }
    let words = "\(page.slug) \(page.title)".jsToLowerCase().jsSplit(wordSeparator)
    return words.contains { word in chapter.role.keywords.contains { matches(word, keyword: $0) } }
  }

  // bible-readiness.ts:126
  private static func matches(_ word: String, keyword: String) -> Bool {
    word.jsEquals(keyword) || word.jsEquals(keyword + "s") || word.jsEquals(keyword + "es") || (keyword.jsEndsWith("y") && word.jsEquals(keyword.jsSlice(0, -1) + "ies"))
  }

  private static func rank(_ stage: BibleStage) -> Int {
    bibleStageOrder.firstIndex(of: stage) ?? bibleStageOrder.count
  }

  private static let wordSeparator = ProseRegex.literal(#"[^a-z0-9]+"#)
}
