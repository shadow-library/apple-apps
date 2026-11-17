// apps/novel-forge-server/src/modules/ai/context/novel-chat-context.ts
extension ChatPack {
  // novel-chat-context.ts:378
  private static let plannerOnlyPageNote =
    "(planner-only: says what happens later in the book — look it up to read it; a change drawn from it to anything the chapter writer or readers can see waits for the author’s review)"

  // novel-chat-context.ts:370
  private static func inventoryPart(_ header: String, _ lines: [String], maxTokens: Int, leftOut: String) -> String? {
    lines.isEmpty ? nil : "\(header)\n\(fitLines(lines, maxTokens: maxTokens, leftOut: leftOut))"
  }

  // novel-chat-context.ts:381
  static func renderInventory(
    entities: [ChatPackEntity], pages: [ChatPackPage], facts: [ChatPackFact], milestones: [ChatPackMilestone]
  ) -> String {
    let entityLines = entities.jsStableSorted { left, right in
      if left.isMajor != right.isMajor { return left.isMajor }
      return JSText.codeUnitPrecedes(left.entityKey, right.entityKey)
    }
    .map { "\($0.entityKey) — \($0.name) (\($0.type)\($0.isMajor ? ", major" : ""))" }
    let pageLines = pages.map { page -> String in
      let ref = "bible_doc:\(page.section)/\(page.slug)"
      if isPlannerOnlyBibleDoc(BibleDocAddress(section: page.section, slug: page.slug)) { return "\(ref) \(plannerOnlyPageNote)" }
      return "\(ref) — \(BibleTitle.derive(slug: page.slug, frontmatter: page.frontmatter, body: nil))"
    }
    let factLines = facts.jsStableSorted { JSText.codeUnitPrecedes($0.factKey, $1.factKey) }
      .map { "\($0.factKey)\($0.disclosedInChapter.map { " (reader knows since ch \($0))" } ?? " (secret)")" }
    let milestoneLines = milestones.map { "\($0.milestoneKey) — \($0.label) (\($0.state.rawValue))" }
    return [
      inventoryPart("Characters, places and other entities (get_entity):", entityLines, maxTokens: InventoryCap.entities, leftOut: "entities — search_lore finds them"),
      inventoryPart("Story Bible pages (get_bible_document):", pageLines, maxTokens: InventoryCap.pages, leftOut: "pages — search_lore finds them"),
      inventoryPart("Canon facts and secrets by key (get_canon_facts):", factLines, maxTokens: InventoryCap.facts, leftOut: "facts — search_lore finds them"),
      inventoryPart("Milestones:", milestoneLines, maxTokens: InventoryCap.milestones, leftOut: "milestones — search_lore finds them"),
    ]
    .compactMap { $0 }
    .joined(separator: "\n\n")
  }
}
