import Foundation
import ShadowCore
import ShadowStore

public enum BiblePageSection: String, CaseIterable, Sendable {
  case project
  case world
  case power
  case plot
  case storyState = "story_state"
  case ai
  case lore
}

public enum StoredPageSection: Hashable, Sendable {
  case known(BiblePageSection)
  case unknown(String)

  public init(rawValue: String) {
    guard let known = BiblePageSection.allCases.first(where: { $0.rawValue.utf8.elementsEqual(rawValue.utf8) }) else {
      self = .unknown(rawValue)
      return
    }
    self = .known(known)
  }

  public var rawValue: String {
    switch self {
    case .known(let section): section.rawValue
    case .unknown(let text): text
    }
  }
}

public enum NovelForgeKeyError: ShadowError, Equatable {
  case chapterOutOfRange(Int)
  case opIndexOutOfRange(Int)
  case notNaturallyKeyed(String)
  case missingKey(EntityRef)
  case malformedKey(String)
  case keyMismatch(EntityRef)

  public var code: String {
    switch self {
    case .chapterOutOfRange: "novel_forge_key.chapter_out_of_range"
    case .opIndexOutOfRange: "novel_forge_key.op_index_out_of_range"
    case .notNaturallyKeyed: "novel_forge_key.not_naturally_keyed"
    case .missingKey: "novel_forge_key.missing_key"
    case .malformedKey: "novel_forge_key.malformed_key"
    case .keyMismatch: "novel_forge_key.key_mismatch"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .chapterOutOfRange(let chapter): "Chapter \(chapter) is not a chapter number; chapters start at 1."
    case .opIndexOutOfRange(let index): "\(index) is not an operation index; indexes start at 0."
    case .notNaturallyKeyed(let kind): "Kind \(kind) has random keys, not natural ones."
    case .missingKey(let ref): "\(ref.kind)/\(ref.key) holds no natural key."
    case .malformedKey(let reason): "The stored natural key is malformed: \(reason)."
    case .keyMismatch(let ref): "The stored natural key does not hash to \(ref.kind)/\(ref.key)."
    }
  }
}

public struct NovelForgeKey: Hashable, Sendable {
  public enum Components: Hashable, Sendable {
    case volume(String)
    case milestone(String)
    case thread(String)
    case mystery(String)
    case secret(String)
    case entity(String)
    case characterKnowledge(fact: String, entity: String)
    case page(section: StoredPageSection, slug: String)
    case chapterPlan(chapter: Int)
    case draft(chapter: Int)
    case finalChapter(chapter: Int)
    case authorNotes
    case proposalChange(proposal: UUID, index: Int)
    case reviewRemedy(review: UUID, finding: String)
    case finalizeDecision(chapter: Int, draftRevision: String, item: String)
  }

  public let novel: UUID
  public let components: Components

  public init(novel: UUID, _ components: Components) throws(NovelForgeKeyError) {
    for chapter in components.chapters where chapter < 1 { throw .chapterOutOfRange(chapter) }
    if case .proposalChange(_, let index) = components, index < 0 { throw .opIndexOutOfRange(index) }
    self.novel = novel
    self.components = components.normalised
  }

  public init(reading state: EntityState, of ref: EntityRef) throws(NovelForgeKeyError) {
    let field: FieldState?
    switch state {
    case .record(let record): field = record[field: CommonField.naturalKey.rawValue]
    case .revisioned(let revisioned): field = revisioned[field: CommonField.naturalKey.rawValue]
    case .appended, .purged: field = nil
    }
    guard let field else { throw .missingKey(ref) }
    try self.init(stored: field.value, of: ref)
  }

  public init(stored: JSONValue, of ref: EntityRef) throws(NovelForgeKeyError) {
    guard let kind = NovelForgeKind(ref.kind), let names = Self.members(of: kind) else { throw .notNaturallyKeyed(ref.kind.rawValue) }
    let reader = try StoredKeyReader(stored, members: names)
    let components: Components
    switch kind {
    case .volume: components = .volume(try reader.text("volume"))
    case .milestone: components = .milestone(try reader.text("milestone"))
    case .thread: components = .thread(try reader.text("thread"))
    case .mystery: components = .mystery(try reader.text("mystery"))
    case .secret: components = .secret(try reader.text("secret"))
    case .entity: components = .entity(try reader.text("entity"))
    case .characterKnowledge: components = .characterKnowledge(fact: try reader.text("fact"), entity: try reader.text("entity"))
    case .page: components = .page(section: StoredPageSection(rawValue: try reader.text("section")), slug: try reader.text("slug"))
    case .chapterPlan: components = .chapterPlan(chapter: try reader.integer("chapter"))
    case .draft: components = .draft(chapter: try reader.integer("chapter"))
    case .finalChapter: components = .finalChapter(chapter: try reader.integer("chapter"))
    case .authorNotes: components = .authorNotes
    case .proposalChange: components = .proposalChange(proposal: try reader.uuid("proposal"), index: try reader.integer("index"))
    case .reviewRemedy: components = .reviewRemedy(review: try reader.uuid("review"), finding: try reader.text("finding"))
    case .finalizeDecision:
      components = .finalizeDecision(chapter: try reader.integer("chapter"), draftRevision: try reader.text("draft_revision"), item: try reader.text("item"))
    case .novel, .approval, .notebookEntry, .notebookWithdrawal, .chatSession, .chatMessage, .chatSummary, .proposal, .chapterReview, .finalizeReview, .refreshReport:
      throw .notNaturallyKeyed(kind.rawValue)
    }
    try self.init(novel: try reader.uuid("novel"), components)
    guard self.ref == ref else { throw .keyMismatch(ref) }
  }

  public var kind: NovelForgeKind { components.kind }

  public var ref: EntityRef {
    EntityRef(kind: kind.entityKind, key: EntityKey.natural(scope: novel.uuidString.lowercased(), kind: kind.entityKind, components: components.hashed))
  }

  public var stored: JSONValue {
    .object(components.members.merging(["novel": .string(novel.uuidString.lowercased())]) { _, _ in preconditionFailure("novel is a reserved member") })
  }

  public static func novel(_ id: UUID) -> EntityRef { randomRef(.novel, id) }
  public static func approval(_ id: UUID) -> EntityRef { randomRef(.approval, id) }
  public static func notebookEntry(_ id: UUID) -> EntityRef { randomRef(.notebookEntry, id) }
  public static func notebookWithdrawal(_ id: UUID) -> EntityRef { randomRef(.notebookWithdrawal, id) }
  public static func chatSession(_ id: UUID) -> EntityRef { randomRef(.chatSession, id) }
  public static func chatMessage(_ id: UUID) -> EntityRef { randomRef(.chatMessage, id) }
  public static func chatSummary(_ id: UUID) -> EntityRef { randomRef(.chatSummary, id) }
  public static func proposal(_ id: UUID) -> EntityRef { randomRef(.proposal, id) }
  public static func chapterReview(_ id: UUID) -> EntityRef { randomRef(.chapterReview, id) }
  public static func finalizeReview(_ id: UUID) -> EntityRef { randomRef(.finalizeReview, id) }
  public static func refreshReport(_ id: UUID) -> EntityRef { randomRef(.refreshReport, id) }

  public static func volume(novel: UUID, key: String) -> EntityRef { volumeKey(novel: novel, volume: key).ref }
  public static func milestone(novel: UUID, key: String) -> EntityRef { milestoneKey(novel: novel, milestone: key).ref }
  public static func thread(novel: UUID, key: String) -> EntityRef { threadKey(novel: novel, thread: key).ref }
  public static func mystery(novel: UUID, key: String) -> EntityRef { mysteryKey(novel: novel, mystery: key).ref }
  public static func secret(novel: UUID, key: String) -> EntityRef { secretKey(novel: novel, secret: key).ref }
  public static func entity(novel: UUID, key: String) -> EntityRef { entityKey(novel: novel, entity: key).ref }
  public static func characterKnowledge(novel: UUID, fact: String, entity: String) -> EntityRef { characterKnowledgeKey(novel: novel, fact: fact, entity: entity).ref }
  public static func page(novel: UUID, section: BiblePageSection, slug: String) -> EntityRef { pageKey(novel: novel, section: section, slug: slug).ref }
  public static func authorNotes(novel: UUID) -> EntityRef { authorNotesKey(novel: novel).ref }
  public static func reviewRemedy(novel: UUID, review: UUID, finding: String) -> EntityRef { reviewRemedyKey(novel: novel, review: review, finding: finding).ref }

  public static func chapterPlan(novel: UUID, chapter: Int) throws(NovelForgeKeyError) -> EntityRef { try chapterPlanKey(novel: novel, chapter: chapter).ref }
  public static func draft(novel: UUID, chapter: Int) throws(NovelForgeKeyError) -> EntityRef { try draftKey(novel: novel, chapter: chapter).ref }
  public static func finalChapter(novel: UUID, chapter: Int) throws(NovelForgeKeyError) -> EntityRef { try finalChapterKey(novel: novel, chapter: chapter).ref }
  public static func proposalChange(novel: UUID, proposal: UUID, index: Int) throws(NovelForgeKeyError) -> EntityRef {
    try proposalChangeKey(novel: novel, proposal: proposal, index: index).ref
  }
  public static func finalizeDecision(novel: UUID, chapter: Int, draftRevision: String, item: String) throws(NovelForgeKeyError) -> EntityRef {
    try finalizeDecisionKey(novel: novel, chapter: chapter, draftRevision: draftRevision, item: item).ref
  }

  private static func randomRef(_ kind: NovelForgeKind, _ id: UUID) -> EntityRef {
    EntityRef(kind: kind.entityKind, key: EntityKey(uuid: id))
  }

  private init(unchecked novel: UUID, _ components: Components) {
    self.novel = novel
    self.components = components.normalised
  }

  private static func members(of kind: NovelForgeKind) -> [String]? {
    switch kind {
    case .volume: ["volume"]
    case .milestone: ["milestone"]
    case .thread: ["thread"]
    case .mystery: ["mystery"]
    case .secret: ["secret"]
    case .entity: ["entity"]
    case .characterKnowledge: ["fact", "entity"]
    case .page: ["section", "slug"]
    case .chapterPlan, .draft, .finalChapter: ["chapter"]
    case .authorNotes: []
    case .proposalChange: ["proposal", "index"]
    case .reviewRemedy: ["review", "finding"]
    case .finalizeDecision: ["chapter", "draft_revision", "item"]
    case .novel, .approval, .notebookEntry, .notebookWithdrawal, .chatSession, .chatMessage, .chatSummary, .proposal, .chapterReview, .finalizeReview, .refreshReport: nil
    }
  }
}

extension NovelForgeKey {
  public static func volumeKey(novel: UUID, volume: String) -> NovelForgeKey { NovelForgeKey(unchecked: novel, .volume(volume)) }
  public static func milestoneKey(novel: UUID, milestone: String) -> NovelForgeKey { NovelForgeKey(unchecked: novel, .milestone(milestone)) }
  public static func threadKey(novel: UUID, thread: String) -> NovelForgeKey { NovelForgeKey(unchecked: novel, .thread(thread)) }
  public static func mysteryKey(novel: UUID, mystery: String) -> NovelForgeKey { NovelForgeKey(unchecked: novel, .mystery(mystery)) }
  public static func secretKey(novel: UUID, secret: String) -> NovelForgeKey { NovelForgeKey(unchecked: novel, .secret(secret)) }
  public static func entityKey(novel: UUID, entity: String) -> NovelForgeKey { NovelForgeKey(unchecked: novel, .entity(entity)) }
  public static func characterKnowledgeKey(novel: UUID, fact: String, entity: String) -> NovelForgeKey {
    NovelForgeKey(unchecked: novel, .characterKnowledge(fact: fact, entity: entity))
  }
  public static func pageKey(novel: UUID, section: BiblePageSection, slug: String) -> NovelForgeKey { NovelForgeKey(unchecked: novel, .page(section: .known(section), slug: slug)) }
  public static func authorNotesKey(novel: UUID) -> NovelForgeKey { NovelForgeKey(unchecked: novel, .authorNotes) }
  public static func chapterPlanKey(novel: UUID, chapter: Int) throws(NovelForgeKeyError) -> NovelForgeKey { try NovelForgeKey(novel: novel, .chapterPlan(chapter: chapter)) }
  public static func draftKey(novel: UUID, chapter: Int) throws(NovelForgeKeyError) -> NovelForgeKey { try NovelForgeKey(novel: novel, .draft(chapter: chapter)) }
  public static func finalChapterKey(novel: UUID, chapter: Int) throws(NovelForgeKeyError) -> NovelForgeKey { try NovelForgeKey(novel: novel, .finalChapter(chapter: chapter)) }
  public static func proposalChangeKey(novel: UUID, proposal: UUID, index: Int) throws(NovelForgeKeyError) -> NovelForgeKey {
    try NovelForgeKey(novel: novel, .proposalChange(proposal: proposal, index: index))
  }
  public static func reviewRemedyKey(novel: UUID, review: UUID, finding: String) -> NovelForgeKey {
    NovelForgeKey(unchecked: novel, .reviewRemedy(review: review, finding: finding))
  }
  public static func finalizeDecisionKey(novel: UUID, chapter: Int, draftRevision: String, item: String) throws(NovelForgeKeyError) -> NovelForgeKey {
    try NovelForgeKey(novel: novel, .finalizeDecision(chapter: chapter, draftRevision: draftRevision, item: item))
  }
}

extension NovelForgeKey.Components {
  var kind: NovelForgeKind {
    switch self {
    case .volume: .volume
    case .milestone: .milestone
    case .thread: .thread
    case .mystery: .mystery
    case .secret: .secret
    case .entity: .entity
    case .characterKnowledge: .characterKnowledge
    case .page: .page
    case .chapterPlan: .chapterPlan
    case .draft: .draft
    case .finalChapter: .finalChapter
    case .authorNotes: .authorNotes
    case .proposalChange: .proposalChange
    case .reviewRemedy: .reviewRemedy
    case .finalizeDecision: .finalizeDecision
    }
  }

  var chapters: [Int] {
    switch self {
    case .chapterPlan(let chapter), .draft(let chapter), .finalChapter(let chapter), .finalizeDecision(let chapter, _, _): [chapter]
    default: []
    }
  }

  var normalised: Self {
    let nfc = { (text: String) in text.precomposedStringWithCanonicalMapping }
    switch self {
    case .volume(let key): return .volume(nfc(key))
    case .milestone(let key): return .milestone(nfc(key))
    case .thread(let key): return .thread(nfc(key))
    case .mystery(let key): return .mystery(nfc(key))
    case .secret(let key): return .secret(nfc(key))
    case .entity(let key): return .entity(nfc(key))
    case .characterKnowledge(let fact, let entity): return .characterKnowledge(fact: nfc(fact), entity: nfc(entity))
    case .page(let section, let slug): return .page(section: StoredPageSection(rawValue: section.rawValue), slug: nfc(slug))
    case .reviewRemedy(let review, let finding): return .reviewRemedy(review: review, finding: nfc(finding))
    case .finalizeDecision(let chapter, let draftRevision, let item): return .finalizeDecision(chapter: chapter, draftRevision: nfc(draftRevision), item: nfc(item))
    case .chapterPlan, .draft, .finalChapter, .authorNotes, .proposalChange: return self
    }
  }

  var hashed: [String] {
    switch self {
    case .volume(let key), .milestone(let key), .thread(let key), .mystery(let key), .secret(let key), .entity(let key): [key]
    case .characterKnowledge(let fact, let entity): [fact, entity]
    case .page(let section, let slug): [section.rawValue, slug]
    case .chapterPlan(let chapter), .draft(let chapter), .finalChapter(let chapter): [String(chapter)]
    case .authorNotes: []
    case .proposalChange(let proposal, let index): [proposal.uuidString.lowercased(), String(index)]
    case .reviewRemedy(let review, let finding): [review.uuidString.lowercased(), finding]
    case .finalizeDecision(let chapter, let draftRevision, let item): [String(chapter), draftRevision, item]
    }
  }

  var members: [String: JSONValue] {
    switch self {
    case .volume(let key): ["volume": .string(key)]
    case .milestone(let key): ["milestone": .string(key)]
    case .thread(let key): ["thread": .string(key)]
    case .mystery(let key): ["mystery": .string(key)]
    case .secret(let key): ["secret": .string(key)]
    case .entity(let key): ["entity": .string(key)]
    case .characterKnowledge(let fact, let entity): ["fact": .string(fact), "entity": .string(entity)]
    case .page(let section, let slug): ["section": .string(section.rawValue), "slug": .string(slug)]
    case .chapterPlan(let chapter), .draft(let chapter), .finalChapter(let chapter): ["chapter": .int(Int64(chapter))]
    case .authorNotes: [:]
    case .proposalChange(let proposal, let index): ["proposal": .string(proposal.uuidString.lowercased()), "index": .int(Int64(index))]
    case .reviewRemedy(let review, let finding): ["review": .string(review.uuidString.lowercased()), "finding": .string(finding)]
    case .finalizeDecision(let chapter, let draftRevision, let item): ["chapter": .int(Int64(chapter)), "draft_revision": .string(draftRevision), "item": .string(item)]
    }
  }
}

private struct StoredKeyReader {
  let members: [String: JSONValue]

  init(_ value: JSONValue, members names: [String]) throws(NovelForgeKeyError) {
    guard case .object(let members) = value else { throw .malformedKey("it is not an object") }
    let expected = names + ["novel"]
    guard members.count == expected.count, members.keys.allSatisfy({ key in expected.contains { $0.utf8.elementsEqual(key.utf8) } }) else {
      throw .malformedKey("it does not have exactly the members \(expected.sorted().joined(separator: ", "))")
    }
    self.members = members
  }

  func uuid(_ name: String) throws(NovelForgeKeyError) -> UUID {
    let text = try self.text(name)
    guard let id = UUID(uuidString: text), id.uuidString.lowercased().utf8.elementsEqual(text.utf8) else { throw .malformedKey("\(name) is not a lower-case UUID") }
    return id
  }

  func text(_ name: String) throws(NovelForgeKeyError) -> String {
    guard let text = members[name]?.stringValue else { throw .malformedKey("\(name) is not a string") }
    return text
  }

  func integer(_ name: String) throws(NovelForgeKeyError) -> Int {
    guard let number = members[name]?.intValue, let chapter = Int(exactly: number) else { throw .malformedKey("\(name) is not an integer") }
    return chapter
  }
}
