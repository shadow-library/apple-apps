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
  case notNaturallyKeyed(String)
  case missingKey(EntityRef)
  case malformedKey(String)
  case keyMismatch(EntityRef)

  public var code: String {
    switch self {
    case .chapterOutOfRange: "novel_forge_key.chapter_out_of_range"
    case .notNaturallyKeyed: "novel_forge_key.not_naturally_keyed"
    case .missingKey: "novel_forge_key.missing_key"
    case .malformedKey: "novel_forge_key.malformed_key"
    case .keyMismatch: "novel_forge_key.key_mismatch"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .chapterOutOfRange(let chapter): "Chapter \(chapter) is not a chapter number; chapters start at 1."
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
  }

  public let novel: UUID
  public let components: Components

  public init(novel: UUID, _ components: Components) throws(NovelForgeKeyError) {
    for chapter in components.chapters where chapter < 1 { throw .chapterOutOfRange(chapter) }
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
    case .chapterPlan: components = .chapterPlan(chapter: try reader.chapter("chapter"))
    case .draft: components = .draft(chapter: try reader.chapter("chapter"))
    case .finalChapter: components = .finalChapter(chapter: try reader.chapter("chapter"))
    case .authorNotes: components = .authorNotes
    case .novel, .approval, .notebookEntry, .notebookWithdrawal: throw .notNaturallyKeyed(kind.rawValue)
    }
    try self.init(novel: try reader.novel(), components)
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

  public static func volume(novel: UUID, key: String) -> EntityRef { volumeKey(novel: novel, volume: key).ref }
  public static func milestone(novel: UUID, key: String) -> EntityRef { milestoneKey(novel: novel, milestone: key).ref }
  public static func thread(novel: UUID, key: String) -> EntityRef { threadKey(novel: novel, thread: key).ref }
  public static func mystery(novel: UUID, key: String) -> EntityRef { mysteryKey(novel: novel, mystery: key).ref }
  public static func secret(novel: UUID, key: String) -> EntityRef { textRef(novel, .secret(key)) }
  public static func entity(novel: UUID, key: String) -> EntityRef { textRef(novel, .entity(key)) }
  public static func characterKnowledge(novel: UUID, fact: String, entity: String) -> EntityRef { textRef(novel, .characterKnowledge(fact: fact, entity: entity)) }
  public static func page(novel: UUID, section: BiblePageSection, slug: String) -> EntityRef { textRef(novel, .page(section: .known(section), slug: slug)) }
  public static func authorNotes(novel: UUID) -> EntityRef { textRef(novel, .authorNotes) }

  public static func chapterPlan(novel: UUID, chapter: Int) throws(NovelForgeKeyError) -> EntityRef { try NovelForgeKey(novel: novel, .chapterPlan(chapter: chapter)).ref }
  public static func draft(novel: UUID, chapter: Int) throws(NovelForgeKeyError) -> EntityRef { try NovelForgeKey(novel: novel, .draft(chapter: chapter)).ref }
  public static func finalChapter(novel: UUID, chapter: Int) throws(NovelForgeKeyError) -> EntityRef { try NovelForgeKey(novel: novel, .finalChapter(chapter: chapter)).ref }

  private static func randomRef(_ kind: NovelForgeKind, _ id: UUID) -> EntityRef {
    EntityRef(kind: kind.entityKind, key: EntityKey(uuid: id))
  }

  private static func textRef(_ novel: UUID, _ components: Components) -> EntityRef {
    precondition(components.chapters.isEmpty, "a key with a chapter goes through the throwing builder")
    return NovelForgeKey(unchecked: novel, components).ref
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
    case .novel, .approval, .notebookEntry, .notebookWithdrawal: nil
    }
  }
}

extension NovelForgeKey {
  public static func volumeKey(novel: UUID, volume: String) -> NovelForgeKey { NovelForgeKey(unchecked: novel, .volume(volume)) }
  public static func milestoneKey(novel: UUID, milestone: String) -> NovelForgeKey { NovelForgeKey(unchecked: novel, .milestone(milestone)) }
  public static func threadKey(novel: UUID, thread: String) -> NovelForgeKey { NovelForgeKey(unchecked: novel, .thread(thread)) }
  public static func mysteryKey(novel: UUID, mystery: String) -> NovelForgeKey { NovelForgeKey(unchecked: novel, .mystery(mystery)) }
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
    }
  }

  var chapters: [Int] {
    switch self {
    case .chapterPlan(let chapter), .draft(let chapter), .finalChapter(let chapter): [chapter]
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
    case .chapterPlan, .draft, .finalChapter, .authorNotes: return self
    }
  }

  var hashed: [String] {
    switch self {
    case .volume(let key), .milestone(let key), .thread(let key), .mystery(let key), .secret(let key), .entity(let key): [key]
    case .characterKnowledge(let fact, let entity): [fact, entity]
    case .page(let section, let slug): [section.rawValue, slug]
    case .chapterPlan(let chapter), .draft(let chapter), .finalChapter(let chapter): [String(chapter)]
    case .authorNotes: []
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

  func novel() throws(NovelForgeKeyError) -> UUID {
    let text = try self.text("novel")
    guard let id = UUID(uuidString: text), id.uuidString.lowercased().utf8.elementsEqual(text.utf8) else { throw .malformedKey("novel is not a lower-case UUID") }
    return id
  }

  func text(_ name: String) throws(NovelForgeKeyError) -> String {
    guard let text = members[name]?.stringValue else { throw .malformedKey("\(name) is not a string") }
    return text
  }

  func chapter(_ name: String) throws(NovelForgeKeyError) -> Int {
    guard let number = members[name]?.intValue, let chapter = Int(exactly: number) else { throw .malformedKey("\(name) is not an integer") }
    return chapter
  }
}
