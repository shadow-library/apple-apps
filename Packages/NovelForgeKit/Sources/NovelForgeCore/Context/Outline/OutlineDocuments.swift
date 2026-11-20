import ShadowCore
import ShadowText

private let sectionPriority = ["project", "plot", "world", "power", "lore", "story_state", "ai"]
private let coreSections: Set<String> = ["plot", "world", "power"]
private let coreProjectSlugs = ["premise", "reader-promise"]

extension OutlineDocument {
  // apps/novel-forge-server/src/modules/ai/context/bible-docs.ts:46
  var hasContent: Bool { !(body ?? "").jsTrim().isEmpty }

  // apps/novel-forge-server/src/modules/ai/context/bible-docs.ts:50
  var ref: String { "bible_doc:\(section)/\(slug)" }

  // apps/novel-forge-server/src/modules/ai/context/bible-docs.ts:54
  var label: String { BibleTitle.derive(slug: slug, frontmatter: frontmatter, body: body) }

  var address: BibleDocAddress { BibleDocAddress(section: section, slug: slug) }

  // apps/novel-forge-server/src/modules/ai/context/bible-docs.ts:99
  private var rank: (Int, Int, Int) {
    let projectSlug = coreProjectSlugs.firstIndex { $0.jsEquals(slug) }
    let core = coreSections.contains(section) || (section.jsEquals("project") && projectSlug != nil)
    let sectionIndex = sectionPriority.firstIndex { $0.jsEquals(section) } ?? -1
    return (core ? 0 : 1, sectionIndex, section.jsEquals("project") ? projectSlug ?? coreProjectSlugs.count : coreProjectSlugs.count)
  }

  /// Premise and reader promise, then plot, world and power, then everything else; slug order within a section.
  // apps/novel-forge-server/src/modules/ai/context/bible-docs.ts:109
  static func ranked(_ documents: [OutlineDocument]) -> [OutlineDocument] {
    documents.jsStableSorted { left, right in
      let (a, b) = (left.rank, right.rank)
      if a.0 != b.0 { return a.0 < b.0 }
      if a.1 != b.1 { return a.1 < b.1 }
      if a.2 != b.2 { return a.2 < b.2 }
      return JSText.localePrecedes(left.slug, right.slug)
    }
  }
}
