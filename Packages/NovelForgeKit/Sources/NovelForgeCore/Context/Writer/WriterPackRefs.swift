import ShadowCore

// apps/novel-forge-server/src/modules/ai/context/context-ref-resolver.ts:15
struct WriterRefResolution: Equatable, Sendable {
  var resolved: [ChatPackSection] = []
  var unresolved: [String] = []
  /// Refs the chapter's disclosure policy refused on purpose: later volumes, chapters, threads and mysteries, excluded pages.
  var withheld: [String] = []
  /// The resolved `entity:` refs whose entity is a character.
  var characters: [String] = []
  /// The resolved `fact:` refs the writer reads as a writing constraint: a locked secret's cover note in place of its truth.
  var constraints: [String] = []
}

// apps/novel-forge-server/src/modules/ai/context/pack-render.ts:144-147, the named groups numbered
private let headingLine = ProseRegex.literal(#"^(#{1,6}\s+(.+)|\*\*([^*\n]+)\*\*:?|__([^_\n]+)__:?)\s*$"#)
private let inlineLabel = ProseRegex.literal(#"^(?:\*\*|__)?([^*_:\n]{1,40}?)(?:\*\*|__)?:"#)
private let guidanceWords = ProseRegex.literal(#"\b(drafter|drafting|cautions?|prohibit\w*|avoid|warnings?|guidance|off[- ]limits)\b"#, "i")
private let prohibitionOpener = ProseRegex.literal(#"^(?:\*\*|__)?(never|do not|don't|must not)\b"#, "i")
private let paragraphBreak = ProseRegex.literal(#"\n\n+"#)
private let headingMarks = ProseRegex.literal(#"^#+\s*"#)
private let decimalPrefix = ProseRegex.literal(#"^[+-]?\d+"#)

enum WriterPackRender {
  // context-ref-resolver.ts:34
  static let entityCardBudget = 800
  // context-ref-resolver.ts:250
  static let biblePageBudget = 8_000
  // context-ref-resolver.ts:217
  static let worldFactValueBudget = 150

  struct Card: Equatable {
    var text: String
    var truncated: Bool
  }

  private struct CardBlock {
    var paragraphs: [String]
    var guidance: Bool
    var heading: Bool
  }

  // pack-render.ts:155
  private static func headingText(_ paragraph: String) -> String? {
    guard let match = headingLine.exec(paragraph.jsSplit("\n", limit: 1).first ?? "") else { return nil }
    return match.groups[1] ?? match.groups[2] ?? match.groups[3] ?? ""
  }

  // pack-render.ts:160
  private static func isGuidanceParagraph(_ paragraph: String) -> Bool {
    if let label = inlineLabel.exec(paragraph)?.groups.first ?? nil, guidanceWords.test(label) { return true }
    return prohibitionOpener.test(paragraph.jsTrimStart())
  }

  /// Authored cards tend to end on the drafter guidance and the prohibitions, which a tail cut removes first, so an over-budget card leads with those blocks.
  // pack-render.ts:167
  private static func guidanceFirst(_ body: String) -> String {
    var blocks: [CardBlock] = []
    for paragraph in body.jsSplit(paragraphBreak) {
      let heading = headingText(paragraph)
      if let heading {
        blocks.append(CardBlock(paragraphs: [paragraph], guidance: guidanceWords.test(heading), heading: true))
      } else if blocks.last?.heading == true {
        blocks[blocks.count - 1].paragraphs.append(paragraph)
      } else {
        blocks.append(CardBlock(paragraphs: [paragraph], guidance: isGuidanceParagraph(paragraph), heading: false))
      }
    }
    return (blocks.filter(\.guidance) + blocks.filter { !$0.guidance }).flatMap(\.paragraphs).joined(separator: "\n\n")
  }

  // pack-render.ts:180
  static func entityCard(_ entity: WriterPackEntity, maxTokens: Int) -> Card {
    let aliasLine = entity.aliases.isEmpty ? "" : "\nAliases: \(entity.aliases.joined(separator: ", "))"
    let statusLine = entity.status.map { "\nStatus: \($0)" } ?? ""
    let raw = entity.body ?? entity.notes ?? ""
    let cut = countTokens(raw) > maxTokens ? truncateAtParagraph(guidanceFirst(raw), maxTokens: maxTokens) : TruncatedText(text: raw, truncated: false)
    return Card(text: "**\(entity.name)** (\(entity.type), \(entity.status ?? "active"))\n\(cut.text)\(aliasLine)\(statusLine)", truncated: cut.truncated)
  }

  // pack-render.ts:189
  static func entityLabel(_ entity: WriterPackEntity, pov: Bool = false) -> String {
    "\(pov ? "POV " : "")\(entity.type.uppercased().jsSplit("_").joined(separator: " ")): \(entity.name)"
  }

  // pack-render.ts:214
  static func entityCardTier(_ status: String?) -> ChatPackTier {
    status == "planned" ? .approvedIntent : .canonical
  }

  // pack-render.ts:209 with sections.ts:102 (renderLabeledSection)
  static func refSection(_ ref: String, label: String, content: String, tier: ChatPackTier, truncated: Bool = false) -> ChatPackSection {
    let rendered = "## \(label)\n\n\(content)"
    return ChatPackSection(key: "ref:\(ref)", tier: tier, segment: .volatile, tokens: countTokens(rendered), truncated: truncated, sourceRefs: [ref], rendered: rendered)
  }

  // pack-render.ts:112
  static func sectionSubject(_ section: ChatPackSection) -> String {
    let heading = (section.rendered.jsSplit("\n", limit: 1).first ?? "").jsReplace(headingMarks, "")
    let colon = heading.jsIndexOf(":")
    return colon == -1 ? heading : heading.jsSlice(colon + 1).jsTrim()
  }

  /// An isolated chapter as a standard call reads it: with no approved bridge (isolation bridges are out of phase 7), its title withheld and its summary walled off.
  // pack-render.ts:254 with finalize-review/isolation-bridge.ts:189 (bridgedSummary) and no bridge
  static func walledOff(title: String?, summary: String?, isolated: Bool) -> (title: String?, summary: String?) {
    isolated ? (nil, ChatPack.noBridgeSummary) : (title, summary)
  }

  // The catalog lists world facts as `category: key | key`; category wins, `category/key` pins one fact. pack-render.ts:199
  static func matchWorldFacts(_ rows: [WriterPackWorldFact], _ value: String) -> (facts: [WriterPackWorldFact], byKey: Bool)? {
    let byCategory = rows.filter { $0.category.jsEquals(value) }
    if !byCategory.isEmpty { return (byCategory, false) }
    let slash = value.jsIndexOf("/")
    let pinned = slash == -1 ? [] : rows.filter { $0.category.jsEquals(value.jsSlice(0, slash)) && $0.key.jsEquals(value.jsSlice(slash + 1)) }
    if !pinned.isEmpty { return (pinned, true) }
    let byKey = rows.filter { $0.key.jsEquals(value) }
    return byKey.isEmpty ? nil : (byKey, true)
  }

  /// JavaScript's `parseInt(value, 10)`; nil where it gives NaN or a number no chapter could be.
  static func parseDecimal(_ value: String) -> Int? {
    guard let digits = decimalPrefix.exec(value.jsTrimStart())?.text else { return nil }
    return Int(digits)
  }
}

extension WriterPackWorld {
  private struct RefParts {
    let prefix: String
    let value: String

    init(_ ref: String) {
      let colon = ref.jsIndexOf(":")
      prefix = colon == -1 ? "" : ref.jsSlice(0, colon)
      value = ref.jsSlice(colon + 1)
    }
  }

  private struct RefRows {
    var entities: [JSString: WriterPackEntity] = [:]
    var worldFacts: [WriterPackWorldFact] = []
    var threads: [JSString: WriterPackThread] = [:]
    var mysteries: [JSString: WriterPackMystery] = [:]
    var chapters: [Int: WriterPackFinal] = [:]
    var volumes: [JSString: WriterPackVolume] = [:]
    var pages: [JSString: DisclosurePage] = [:]
    var facts: [JSString: DisclosureFact] = [:]
    var hiddenFactKeys: Set<JSString> = []
  }

  /// `refs` resolved for the writer of `chapter`: each one the policy may show becomes a writer-safe section, in the order given.
  // apps/novel-forge-server/src/modules/ai/context/context-ref-resolver.ts:66 (resolveRefsFor), with no isolation bridge
  func resolveRefs(_ refs: [String], chapter: Int, disclosure: inout WriterDisclosurePolicy) throws(DisclosureError) -> WriterRefResolution {
    let refused = refs.filter { !disclosure.canResolve($0) }
    let unique = refs.jsUnique().filter { disclosure.canResolve($0) }
    let rows = refRows(unique, chapter: chapter)
    var resolution = WriterRefResolution(withheld: refused.jsUnique())
    for ref in unique {
      let parts = RefParts(ref)
      let value = JSString(parts.value)
      if parts.prefix == "fact", rows.hiddenFactKeys.contains(value), (rows.facts[value]?.writerNote?.jsTrim() ?? "").isEmpty { continue }
      let opened: Int?? =
        switch parts.prefix {
        case "thread": rows.threads[value].map(\.openedChapter)
        case "mystery": rows.mysteries[value].map(\.openedChapter)
        default: nil
        }
      if let opened, !disclosure.opensBy(opened) {
        resolution.withheld.append(ref)
        continue
      }
      guard let section = try resolveRef(ref, parts, rows, disclosure: &disclosure) else {
        resolution.unresolved.append(ref)
        continue
      }
      resolution.resolved.append(section)
      if parts.prefix == "fact", rows.hiddenFactKeys.contains(value) { resolution.constraints.append(ref) }
    }
    resolution.characters = unique.filter { ref in
      ref.jsStartsWith("entity:") && rows.entities[JSString(ref.jsSlice("entity:".jsLength))]?.type == EntityType.character.rawValue
    }
    return resolution
  }

  // context-ref-resolver.ts:85-162
  private func refRows(_ refs: [String], chapter: Int) -> RefRows {
    var keys: [String: Set<JSString>] = [:]
    var chapterNumbers = Set<Int>()
    var pageAddresses = Set<JSString>()
    for ref in refs where ref.jsIndexOf(":") != -1 {
      let parts = RefParts(ref)
      switch parts.prefix {
      case "world_fact": keys["world_fact", default: []].formUnion(([parts.value] + parts.value.jsSplit("/")).map { JSString($0) })
      case "chapter": if let number = WriterPackRender.parseDecimal(parts.value) { chapterNumbers.insert(number) }
      case "bible_doc": pageAddresses.insert(JSString(parts.value.jsIncludes("/") ? parts.value : "\(parts.value)/"))
      default: keys[parts.prefix, default: []].insert(JSString(parts.value))
      }
    }
    var rows = RefRows()
    let entityKeys = keys["entity"] ?? []
    for entity in entities where entityKeys.contains(JSString(entity.entity)) { rows.entities[JSString(entity.entity)] = entity }
    let worldKeys = keys["world_fact"] ?? []
    rows.worldFacts = worldFacts.filter { worldKeys.contains(JSString($0.category)) || worldKeys.contains(JSString($0.key)) }
    for thread in threads where keys["thread"]?.contains(JSString(thread.thread)) == true { rows.threads[JSString(thread.thread)] = thread }
    for mystery in mysteries where keys["mystery"]?.contains(JSString(mystery.mystery)) == true { rows.mysteries[JSString(mystery.mystery)] = mystery }
    for final in finals where chapterNumbers.contains(final.chapter) { rows.chapters[final.chapter] = final }
    for volume in volumes where keys["volume"]?.contains(JSString(volume.volume)) == true { rows.volumes[JSString(volume.volume)] = volume }
    for page in pages where pageAddresses.contains(JSString("\(page.address.section)/\(page.address.slug)")) {
      rows.pages[JSString("\(page.address.section)/\(page.address.slug)")] = page
    }
    let factRows = facts.filter { keys["fact"]?.contains(JSString($0.factKey)) == true }
    for fact in factRows { rows.facts[JSString(fact.factKey)] = fact }
    if !factRows.isEmpty { rows.hiddenFactKeys = writerHiddenFactKeys(in: disclosureWorld, chapter: chapter, facts: factRows) }
    return rows
  }

  // context-ref-resolver.ts:204
  private func resolveRef(_ ref: String, _ parts: RefParts, _ rows: RefRows, disclosure: inout WriterDisclosurePolicy) throws(DisclosureError) -> ChatPackSection? {
    let value = JSString(parts.value)
    switch parts.prefix {
    case "entity":
      guard let entity = rows.entities[value] else { return nil }
      let card = WriterPackRender.entityCard(entity, maxTokens: WriterPackRender.entityCardBudget)
      let label = try disclosure.scrub(WriterPackRender.entityLabel(entity), .heading)
      return WriterPackRender.refSection(
        ref, label: label, content: try disclosure.scrub(card.text, .entity), tier: WriterPackRender.entityCardTier(entity.status), truncated: card.truncated)
    case "world_fact":
      guard let match = WriterPackRender.matchWorldFacts(rows.worldFacts, parts.value) else { return nil }
      let lines = match.facts.map { "\(match.byKey ? "\($0.category)/" : "")\($0.key): \(truncateAtParagraph($0.value, maxTokens: WriterPackRender.worldFactValueBudget).text)" }
      let label = try disclosure.scrub("WORLD FACTS: \(parts.value)", .heading)
      return WriterPackRender.refSection(ref, label: label, content: try disclosure.scrub(lines.joined(separator: "\n"), .reference), tier: .canonical)
    case "thread":
      guard let thread = rows.threads[value] else { return nil }
      let span = "ch \(thread.openedChapter.map(String.init) ?? "?")–\(thread.closedChapter.map(String.init) ?? "?")"
      let text = "**\(thread.thread)** (\(thread.status), \(span))\n\(thread.summary ?? "")"
      let label = try disclosure.scrub("PLOT THREAD: \(thread.thread)", .heading)
      return WriterPackRender.refSection(ref, label: label, content: try disclosure.scrub(text, .reference), tier: .canonical)
    case "mystery":
      guard let mystery = rows.mysteries[value] else { return nil }
      let text = "**\(mystery.mystery)** (\(mystery.status), ch \(mystery.openedChapter.map(String.init) ?? "?"))\n\(mystery.question)"
      let label = try disclosure.scrub("MYSTERY: \(mystery.mystery)", .heading)
      return WriterPackRender.refSection(ref, label: label, content: try disclosure.scrub(text, .reference), tier: .canonical)
    case "chapter":
      guard let number = WriterPackRender.parseDecimal(parts.value), let found = rows.chapters[number] else { return nil }
      let readable = WriterPackRender.walledOff(title: found.title, summary: found.summary, isolated: found.isolated)
      let title = readable.title.flatMap { $0.isEmpty ? nil : $0 }
      let label = try disclosure.scrub("EARLIER CHAPTER: \(number)\(title.map { " — \($0)" } ?? "")", .heading)
      let text = "Ch \(number): \(try disclosure.scrub(readable.summary ?? "", .summary))"
      return WriterPackRender.refSection(ref, label: label, content: text, tier: .canonical)
    case "volume":
      guard let volume = rows.volumes[value] else { return nil }
      let name = volume.title ?? volume.volume
      let label = try disclosure.scrub("VOLUME: \(name)", .heading)
      return WriterPackRender.refSection(ref, label: label, content: try disclosure.scrub("**\(name)**\nGoal: \(volume.objective ?? "")", .plan), tier: .approvedIntent)
    case "bible_doc":
      guard let page = rows.pages[JSString(parts.value.jsIncludes("/") ? parts.value : "\(parts.value)/")], !page.body.isEmpty, !isWriterExcludedBibleDoc(page.address)
      else { return nil }
      let body = truncateAtParagraph(page.body, maxTokens: WriterPackRender.biblePageBudget)
      let label = try disclosure.scrub("BIBLE: \(page.address.section)/\(page.address.slug)", .heading)
      return WriterPackRender.refSection(ref, label: label, content: try disclosure.scrub(body.text, .biblePage), tier: .canonical, truncated: body.truncated)
    case "fact":
      guard let fact = rows.facts[value] else { return nil }
      if rows.hiddenFactKeys.contains(value) {
        return WriterPackRender.refSection(ref, label: "WRITING CONSTRAINT", content: try disclosure.scrub(fact.writerNote?.jsTrim() ?? "", .knowledge), tier: .approvedIntent)
      }
      let label = try disclosure.scrub("CANON FACT: \(fact.factKey)", .heading)
      return WriterPackRender.refSection(ref, label: label, content: try disclosure.scrub("**\(fact.factKey)**: \(fact.text)", .knowledge), tier: .canonical)
    default:
      return nil
    }
  }
}
