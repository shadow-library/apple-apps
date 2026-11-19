import Foundation
import ShadowCore
import ShadowStore

extension DraftMark: FieldName {}

// apps/novel-forge-server/src/database/schemas/projects.ts:43
public enum ContentGenerator: String, CaseIterable, Sendable {
  case standard
  case unrestricted
  case human
}

// apps/novel-forge-server/src/database/schemas/ai.ts:76
public enum DraftSource: String, CaseIterable, Sendable {
  case generated
  case patched
  case rewritten
  case revised
  case imported
  case handEdited = "hand_edited"
  case chatEdited = "chat_edited"
  case amended
  case restored
  case passageRewritten = "passage_rewritten"
}

enum DraftContentMember: String, CaseIterable, FieldName {
  case title
  case body
  case summary
  case source
  case generator
  case isolated
  case restoredFrom = "restored_from"
  case upstream
  case state
  case run
  case job
  case leakHold = "leak_hold"
}

// apps/novel-forge-server/src/database/schemas/ai.ts:267-291; the review status, stale reason and word count are derived, never stored
public struct DraftContent: RevisionBody, Sendable {
  public var title: String?
  public var body: String
  public var summary: String?
  public var source: StoredEnum<DraftSource>
  public var generator: StoredEnum<ContentGenerator>
  public var isolated: Bool
  public var restoredFrom: String?
  public private(set) var unrecognised: [String: JSONValue]
  /// Kept as stored, so a shape this version cannot read still round-trips and never hides the prose.
  private var storedUpstream: JSONValue
  private var storedState: JSONValue
  private var storedRun: JSONValue
  private var storedJob: JSONValue
  private var storedLeakHold: JSONValue

  public init(
    title: String? = nil, body: String, summary: String? = nil, source: StoredEnum<DraftSource>, generator: StoredEnum<ContentGenerator> = .known(.standard),
    isolated: Bool = false, restoredFrom: String? = nil, upstream: DraftUpstream? = nil, state: [String: JSONValue]? = nil, run: String? = nil, job: EntityKey? = nil
  ) {
    self.title = title
    self.body = body
    self.summary = summary
    self.source = source
    self.generator = generator
    self.isolated = isolated
    self.restoredFrom = restoredFrom
    storedUpstream = upstream.json
    storedState = state.json
    storedRun = run.json
    storedJob = job.json
    storedLeakHold = .null
    unrecognised = [:]
  }

  /// What the revision was written against (`ChapterFingerprint` rule 2); nil when it records nothing this version can read, which the lifecycle shows as stale.
  public var upstream: DraftUpstream? {
    get { DraftUpstream(json: storedUpstream) }
    set { storedUpstream = newValue.json }
  }

  /// The continuation state a generation run wrote (apps/novel-forge-server/src/modules/ai/graphs/chapter-generation.graph.ts:209), which CHP_005 requires of an
  /// isolated chapter (common/finalize-gate.ts:21); nil when it records none this version can read.
  public var state: [String: JSONValue]? {
    get { storedState.objectValue }
    set { storedState = newValue.json }
  }

  /// The generation run that wrote the revision (chapter-generation.graph.ts:210).
  public var run: String? {
    get { storedRun.stringValue }
    set { storedRun = newValue.json }
  }

  public var job: EntityKey? {
    get { EntityKey(json: storedJob) }
    set { storedJob = newValue.json }
  }

  /// The head a passage rewrite was written over when it brought in a locked secret its passage did not give away (schema v4, holdNewLeaks in
  /// apps/novel-forge-server/src/modules/generation/passage-leaks.ts:13). Naming the parent holds that one revision: content copied into a later one holds nothing.
  public var leakHeldOver: String? {
    get { storedLeakHold.stringValue }
    set { storedLeakHold = newValue.json }
  }

  public func holdsLeak(over parent: String?) -> Bool {
    guard let parent, let held = leakHeldOver else { return false }
    return held.utf8.elementsEqual(parent.utf8)
  }

  public init?(json: JSONValue) {
    guard let reader = FieldReader<DraftContentMember>(object: json) else { return nil }
    do throws(UnreadableReason) {
      self.init(
        title: try reader.optional(.title), body: try reader.required(.body), summary: try reader.optional(.summary), source: try reader.required(.source),
        generator: try reader.required(.generator), isolated: try reader.required(.isolated), restoredFrom: try reader.optional(.restoredFrom))
    } catch {
      return nil
    }
    storedUpstream = Self.stored(.upstream, in: reader)
    storedState = Self.stored(.state, in: reader)
    storedRun = Self.stored(.run, in: reader)
    storedJob = Self.stored(.job, in: reader)
    storedLeakHold = Self.stored(.leakHold, in: reader)
    unrecognised = reader.unrecognised
  }

  public var json: JSONValue {
    var fields = RecordFields<DraftContentMember>()
    fields.put(.title, title)
    fields.put(.body, body)
    fields.put(.summary, summary)
    fields.put(.source, source)
    fields.put(.generator, generator)
    fields.put(.isolated, isolated)
    fields.put(.restoredFrom, restoredFrom)
    fields.put(.upstream, storedUpstream)
    fields.put(.state, storedState)
    fields.put(.run, storedRun)
    fields.put(.job, storedJob)
    if storedLeakHold != .null { fields.put(.leakHold, storedLeakHold) }
    return .object(unrecognised.merging(fields.members) { _, known in known })
  }

  private static func stored(_ member: DraftContentMember, in reader: FieldReader<DraftContentMember>) -> JSONValue {
    let value: JSONValue? = try? reader.optional(member)
    return value ?? .null
  }
}

// The `approved` mark only keeps a revision from being pruned; the approval in force comes from the approval items.
public struct DraftRecord: DocumentRecord, RemovableRecord {
  public typealias Body = DraftContent
  public typealias Mark = DraftMark

  public static let kind = NovelForgeKind.draft

  public let key: NovelForgeKey
  public let chapter: Int
  public var content: DraftContent

  public init(novel: UUID, chapter: Int, content: DraftContent) throws(NovelForgeKeyError) {
    key = try .draftKey(novel: novel, chapter: chapter)
    self.chapter = chapter
    self.content = content
  }

  public init(key: NovelForgeKey, reading reader: FieldReader<DocumentField>) throws(UnreadableReason) {
    guard case .draft(let chapter) = key.components else { throw .naturalKey(.keyMismatch(key.ref)) }
    self.key = key
    self.chapter = chapter
    content = try reader.head()
  }
}

extension DraftRecord {
  public static func ref(novel: UUID, chapter: Int) throws(NovelForgeKeyError) -> EntityRef { try NovelForgeKey.draft(novel: novel, chapter: chapter) }

  public static func revise(_ ref: EntityRef, _ content: DraftContent, marks: [DraftMark] = [], in transaction: inout WriteTransaction) throws(StoreError) -> Revised {
    try revise(ref, body: content, marks: marks, in: &transaction)
  }

  /// A revision beside the head, child of `parent`, that does not become the head; it holds no leak, whatever revision its content was copied from.
  public static func keep(_ ref: EntityRef, _ content: DraftContent, parent: RevisionParent, in transaction: inout WriteTransaction) throws(StoreError) -> Revised {
    var content = content
    content.leakHeldOver = nil
    return try revise(ref, body: content, parent: parent, head: false, in: &transaction)
  }

  public static func mark(_ ref: EntityRef, revision: String, _ marks: [DraftMark], in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try mark(ref, revision: revision, as: marks, in: &transaction)
  }

  public static func history<Transaction: StateReading & ~Copyable>(_ ref: EntityRef, in transaction: borrowing Transaction) throws(StoreError) -> HistoryReading<
    DraftContent, DraftMark
  > {
    try history(of: ref, in: transaction)
  }
}
