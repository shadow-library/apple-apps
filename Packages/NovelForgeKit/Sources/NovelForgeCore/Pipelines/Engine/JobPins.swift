import Foundation
import ShadowCore
import ShadowJobs
import ShadowStore

/// The novel, chapter and kind a job's key names, read back through `NovelJobAddress`.
public struct NovelJobTarget: Sendable, Hashable {
  public let novel: UUID
  public let chapter: Int
  public let kind: NovelJobKind

  public init(novel: UUID, chapter: Int, kind: NovelJobKind) {
    self.novel = novel
    self.chapter = chapter
    self.kind = kind
  }

  init?(_ key: JobKey) {
    guard let novel = NovelJobAddress.novel(ofScope: key.scope), let chapter = NovelJobAddress.chapter(ofTarget: key.target),
      let kind = NovelJobKind(rawValue: key.kind)
    else { return nil }
    self.init(novel: novel, chapter: chapter, kind: kind)
  }
}

/// What an attempt read when it started, recorded on its `start` so later steps never read the live store for it (plan, Leases, stopping and resuming).
/// `upstream` is `ChapterFingerprint` rule 2 at the start: the previous chapters' resting revisions or the canon digest the chapter rests on.
struct JobPins: Sendable, Equatable {
  let pipeline: Int
  /// The plan head's revision; nil when the chapter has no live plan.
  let plan: String?
  let upstream: DraftUpstream
  let bible: String

  private enum Member: String {
    case pipeline
    case plan
    case upstream
    case bible
  }

  var json: JSONValue {
    [
      Member.pipeline.rawValue: .int(Int64(pipeline)), Member.plan.rawValue: plan.map(JSONValue.string) ?? .null, Member.upstream.rawValue: upstream.json,
      Member.bible.rawValue: .string(bible),
    ]
  }

  static func pipelineVersion(in json: JSONValue) -> Int? {
    json.objectValue?[Member.pipeline.rawValue]?.intValue.flatMap { Int(exactly: $0) }
  }

  init(pipeline: Int, plan: String?, upstream: DraftUpstream, bible: String) {
    self.pipeline = pipeline
    self.plan = plan
    self.upstream = upstream
    self.bible = bible
  }

  init?(json: JSONValue) {
    guard let members = json.objectValue, let pipeline = Self.pipelineVersion(in: json), let bible = members[Member.bible.rawValue]?.stringValue,
      let upstream = members[Member.upstream.rawValue].flatMap(DraftUpstream.init(json:))
    else { return nil }
    let plan = members[Member.plan.rawValue]
    guard plan?.isNull ?? true || plan?.stringValue != nil else { return nil }
    self.init(pipeline: pipeline, plan: plan?.stringValue, upstream: upstream, bible: bible)
  }

  static func pin(_ target: NovelJobTarget, pipeline: Int, in transaction: borrowing WriteTransaction) throws(JobEngineError) -> JobPins {
    do {
      let plan = try transaction.planHead(novel: target.novel, chapter: target.chapter)?.revision
      let upstream = try storing { () throws(StoreError) in try DraftUpstream.current(novel: target.novel, chapter: target.chapter, in: transaction) }
      let bible = try storing { () throws(StoreError) in try StoryBibleHash.of(target.novel, in: transaction) }
      return JobPins(pipeline: pipeline, plan: plan, upstream: upstream, bible: bible)
    } catch {
      throw .pins(error)
    }
  }

  private static func storing<T>(_ body: () throws(StoreError) -> T) throws(DomainError) -> T {
    do {
      return try body()
    } catch {
      throw .store(error)
    }
  }
}

/// Native: the reference hashes the rendered pack (writer-snapshot-capture.ts:6), which an attempt builds after it starts; the pin hashes what that pack is
/// built from instead, each live entity, page and fact by every field it stores (a document by its head revision too), with the count this device cannot read.
enum StoryBibleHash {
  static func of<Transaction: StateReading & ~Copyable>(_ novel: UUID, in transaction: borrowing Transaction) throws(StoreError) -> String {
    let entities = try EntityRecord.listing(novel: novel, in: transaction)
    let pages = try PageRecord.listing(novel: novel, in: transaction)
    let facts = try SecretRecord.listing(novel: novel, in: transaction)
    var items: [(order: String, value: JSONValue)] = []
    for ref in entities.live.map(\.ref) + pages.live.map(\.ref) + facts.live.map(\.ref) {
      guard let state = try transaction.state(of: ref, scope: .vault) else { continue }
      items.append(("\(ref.kind)\u{0}\(ref.key.rawValue)", .array([.string(ref.kind.description), .string(ref.key.rawValue), stored(state)])))
    }
    let sorted = items.sorted { JSText.codeUnitPrecedes($0.order, $1.order) }.map(\.value)
    let unreadable = entities.unreadable + pages.unreadable + facts.unreadable
    return ChapterFingerprint.digest(["records": .array(sorted), "unreadable": .int(Int64(unreadable))])
  }

  private static func stored(_ state: EntityState) -> JSONValue {
    switch state {
    case .record(let record): return fields(record.fields)
    case .revisioned(let revisioned): return ["fields": fields(revisioned.fields), "head": revisioned.headRevision.map(JSONValue.string) ?? .null]
    case .appended, .purged: return .null
    }
  }

  private static func fields(_ fields: [ExactString: FieldState]) -> JSONValue {
    .object(Dictionary(uniqueKeysWithValues: fields.map { ($0.key.value, $0.value.value) }))
  }
}
