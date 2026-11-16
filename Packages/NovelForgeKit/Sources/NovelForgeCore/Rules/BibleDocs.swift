// apps/novel-forge-server/src/modules/ai/context/bible-docs.ts:4
struct BibleDocAddress: Sendable, Hashable {
  let section: String
  let slug: String

  // apps/novel-forge-server/src/modules/ai/context/bible-docs.ts:62
  static let organisedTimeline = BibleDocAddress(section: "project", slug: "timeline")

  // apps/novel-forge-server/src/modules/ai/context/bible-docs.ts:63
  static let openQuestions = BibleDocAddress(section: "project", slug: "open-questions")

  static func == (left: BibleDocAddress, right: BibleDocAddress) -> Bool {
    left.section.jsEquals(right.section) && left.slug.jsEquals(right.slug)
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(JSString(section))
    hasher.combine(JSString(slug))
  }
}

struct BibleDocAccess: Sendable, Equatable {
  let writerExcluded: Bool
  let plannerOnly: Bool
}

// apps/novel-forge-server/src/modules/ai/context/bible-docs.ts:71
private let plannerOnlyDocs = [BibleDocAddress.organisedTimeline, .openQuestions]

// apps/novel-forge-server/src/modules/ai/context/bible-docs.ts:77
private let writerExcludedDocs = [
  BibleDocAddress(section: "story_state", slug: "volume-plan"), BibleDocAddress(section: "story_state", slug: "volumes"), BibleDocAddress(section: "plot", slug: "escalation-map"),
]

// apps/novel-forge-server/src/modules/ai/context/bible-docs.ts:87
func isPlannerOnlyBibleDoc(_ doc: BibleDocAddress) -> Bool {
  plannerOnlyDocs.contains(doc)
}

// apps/novel-forge-server/src/modules/ai/context/bible-docs.ts:91
func isWriterExcludedBibleDoc(_ doc: BibleDocAddress) -> Bool {
  isPlannerOnlyBibleDoc(doc) || writerExcludedDocs.contains(doc)
}

// apps/novel-forge-server/src/modules/ai/context/bible-docs.ts:96
func bibleDocAccess(_ doc: BibleDocAddress) -> BibleDocAccess {
  BibleDocAccess(writerExcluded: isWriterExcludedBibleDoc(doc), plannerOnly: isPlannerOnlyBibleDoc(doc))
}
