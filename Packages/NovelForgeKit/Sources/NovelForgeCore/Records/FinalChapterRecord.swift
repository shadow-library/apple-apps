import Foundation
import ShadowCore
import ShadowStore

extension FinalChapterField: FieldName {}
extension FinalChapterCanonMember: FieldName {}

enum FinalChapterAmendmentMember: String, CaseIterable, FieldName {
  case canon
  case title
  case body
  case note
  case summary
}

// apps/novel-forge-server/src/modules/ai/graphs/chapter-finalization.graph.ts:140
public struct Canon: Sendable, Equatable {
  public var draftRevision: String?
  public var planRevision: String?
  public var approval: UUID?
  public var title: String?
  public var body: String
  public var summary: String?
  public var note: String?
  public var generator: StoredEnum<ContentGenerator>
  public var isolated: Bool
  public var volume: String?
  public var contract: ChapterContract
  public var disclosed: [String]?
  public private(set) var unrecognised: [String: JSONValue]

  public init(
    draftRevision: String? = nil, planRevision: String? = nil, approval: UUID? = nil, title: String? = nil, body: String, summary: String? = nil, note: String? = nil,
    generator: StoredEnum<ContentGenerator> = .known(.standard), isolated: Bool = false, volume: String? = nil, contract: ChapterContract = ChapterContract(),
    disclosed: [String]? = nil
  ) {
    self.draftRevision = draftRevision
    self.planRevision = planRevision
    self.approval = approval
    self.title = title
    self.body = body
    self.summary = summary
    self.note = note
    self.generator = generator
    self.isolated = isolated
    self.volume = volume
    self.contract = contract
    self.disclosed = disclosed
    unrecognised = [:]
  }

  static func normalisedDisclosure(_ keys: [String]) -> [String] {
    Set(keys.map(\.precomposedStringWithCanonicalMapping)).sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
  }

  private static func disclosure(in json: JSONValue) -> [String]? {
    guard case .array(let items) = json else { return nil }
    let keys = items.compactMap(\.stringValue)
    guard keys.count == items.count else { return nil }
    return normalisedDisclosure(keys)
  }
}

extension Canon: JSONRepresentable {
  public init?(json: JSONValue) {
    guard let reader = FieldReader<FinalChapterCanonMember>(object: json) else { return nil }
    do throws(UnreadableReason) {
      self.init(
        draftRevision: try reader.optional(.draftRevision), planRevision: try reader.optional(.planRevision), approval: try reader.optional(.approval),
        title: try reader.optional(.title), body: try reader.required(.body), summary: try reader.optional(.summary), note: try reader.optional(.note),
        generator: try reader.required(.generator), isolated: try reader.required(.isolated), volume: try reader.optional(.volume), contract: try reader.required(.contract))
    } catch {
      return nil
    }
    unrecognised = reader.unrecognised
    let disclosure = json.objectValue?[FinalChapterCanonMember.disclosed.rawValue]
    disclosed = disclosure.flatMap(Self.disclosure(in:))
    // A malformed list reads as not recorded and is kept as found, so the canon still encodes to what was stored.
    if let disclosure, !disclosure.isNull, disclosed == nil { unrecognised[FinalChapterCanonMember.disclosed.rawValue] = disclosure }
  }

  public var json: JSONValue {
    var fields = RecordFields<FinalChapterCanonMember>()
    fields.put(.draftRevision, draftRevision)
    fields.put(.planRevision, planRevision)
    fields.put(.approval, approval)
    fields.put(.title, title)
    fields.put(.body, body)
    fields.put(.summary, summary)
    fields.put(.note, note)
    fields.put(.generator, generator)
    fields.put(.isolated, isolated)
    fields.put(.volume, volume)
    fields.put(.contract, contract)
    if disclosed != nil || unrecognised[FinalChapterCanonMember.disclosed.rawValue] == nil { fields.put(.disclosed, disclosed.map(Self.normalisedDisclosure)) }
    return .object(unrecognised.merging(fields.members) { _, known in known })
  }
}

public struct FinalChapterText: Sendable, Equatable {
  public var title: String?
  public var body: String
  public var note: String?
  public var summary: String?

  public init(title: String? = nil, body: String, note: String? = nil, summary: String? = nil) {
    self.title = title
    self.body = body
    self.note = note
    self.summary = summary
  }
}

// apps/novel-forge-server/src/modules/generation/chapter-amend.dto.ts:6; `canon` is the digest of the canon it was made against, so an amendment of a canon that lost never shows
public struct FinalChapterAmendment: RevisionBody, Sendable {
  public let canon: String
  public var text: FinalChapterText
  public private(set) var unrecognised: [String: JSONValue]

  init(canon: String, text: FinalChapterText) {
    self.canon = canon
    self.text = text
    unrecognised = [:]
  }

  public init?(json: JSONValue) {
    guard let reader = FieldReader<FinalChapterAmendmentMember>(object: json) else { return nil }
    do throws(UnreadableReason) {
      self.init(
        canon: try reader.required(.canon),
        text: FinalChapterText(title: try reader.optional(.title), body: try reader.required(.body), note: try reader.optional(.note), summary: try reader.optional(.summary)))
    } catch {
      return nil
    }
    unrecognised = reader.unrecognised
  }

  public var json: JSONValue {
    var fields = RecordFields<FinalChapterAmendmentMember>()
    fields.put(.canon, canon)
    fields.put(.title, text.title)
    fields.put(.body, text.body)
    fields.put(.note, text.note)
    fields.put(.summary, text.summary)
    return .object(unrecognised.merging(fields.members) { _, known in known })
  }

  func replacing(_ text: FinalChapterText) -> FinalChapterAmendment {
    var copy = self
    copy.text = text
    return copy
  }
}

public enum FinalizeOutcome: Sendable, Equatable {
  case finalized(ChangeRecord)
  case alreadyFinal(FinalChapterRecord)
  case unreadableCanon(UnreadableReason)
}

// A chapter is final when its canon exists; everything derived from finalized data reads the canon, and an amendment bound to it changes only the text and summary.
public struct FinalChapterRecord: RevisionedRecord {
  public typealias Body = FinalChapterAmendment

  public static let kind = NovelForgeKind.finalChapter

  public let key: NovelForgeKey
  public let chapter: Int
  public let canon: Canon
  public let canonDigest: String
  public let amendment: FinalChapterAmendment?
  public let amendmentRevision: String?

  public init(novel: UUID, chapter: Int, canon: Canon) throws(NovelForgeKeyError) {
    key = try .finalChapterKey(novel: novel, chapter: chapter)
    self.chapter = chapter
    self.canon = canon
    canonDigest = Self.digest(canon.json)
    amendment = nil
    amendmentRevision = nil
  }

  public init(key: NovelForgeKey, reading reader: FieldReader<FinalChapterField>) throws(UnreadableReason) {
    guard case .finalChapter(let chapter) = key.components else { throw .naturalKey(.keyMismatch(key.ref)) }
    let stored: JSONValue = try reader.required(.canon)
    guard let canon = Canon(json: stored) else { throw .invalid(field: FinalChapterField.canon.rawValue) }
    let digest = Self.digest(stored)
    self.key = key
    self.chapter = chapter
    self.canon = canon
    canonDigest = digest
    let bound = reader.revisionsNewestFirst.lazy.compactMap { revision in FinalChapterAmendment(json: revision.body).map { (id: revision.id, amendment: $0) } }
      .first { $0.amendment.canon.utf8.elementsEqual(digest.utf8) }
    amendment = bound?.amendment
    amendmentRevision = bound?.id
  }

  // `summary` stays declared in schema v1; nothing writes it and readers ignore it.
  public var fields: RecordFields<FinalChapterField> {
    var fields = RecordFields<FinalChapterField>()
    fields.put(.canon, canon)
    return fields
  }

  public var text: FinalChapterText {
    amendment?.text ?? FinalChapterText(title: canon.title, body: canon.body, note: canon.note, summary: canon.summary)
  }

  public func create(in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    try transaction.set(ref, [CommonField.naturalKey.rawValue: key.stored, FinalChapterField.canon.rawValue: canon.json])
  }

  public static func edit(_ ref: EntityRef, _ edit: RecordFields<FinalChapterField>, in transaction: inout WriteTransaction) throws(StoreError) -> ChangeRecord {
    throw .invalidChange("\(ref.kind.rawValue)/\(ref.key.rawValue) is written only by finalize and amend")
  }

  public static func isPending(_ state: EntityState) -> Bool {
    guard case .revisioned(let revisioned) = state else { return false }
    return revisioned[field: CommonField.naturalKey.rawValue] == nil || revisioned[field: FinalChapterField.canon.rawValue] == nil
  }

  static func digest(_ canon: JSONValue) -> String {
    sha256Hex(String(decoding: CanonicalJSON.encode(canon), as: UTF8.self))
  }

  private func amended(_ text: FinalChapterText) -> FinalChapterAmendment {
    amendment?.replacing(text) ?? FinalChapterAmendment(canon: canonDigest, text: text)
  }
}

extension FinalChapterRecord {
  public static func ref(novel: UUID, chapter: Int) throws(NovelForgeKeyError) -> EntityRef { try NovelForgeKey.finalChapter(novel: novel, chapter: chapter) }

  public func finalize(in transaction: inout WriteTransaction) throws(StoreError) -> FinalizeOutcome {
    let state = try transaction.state(of: ref, scope: .vault)
    guard case .revisioned(let existing)? = state, existing[field: FinalChapterField.canon.rawValue] != nil else { return .finalized(try create(in: &transaction)) }
    switch Self.reading(state, of: ref) {
    case .readable(let entry): return .alreadyFinal(entry.record)
    case .unreadable(let reason): return .unreadableCanon(reason)
    case .absent: return .unreadableCanon(.missing(field: CommonField.naturalKey.rawValue))
    }
  }

  public static func amend(_ ref: EntityRef, _ text: FinalChapterText, in transaction: inout WriteTransaction) throws(StoreError) -> Revised {
    try revise(ref, body: try final(ref, in: transaction).amended(text), in: &transaction)
  }

  public static func editSummary(_ ref: EntityRef, _ summary: String?, in transaction: inout WriteTransaction) throws(StoreError) -> Revised {
    let record = try final(ref, in: transaction)
    var text = record.text
    text.summary = summary
    return try revise(ref, body: record.amended(text), in: &transaction)
  }

  public static func history<Transaction: StateReading & ~Copyable>(_ ref: EntityRef, in transaction: borrowing Transaction) throws(StoreError) -> HistoryReading<
    FinalChapterAmendment, NoMark
  > {
    try history(of: ref, in: transaction)
  }

  private static func final(_ ref: EntityRef, in transaction: borrowing WriteTransaction) throws(StoreError) -> FinalChapterRecord {
    guard case .readable(let entry) = try read(ref, in: transaction) else { throw .invalidChange("\(ref.kind.rawValue)/\(ref.key.rawValue) is not a readable final chapter") }
    return entry.record
  }
}
