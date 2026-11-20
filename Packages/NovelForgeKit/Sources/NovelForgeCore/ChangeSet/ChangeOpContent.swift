import ShadowText

// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:13
struct PremiseUpdate: Sendable, Equatable {
  var premise: String?
  var brief: String?
  var themes: [String]?
  var instructions: String?
  var theme: String?
  var readerPromise: String?
  var protagonistKey: String?
  var opposition: String?
  var endingQuestion: String?
  var ending: String?

  init?(_ fields: OpFields) {
    premise = fields.string("premise")
    brief = fields.string("brief")
    themes = fields.strings("themes")
    instructions = fields.string("instructions")
    theme = fields.string("theme")
    readerPromise = fields.string("readerPromise")
    protagonistKey = fields.string("protagonistKey")
    opposition = fields.string("opposition")
    endingQuestion = fields.string("endingQuestion")
    ending = fields.string("ending")
  }

  func encode(into encoder: inout OpEncoder) {
    encoder.string("premise", premise)
    encoder.string("brief", brief)
    encoder.strings("themes", themes)
    encoder.string("instructions", instructions)
    encoder.string("theme", theme)
    encoder.string("readerPromise", readerPromise)
    encoder.string("protagonistKey", protagonistKey)
    encoder.string("opposition", opposition)
    encoder.string("endingQuestion", endingQuestion)
    encoder.string("ending", ending)
  }
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:27
struct BibleDocumentUpsert: Sendable, Equatable {
  var section: BiblePageSection
  var slug: String
  var frontmatter: OrderedJSONObject?
  var body: String?

  init?(_ fields: OpFields) {
    guard let section: BiblePageSection = fields.member("section"), let slug = fields.string("slug") else { return nil }
    self.section = section
    self.slug = slug
    frontmatter = fields.object("frontmatter")
    body = fields.string("body")
  }

  func encode(into encoder: inout OpEncoder) {
    encoder.string("section", section.rawValue)
    encoder.string("slug", slug)
    encoder.put("frontmatter", frontmatter.map(OrderedJSON.object))
    encoder.string("body", body)
  }
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:35
struct BibleDocumentRemove: Sendable, Equatable {
  var section: BiblePageSection
  var slug: String

  init?(_ fields: OpFields) {
    guard let section: BiblePageSection = fields.member("section"), let slug = fields.string("slug") else { return nil }
    self.section = section
    self.slug = slug
  }

  func encode(into encoder: inout OpEncoder) {
    encoder.string("section", section.rawValue)
    encoder.string("slug", slug)
  }
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:42
struct VolumeUpsert: Sendable, Equatable {
  var volumeKey: String
  var ordinal: Int?
  var title: String?
  var objective: String?
  var body: String?
  var state: String?

  init?(_ fields: OpFields) {
    guard let volumeKey = fields.string("volumeKey") else { return nil }
    self.volumeKey = volumeKey
    ordinal = fields.int("ordinal")
    title = fields.string("title")
    objective = fields.string("objective")
    body = fields.string("body")
    state = fields.string("state")
  }

  func encode(into encoder: inout OpEncoder) {
    encoder.string("volumeKey", volumeKey)
    encoder.int("ordinal", ordinal)
    encoder.string("title", title)
    encoder.string("objective", objective)
    encoder.string("body", body)
    encoder.string("state", state)
  }
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:51
struct VolumeRemove: Sendable, Equatable {
  var volumeKey: String

  init?(_ fields: OpFields) {
    guard let volumeKey = fields.string("volumeKey") else { return nil }
    self.volumeKey = volumeKey
  }

  func encode(into encoder: inout OpEncoder) {
    encoder.string("volumeKey", volumeKey)
  }
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:66
struct BriefUpdate: Sendable, Equatable {
  var chapter: Int
  var title: String?
  var body: String?
  var writeMode: BriefWriteMode?
  var volumeKey: String?
  var contextRefs: [String]?
  var pov: OpValue<String>
  var chapterPurpose: String?
  var readerValue: [String]?
  var repetitionRisks: OpValue<[String]>
  var densityRisk: OpValue<String>
  var endingContract: EndingContract?
  var knowledgeContract: OpValue<ChangeKnowledgeContract>
  var direction: OpValue<String>
  var contentMode: OpValue<ContentMode>
  var scenes: OpValue<[BriefScene]>
  var claimedMilestones: OpValue<[String]>
  var isEnding: Bool?

  init?(_ fields: OpFields) {
    guard let chapter = fields.int("chapter") else { return nil }
    self.chapter = chapter
    title = fields.string("title")
    body = fields.string("body")
    writeMode = fields.member("writeMode")
    volumeKey = fields.string("volumeKey")
    contextRefs = fields.strings("contextRefs")
    pov = fields.patchString("pov")
    chapterPurpose = fields.string("chapterPurpose")
    readerValue = fields.strings("readerValue")
    repetitionRisks = fields.patchStrings("repetitionRisks")
    densityRisk = fields.patchString("densityRisk")
    endingContract = fields.object("endingContract").flatMap(EndingContract.init)
    knowledgeContract = fields.patch("knowledgeContract") { $0.objectValue.flatMap(ChangeKnowledgeContract.init) }
    direction = fields.patchString("direction")
    contentMode = fields.patch("contentMode") { ContentMode(exactly: $0) }
    scenes = fields.patch("scenes") { $0.arrayValue.map { $0.compactMap(Self.scene) } }
    claimedMilestones = fields.patchStrings("claimedMilestones")
    isEnding = fields.bool("isEnding")
  }

  private static func scene(_ raw: OrderedJSON) -> BriefScene? {
    guard let record = raw.objectValue, let summary = record["summary"]?.stringValue else { return nil }
    return BriefScene(
      summary: summary,
      pov: record["pov"]?.stringValue,
      goal: record["goal"]?.stringValue,
      obstacle: record["obstacle"]?.stringValue,
      turn: record["turn"]?.stringValue,
      beats: record["beats"]?.arrayValue?.compactMap(\.stringValue),
      estimatedWords: record["estimatedWords"]?.numberValue.map(JSNumber.integer)
    )
  }

  func encode(into encoder: inout OpEncoder) {
    encoder.int("chapter", chapter)
    encoder.string("title", title)
    encoder.string("body", body)
    encoder.string("writeMode", writeMode?.rawValue)
    encoder.string("volumeKey", volumeKey)
    encoder.strings("contextRefs", contextRefs)
    encoder.patchString("pov", pov)
    encoder.string("chapterPurpose", chapterPurpose)
    encoder.strings("readerValue", readerValue)
    encoder.patchStrings("repetitionRisks", repetitionRisks)
    encoder.patchString("densityRisk", densityRisk)
    encoder.put("endingContract", endingContract?.json)
    encoder.patch("knowledgeContract", knowledgeContract, \.json)
    encoder.patchString("direction", direction)
    encoder.patch("contentMode", contentMode) { .string($0.rawValue) }
    encoder.patch("scenes", scenes) { .array($0.map(sceneJSON)) }
    encoder.patchStrings("claimedMilestones", claimedMilestones)
    encoder.bool("isEnding", isEnding)
  }
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:92
struct BriefRemove: Sendable, Equatable {
  var chapter: Int

  init?(_ fields: OpFields) {
    guard let chapter = fields.int("chapter") else { return nil }
    self.chapter = chapter
  }

  func encode(into encoder: inout OpEncoder) {
    encoder.int("chapter", chapter)
  }
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:97
struct DraftUpdate: Sendable, Equatable {
  var chapter: Int
  var title: String?
  var body: String?
  var summary: String?

  init?(_ fields: OpFields) {
    guard let chapter = fields.int("chapter") else { return nil }
    self.chapter = chapter
    title = fields.string("title")
    body = fields.string("body")
    summary = fields.string("summary")
  }

  func encode(into encoder: inout OpEncoder) {
    encoder.int("chapter", chapter)
    encoder.string("title", title)
    encoder.string("body", body)
    encoder.string("summary", summary)
  }
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:105
struct DraftRemove: Sendable, Equatable {
  var chapter: Int

  init?(_ fields: OpFields) {
    guard let chapter = fields.int("chapter") else { return nil }
    self.chapter = chapter
  }

  func encode(into encoder: inout OpEncoder) {
    encoder.int("chapter", chapter)
  }
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:124
struct DraftRewritePassage: Sendable, Equatable {
  var chapter: Int
  var passage: String
  var replacement: String
  var label: String?
  var contextIndex: Int?
  var anchor: PassageRewriteAnchor?

  init?(_ fields: OpFields) {
    guard let chapter = fields.int("chapter"), let passage = fields.string("passage"), let replacement = fields.string("replacement") else { return nil }
    self.chapter = chapter
    self.passage = passage
    self.replacement = replacement
    label = fields.string("label")
    contextIndex = fields.int("contextIndex")
    anchor = fields.object("anchor").flatMap(PassageRewriteAnchor.init)
  }

  func encode(into encoder: inout OpEncoder) {
    encoder.int("chapter", chapter)
    encoder.string("passage", passage)
    encoder.string("replacement", replacement)
    encoder.string("label", label)
    encoder.int("contextIndex", contextIndex)
    encoder.put("anchor", anchor?.json)
  }
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:134
struct EntityUpsert: Sendable, Equatable {
  var entityKey: String
  var type: EntityType
  var name: String?
  var status: String?
  var motivation: String?
  var notes: String?
  var body: String?

  init?(_ fields: OpFields) {
    guard let entityKey = fields.string("entityKey"), let type: EntityType = fields.member("type") else { return nil }
    self.entityKey = entityKey
    self.type = type
    name = fields.string("name")
    status = fields.string("status")
    motivation = fields.string("motivation")
    notes = fields.string("notes")
    body = fields.string("body")
  }

  func encode(into encoder: inout OpEncoder) {
    encoder.string("entityKey", entityKey)
    encoder.string("type", type.rawValue)
    encoder.string("name", name)
    encoder.string("status", status)
    encoder.string("motivation", motivation)
    encoder.string("notes", notes)
    encoder.string("body", body)
  }
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:145
struct EntityRemove: Sendable, Equatable {
  var entityKey: String

  init?(_ fields: OpFields) {
    guard let entityKey = fields.string("entityKey") else { return nil }
    self.entityKey = entityKey
  }

  func encode(into encoder: inout OpEncoder) {
    encoder.string("entityKey", entityKey)
  }
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:155
struct FactUpsert: Sendable, Equatable {
  var factKey: String
  var body: String?
  var subjects: [String]?
  var constraintNote: String?
  var writerNote: String?
  var terms: [String]?
  var revealChapter: OpValue<Int>
  var unlock: OpValue<UnlockCondition>
  var allowedClues: OpValue<[String]>

  init?(_ fields: OpFields) {
    guard let factKey = fields.string("factKey") else { return nil }
    self.factKey = factKey
    body = fields.string("body")
    subjects = fields.strings("subjects")
    constraintNote = fields.string("constraintNote")
    writerNote = fields.string("writerNote")
    terms = fields.strings("terms")
    revealChapter = fields.patchInt("revealChapter")
    unlock = fields.patch("unlock") { UnlockCondition(validating: $0) }
    allowedClues = fields.patchStrings("allowedClues")
  }

  func encode(into encoder: inout OpEncoder) {
    encoder.string("factKey", factKey)
    encoder.string("body", body)
    encoder.strings("subjects", subjects)
    encoder.string("constraintNote", constraintNote)
    encoder.string("writerNote", writerNote)
    encoder.strings("terms", terms)
    encoder.patchInt("revealChapter", revealChapter)
    encoder.patch("unlock", unlock, unlockJSON)
    encoder.patchStrings("allowedClues", allowedClues)
  }
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:168
struct FactRemove: Sendable, Equatable {
  var factKey: String

  init?(_ fields: OpFields) {
    guard let factKey = fields.string("factKey") else { return nil }
    self.factKey = factKey
  }

  func encode(into encoder: inout OpEncoder) {
    encoder.string("factKey", factKey)
  }
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:174
struct MilestoneUpsert: Sendable, Equatable {
  var milestoneKey: String
  var label: String?
  var subjectEntityKey: OpValue<String>
  var kind: MilestoneKind?

  init?(_ fields: OpFields) {
    guard let milestoneKey = fields.string("milestoneKey") else { return nil }
    self.milestoneKey = milestoneKey
    label = fields.string("label")
    subjectEntityKey = fields.patchString("subjectEntityKey")
    kind = fields.member("kind")
  }

  func encode(into encoder: inout OpEncoder) {
    encoder.string("milestoneKey", milestoneKey)
    encoder.string("label", label)
    encoder.patchString("subjectEntityKey", subjectEntityKey)
    encoder.string("kind", kind?.rawValue)
  }
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:182
struct MilestoneRemove: Sendable, Equatable {
  var milestoneKey: String

  init?(_ fields: OpFields) {
    guard let milestoneKey = fields.string("milestoneKey") else { return nil }
    self.milestoneKey = milestoneKey
  }

  func encode(into encoder: inout OpEncoder) {
    encoder.string("milestoneKey", milestoneKey)
  }
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:190
struct PromiseCreate: Sendable, Equatable {
  var kind: PromiseKind
  var key: String
  var label: String
  var openedChapter: Int?

  init?(_ fields: OpFields) {
    guard let kind: PromiseKind = fields.member("kind"), let key = fields.string("key"), let label = fields.string("label") else { return nil }
    self.kind = kind
    self.key = key
    self.label = label
    openedChapter = fields.int("openedChapter")
  }

  func encode(into encoder: inout OpEncoder) {
    encoder.string("kind", kind.rawValue)
    encoder.string("key", key)
    encoder.string("label", label)
    encoder.int("openedChapter", openedChapter)
  }
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:199
struct PromiseUpdate: Sendable, Equatable {
  var kind: PromiseKind
  var key: String
  var label: String?
  var lastAdvancedChapter: Int?
  var status: PromiseOpStatus?

  init?(_ fields: OpFields) {
    guard let kind: PromiseKind = fields.member("kind"), let key = fields.string("key") else { return nil }
    self.kind = kind
    self.key = key
    label = fields.string("label")
    lastAdvancedChapter = fields.int("lastAdvancedChapter")
    status = fields.member("status")
  }

  func encode(into encoder: inout OpEncoder) {
    encoder.string("kind", kind.rawValue)
    encoder.string("key", key)
    encoder.string("label", label)
    encoder.int("lastAdvancedChapter", lastAdvancedChapter)
    encoder.string("status", status?.rawValue)
  }
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:209
struct PromiseSetPayoff: Sendable, Equatable {
  var kind: PromiseKind
  var key: String
  var payoffMilestoneKey: OpValue<String>
  var payoffVolumeKey: OpValue<String>
  var payoffWindow: OpValue<Int>
  var someday: Bool?
  var dormant: Bool?

  init?(_ fields: OpFields) {
    guard let kind: PromiseKind = fields.member("kind"), let key = fields.string("key") else { return nil }
    self.kind = kind
    self.key = key
    payoffMilestoneKey = fields.patchString("payoffMilestoneKey")
    payoffVolumeKey = fields.patchString("payoffVolumeKey")
    payoffWindow = fields.patchInt("payoffWindow")
    someday = fields.bool("someday")
    dormant = fields.bool("dormant")
  }

  func encode(into encoder: inout OpEncoder) {
    encoder.string("kind", kind.rawValue)
    encoder.string("key", key)
    encoder.patchString("payoffMilestoneKey", payoffMilestoneKey)
    encoder.patchString("payoffVolumeKey", payoffVolumeKey)
    encoder.patchInt("payoffWindow", payoffWindow)
    encoder.bool("someday", someday)
    encoder.bool("dormant", dormant)
  }
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:222
struct PromiseDrop: Sendable, Equatable {
  var kind: PromiseKind
  var key: String

  init?(_ fields: OpFields) {
    guard let kind: PromiseKind = fields.member("kind"), let key = fields.string("key") else { return nil }
    self.kind = kind
    self.key = key
  }

  func encode(into encoder: inout OpEncoder) {
    encoder.string("kind", kind.rawValue)
    encoder.string("key", key)
  }
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set.types.ts:229
struct OrganiseRule: Sendable, Equatable {
  var rule: String
  var optionId: String

  init?(_ fields: OpFields) {
    guard let rule = fields.string("rule"), let optionId = fields.string("optionId") else { return nil }
    self.rule = rule
    self.optionId = optionId
  }

  func encode(into encoder: inout OpEncoder) {
    encoder.string("rule", rule)
    encoder.string("optionId", optionId)
  }
}
