import Foundation

// platform/apps/novel-forge-web/src/lib/bible-topics.ts:3
public enum BibleTopic: String, CaseIterable, Sendable {
  case core
  case people
  case factions
  case places
  case power
  case lore
  case objects
  case author
}

// platform/apps/novel-forge-web/src/lib/bible-topics.ts and story-bible.ts; the manifest-stage step of documentTopic (bible-topics.ts:226) needs the server's bibleRoles, which is not ported
public enum BibleTopics {
  // bible-topics.ts:219
  public static func topic(of entity: EntityRecord) -> BibleTopic {
    guard case .known(let type) = entity.type else { return .lore }
    switch type {
    case .character: return .people
    case .faction: return .factions
    case .location: return .places
    case .powerRule: return .power
    case .item: return .objects
    case .concept: return byKeywords(entity.name) ?? byKeywords(excerpt(of: entity)) ?? .lore
    }
  }

  // bible-topics.ts:270
  public static func topic(of page: PageSummary) -> BibleTopic {
    let label = "\(page.title) \(page.slug.jsReplace(Pattern.separatorRuns, " "))"
    if isAuthorOnly(label) { return .author }
    if page.section == .power { return .power }
    let fallback = sectionTopic(page.section)
    return byKeywords(label, among: fallback == .core ? [.people, .factions, .places] : BibleTopic.allCases) ?? fallback
  }

  // bible-topics.ts:195
  public static func isAuthorOnly(_ text: String) -> Bool {
    Pattern.authorOnly.test(text)
  }

  // story-bible.ts:74
  public static func excerpt(of entity: EntityRecord, limit: Int = 140) -> String {
    guard let body = entity.body?.jsTrim(), !body.isEmpty else { return "" }
    let paragraph = plainText(strippingHeading(body, name: entity.name)).jsSplit(Pattern.paragraphBreak, limit: 1).first ?? ""
    return clip(paragraph, limit: limit)
  }

  // bible-topics.ts:48
  private static func sectionTopic(_ section: BiblePageSection) -> BibleTopic {
    switch section {
    case .project, .plot, .storyState, .ai: .core
    case .world, .lore: .lore
    case .power: .power
    }
  }

  // bible-topics.ts:207
  private static func byKeywords(_ text: String, among allowed: [BibleTopic] = BibleTopic.allCases) -> BibleTopic? {
    let pieces: [String] = text.jsToLowerCase().jsSplit(Pattern.nonWord)
    let found = Set(pieces.filter { !$0.isEmpty }.map { JSString($0) })
    for entry in keywordTopics where allowed.contains(entry.topic) {
      if entry.words.contains(where: { found.contains(JSString($0)) }) { return entry.topic }
    }
    return nil
  }

  // story-bible.ts:45
  private static func strippingHeading(_ body: String, name: String) -> String {
    guard let match = body.jsMatchAll(Pattern.entityHeading).first, let captured = match.groups.first.flatMap({ $0 }), !captured.isEmpty else { return body }
    let heading = captured.jsReplace(Pattern.emphasisMarks, "").jsTrim().jsToLowerCase()
    guard heading.jsEquals(name.jsTrim().jsToLowerCase()) else { return body }
    return body.jsSlice(match.endIndex).jsReplace(Pattern.leadingSpace, "")
  }

  // story-bible.ts:53
  private static func plainText(_ markdown: String) -> String {
    markdown.jsSplit("\n")
      .filter { !Pattern.headingLine.test($0) && !Pattern.ruleLine.test($0) }
      .map { $0.jsReplace(Pattern.listMarker, "").jsReplace(Pattern.quoteMarker, "") }
      .joined(separator: "\n")
      .jsReplace(Pattern.image, "")
      .jsReplace(Pattern.link, "$1")
      .jsReplace(Pattern.inlineMarks, "")
      .jsTrim()
  }

  // story-bible.ts:66
  private static func clip(_ text: String, limit: Int) -> String {
    let flat = text.jsReplace(Pattern.whitespaceRuns, " ").jsTrim()
    guard flat.jsLength > limit else { return flat }
    let cut = flat.jsSlice(0, limit)
    let lastSpace = lastSpace(in: cut)
    let kept = Double(lastSpace) > Double(limit) / 2 ? cut.jsSlice(0, lastSpace) : cut
    return kept.jsReplace(Pattern.trailingPunctuation, "") + "…"
  }

  private static func lastSpace(in text: String) -> Int {
    guard let index = text.jsCodeUnits.lastIndex(of: 0x20) else { return -1 }
    return index
  }

  private enum Pattern {
    static let authorOnly = regex(#"\bauthor[\s_-]*(only|notes?)\b|\bfor[\s_-]+the[\s_-]+author\b"#, "i")
    static let separatorRuns = regex(#"[-_]+"#, "g")
    static let nonWord = regex(#"[^\p{L}\p{N}]+"#, "u")
    static let entityHeading = regex(#"^\s*#{1,3}[ \t]+(.+?)[ \t]*(?:\r?\n|$)"#)
    static let emphasisMarks = regex(#"[*_`]"#, "g")
    static let leadingSpace = regex(#"^\s+"#)
    static let headingLine = regex(#"^\s*#{1,6}\s"#)
    static let ruleLine = regex(#"^\s*(?:[-*_]\s*){3,}$"#)
    static let listMarker = regex(#"^\s*(?:[-*+]|\d+[.)])\s+"#)
    static let quoteMarker = regex(#"^\s*>\s?"#)
    static let image = regex(#"!\[[^\]]*\]\([^)]*\)"#, "g")
    static let link = regex(#"\[([^\]]*)\]\([^)]*\)"#, "g")
    static let inlineMarks = regex(#"(\*\*|__|\*|`|~~)"#, "g")
    static let paragraphBreak = regex(#"\n\s*\n"#)
    static let whitespaceRuns = regex(#"\s+"#, "g")
    static let trailingPunctuation = regex(#"[\s,;:.-]+$"#)

    private static func regex(_ source: String, _ flags: String = "") -> JSRegex {
      do {
        return try JSRegex(source, flags: flags)
      } catch {
        preconditionFailure("the pattern \(source) is not a valid regular expression")
      }
    }
  }

  // bible-topics.ts:59
  private static let keywordTopics: [(topic: BibleTopic, words: [String])] = [
    (
      .people,
      [
        "character", "characters", "cast", "ensemble", "protagonist", "antagonist", "relationship", "relationships", "romance", "family", "crowd", "crew", "friends",
        "companions", "squad", "team",
      ]
    ),
    (
      .factions,
      [
        "faction", "factions", "guild", "guilds", "clan", "clans", "order", "house", "houses", "dynasty", "empire", "kingdom", "nation", "nations", "tribe", "tribes",
        "race", "races", "species", "peoples", "cult", "sect", "alliance", "army", "council", "church", "organisation", "organization", "politics",
      ]
    ),
    (
      .places,
      [
        "location", "locations", "place", "places", "geography", "map", "city", "cities", "town", "village", "region", "regions", "continent", "realm", "realms", "land",
        "lands", "island", "forest", "mountain", "mountains", "sea", "ocean", "river", "desert", "dungeon", "dungeons", "tower", "castle", "academy", "school", "district",
        "planet",
      ]
    ),
    (
      .power,
      [
        "power", "powers", "magic", "mana", "system", "level", "levels", "levelling", "leveling", "class", "classes", "ability", "abilities", "skill", "skills", "rank",
        "ranks", "tier", "tiers", "cultivation", "progression", "spell", "spells", "technique", "techniques", "bloodline", "scaling",
      ]
    ),
    (
      .objects,
      ["item", "items", "artifact", "artifacts", "artefact", "artefacts", "relic", "relics", "weapon", "weapons", "sword", "blade", "ring", "amulet", "treasure", "equipment"]
    ),
    (
      .lore,
      ["history", "lore", "legend", "legends", "myth", "myths", "mythology", "prophecy", "religion", "gods", "era", "age", "war", "timeline", "calendar", "culture"]
    ),
  ]
}
