import ShadowText

public enum BibleStage: String, CaseIterable, Codable, Sendable {
  case foundation
  case world
  case power
  case factionsAndLocations
  case characters
  case plot
  case volumes
}

struct BibleChapterRole: Equatable, Sendable {
  var label: String
  var sections: [BiblePageSection]
  var keywords: [String]
}

struct BibleChapterSpec: Equatable, Sendable {
  var stage: BibleStage
  var section: BiblePageSection
  var slug: String
  var purpose: String
  var materializes: [EntityType]
  var topics: [String]
  var role: BibleChapterRole
}

struct LegacyChapterSlug: Equatable, Sendable {
  var section: BiblePageSection
  var slug: String
  var stage: BibleStage
}

// apps/novel-forge-server/src/modules/bible/bible-manifest.ts:27
let bibleStageOrder: [BibleStage] = [.foundation, .world, .power, .factionsAndLocations, .characters, .plot, .volumes]

private let foundationChapter = BibleChapterSpec(
  stage: .foundation,
  section: .project,
  slug: "premise",
  purpose: "the full premise: hook, stakes, protagonist drive, the reader promise, and the tone the serial is allowed to swing between",
  materializes: [],
  topics: ["hook", "stakes", "protagonist drive", "reader promise", "pacing and tone"],
  role: BibleChapterRole(label: "Premise", sections: [.project], keywords: ["premise", "pitch", "logline", "hook", "synopsis", "concept", "summary"])
)

private let worldChapter = BibleChapterSpec(
  stage: .world,
  section: .world,
  slug: "setting-overview",
  purpose: "where and when the story lives, the rules of normal life, and the geopolitical shape that makes the plot possible",
  materializes: [.location, .concept],
  topics: ["era and place", "rules of normal life", "geopolitical shape"],
  role: BibleChapterRole(
    label: "World and setting",
    sections: [.world, .lore],
    keywords: ["setting", "world", "overview", "era", "history", "society", "culture", "cosmology", "background", "geography"]
  )
)

private let powerChapter = BibleChapterSpec(
  stage: .power,
  section: .power,
  slug: "system-and-limits",
  purpose: "the visible progression ladder readers anticipate, plus what power costs, what it cannot do, and what breaking its rules means",
  materializes: [.powerRule, .concept],
  topics: ["progression ladder", "costs and limits", "consequences of breaking the rules"],
  role: BibleChapterRole(
    label: "Power system",
    sections: [.power],
    keywords: ["system", "limit", "rule", "law", "cost", "ladder", "progression", "rank", "tier", "level", "ability", "class", "skill", "magic", "power", "cultivation"]
  )
)

private let factionsAndLocationsChapter = BibleChapterSpec(
  stage: .factionsAndLocations,
  section: .world,
  slug: "factions-and-locations",
  purpose: "the powers that be, what each wants, why they collide, and the places those collisions happen in",
  materializes: [.faction, .location],
  topics: ["faction goals", "faction conflicts", "locations that matter to the plot"],
  role: BibleChapterRole(
    label: "Factions and locations",
    sections: [.world, .lore],
    keywords: [
      "faction", "location", "place", "region", "nation", "kingdom", "empire", "city", "territory", "organization", "organisation", "guild", "politics", "political", "map",
      "travel",
    ]
  )
)

private let charactersChapter = BibleChapterSpec(
  stage: .characters,
  section: .project,
  slug: "cast",
  purpose: "the cast: who carries the story, what each wants, and the relationships that generate conflict",
  materializes: [.character],
  topics: ["protagonist", "opposition", "supporting cast", "relationships"],
  role: BibleChapterRole(
    label: "Cast",
    sections: [.project, .ai, .lore],
    keywords: ["cast", "character", "protagonist", "antagonist", "roster", "people", "relationship", "dramatis"]
  )
)

private let plotChapter = BibleChapterSpec(
  stage: .plot,
  section: .plot,
  slug: "escalation-map",
  purpose: "the opening conflict and how pressure starts to build from it; later turns and an ending only where the author has given them",
  materializes: [],
  topics: ["opening conflict", "how pressure starts to build", "later turns the author has planned"],
  role: BibleChapterRole(
    label: "Escalation map",
    sections: [.plot, .storyState],
    keywords: ["escalation", "plot", "arc", "outline", "endgame", "spine", "stakes", "beat", "structure", "storyline"]
  )
)

private let volumesChapter = BibleChapterSpec(
  stage: .volumes,
  section: .storyState,
  slug: "volume-plan",
  purpose: "the volumes the author has planned: ordinals, objectives, the conflict each raises and the payoff each owes",
  materializes: [],
  topics: ["volume objectives", "per-volume payoff"],
  role: BibleChapterRole(label: "Volume plan", sections: [.storyState, .plot], keywords: ["volume", "book", "season", "roadmap"])
)

// apps/novel-forge-server/src/modules/bible/bible-manifest.ts:29
let bibleManifest: [BibleChapterSpec] = [
  foundationChapter, worldChapter, powerChapter, factionsAndLocationsChapter, charactersChapter, plotChapter, volumesChapter,
]

// apps/novel-forge-server/src/modules/bible/bible-manifest.ts:133
let legacyChapterSlugs: [LegacyChapterSlug] = [
  LegacyChapterSlug(section: .project, slug: "foundation", stage: .foundation),
  LegacyChapterSlug(section: .world, slug: "world-power", stage: .world),
  LegacyChapterSlug(section: .world, slug: "factions-locations", stage: .factionsAndLocations),
  LegacyChapterSlug(section: .ai, slug: "characters", stage: .characters),
  LegacyChapterSlug(section: .plot, slug: "plot", stage: .plot),
  LegacyChapterSlug(section: .storyState, slug: "volumes", stage: .volumes),
]

// apps/novel-forge-server/src/modules/bible/bible-manifest.ts:145
func chapterForStage(_ stage: BibleStage) -> BibleChapterSpec {
  switch stage {
  case .foundation: foundationChapter
  case .world: worldChapter
  case .power: powerChapter
  case .factionsAndLocations: factionsAndLocationsChapter
  case .characters: charactersChapter
  case .plot: plotChapter
  case .volumes: volumesChapter
  }
}

// apps/novel-forge-server/src/modules/bible/bible-manifest.ts:151
func chapterAt(section: String, slug: String) -> BibleChapterSpec? {
  bibleManifest.first { $0.section.rawValue.jsEquals(section) && $0.slug.jsEquals(slug) }
}

// apps/novel-forge-server/src/modules/bible/bible-manifest.ts:155
func entityTypesForSection(_ section: String) -> [EntityType] {
  var seen = Set<EntityType>()
  return bibleManifest.filter { $0.section.rawValue.jsEquals(section) }.flatMap(\.materializes).filter { seen.insert($0).inserted }
}

// apps/novel-forge-server/src/modules/bible/bible-manifest.ts:160
func isEntityBearingSection(_ section: String) -> Bool {
  !entityTypesForSection(section).isEmpty
}

// apps/novel-forge-server/src/modules/bible/bible-manifest.ts:170
func requiredEntityTypesForSlug(section: String, slug: String) -> [EntityType] {
  if let chapter = chapterAt(section: section, slug: slug) { return chapter.materializes }
  let siblings = bibleManifest.filter { $0.section.rawValue.jsEquals(section) }
  if siblings.isEmpty || siblings.contains(where: { $0.materializes.isEmpty }) { return [] }
  return entityTypesForSection(section)
}

// apps/novel-forge-server/src/modules/bible/bible-manifest.ts:179
func renderManifest() -> String {
  bibleManifest.map { chapter in
    let entities =
      chapter.materializes.isEmpty ? "" : " — the canon it establishes is recorded as entities of type: \(chapter.materializes.map(\.rawValue).joined(separator: ", "))"
    return
      "\(chapter.section.rawValue)/\(chapter.slug) — \(chapter.purpose)\(entities)\n  topics to cover where the author's material supports them: \(chapter.topics.joined(separator: "; "))"
  }.joined(separator: "\n")
}
