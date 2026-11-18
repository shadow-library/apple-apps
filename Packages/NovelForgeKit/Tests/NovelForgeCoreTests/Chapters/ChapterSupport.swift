import Foundation
import GRDB
import ShadowCore
import ShadowStore

@testable import NovelForgeCore

let chapterAreaDerivations = ProjectionDerivations.all + CanonDerivations.all + PlanWorldDerivations.all + ChapterDerivations.all

enum UpstreamRecording: Sendable {
  case current
  case none
  case given(DraftUpstream)
}

/// The writes chapter operations will make, done the way the fingerprint rules expect: every draft revision records its upstream, every approval its terms.
enum ChapterWrites {
  static func head(novel: UUID, chapter: Int, in transaction: borrowing WriteTransaction) throws -> String? {
    guard case .revisioned(let state)? = try transaction.state(of: try DraftRecord.ref(novel: novel, chapter: chapter), scope: .vault) else { return nil }
    return state.headRevision
  }

  static func planContract(novel: UUID, chapter: Int, in transaction: borrowing WriteTransaction) throws -> ChapterContract? {
    guard case .readable(let entry) = try ChapterPlanRecord.read(try ChapterPlanRecord.ref(novel: novel, chapter: chapter), in: transaction), !entry.isRemoved else {
      return nil
    }
    return entry.record.content.contract
  }

  @discardableResult
  static func draft(
    novel: UUID, chapter: Int, body: String = "The tide turns.", source: DraftSource = .generated, recording: UpstreamRecording = .current,
    in transaction: inout WriteTransaction
  ) throws -> String {
    let upstream: DraftUpstream? =
      switch recording {
      case .current: try DraftUpstream.current(novel: novel, chapter: chapter, in: transaction)
      case .none: nil
      case .given(let upstream): upstream
      }
    let content = DraftContent(body: body, source: .known(source), upstream: upstream)
    let record = try DraftRecord(novel: novel, chapter: chapter, content: content)
    switch try DraftRecord.read(record.ref, in: transaction) {
    case .absent: _ = try record.create(in: &transaction)
    case .readable(let entry) where entry.isRemoved:
      _ = try record.restore(in: &transaction)
      _ = try DraftRecord.revise(record.ref, content, in: &transaction)
    default: _ = try DraftRecord.revise(record.ref, content, in: &transaction)
    }
    return try head(novel: novel, chapter: chapter, in: transaction) ?? ""
  }

  static func removeDraft(novel: UUID, chapter: Int, in transaction: inout WriteTransaction) throws {
    let ref = try DraftRecord.ref(novel: novel, chapter: chapter)
    guard case .readable(let entry) = try DraftRecord.read(ref, in: transaction), !entry.isRemoved else { return }
    _ = try DraftRecord.remove(ref, in: &transaction)
  }

  /// Approves the head as the plan head stands; an `as_written` approval accepts the differences the lifecycle shows.
  static func approve(novel: UUID, chapter: Int, kind: ApprovalKind = .standard, id: UUID = UUID(), in transaction: inout WriteTransaction) throws {
    guard let head = try head(novel: novel, chapter: chapter, in: transaction) else { return }
    let terms = ChapterFingerprint.planTerms(try planContract(novel: novel, chapter: chapter, in: transaction))
    let upstream = kind == .asWritten ? try ChapterLifecycleEntry.read(novel: novel, chapter: chapter, in: transaction.database)?.differences : nil
    let approval = ApprovalRecord(
      id: id, novel: novel, chapter: chapter, approvalKind: .known(kind), draftRevision: head, planRevision: "v:plan", planTermsDigest: terms, upstreamDigest: upstream)
    _ = try approval.append(in: &transaction)
  }

  /// Finalizes the draft head with the plan head's contract and what it discloses, as finalize records them, bound to the approval in force as reconciled.
  static func finalize(novel: UUID, chapter: Int, in transaction: inout WriteTransaction) throws {
    let head = try head(novel: novel, chapter: chapter, in: transaction)
    let approval = try ChapterLifecycleEntry.read(novel: novel, chapter: chapter, in: transaction.database)?.approval
    let plan = try planContract(novel: novel, chapter: chapter, in: transaction)
    let volume = try ChapterPlanRecord.read(try ChapterPlanRecord.ref(novel: novel, chapter: chapter), in: transaction).entry?.record.content.volume
    let disclosed = plan == nil ? [] : try ChapterFinalize.disclosed(novel: novel, chapter: chapter, in: transaction)
    let canon = Canon(
      draftRevision: head, planRevision: "v:plan", approval: approval, body: "Final \(chapter).", volume: volume, contract: plan ?? ChapterContract(),
      disclosed: disclosed)
    _ = try FinalChapterRecord(novel: novel, chapter: chapter, canon: canon).finalize(in: &transaction)
  }

  static func reveal(novel: UUID, fact: String, entity: String, chapter: Int, in transaction: inout WriteTransaction) throws {
    let record = CharacterKnowledgeRecord(novel: novel, fact: fact, entity: entity, reveal: ManualReveal(chapter: chapter))
    switch try CharacterKnowledgeRecord.read(record.ref, in: transaction) {
    case .absent: _ = try record.create(in: &transaction)
    case .readable(let entry) where entry.isRemoved: _ = try record.restore(in: &transaction)
    default: _ = try CharacterKnowledgeRecord.edit(record.ref, record.fields, in: &transaction)
    }
  }

  static func retract(novel: UUID, fact: String, entity: String, in transaction: inout WriteTransaction) throws {
    let ref = CharacterKnowledgeRecord.ref(novel: novel, fact: fact, entity: entity)
    guard case .readable(let entry) = try CharacterKnowledgeRecord.read(ref, in: transaction), !entry.isRemoved else { return }
    _ = try CharacterKnowledgeRecord.remove(ref, in: &transaction)
  }

  static func entity(novel: UUID, _ key: String, in transaction: inout WriteTransaction) throws {
    let record = EntityRecord(novel: novel, entity: key, type: .known(.character), name: key.capitalized)
    switch try EntityRecord.read(record.ref, in: transaction) {
    case .absent: _ = try record.create(in: &transaction)
    case .readable(let entry) where entry.isRemoved: _ = try record.restore(in: &transaction)
    default: break
    }
  }
}

/// A chapter's lifecycle reduced to what the tests compare.
struct LifecycleView: Hashable, CustomStringConvertible {
  let review: DraftReviewState?
  let stale: String?
  let planStale: String?
  let approval: UUID?

  init(review: DraftReviewState?, stale: String? = nil, planStale: String? = nil, approval: UUID? = nil) {
    self.review = review
    self.stale = stale
    self.planStale = planStale
    self.approval = approval
  }

  init(_ entry: ChapterLifecycleEntry) {
    self.init(review: entry.review, stale: entry.stale?.reason, planStale: entry.planStale?.reason, approval: entry.approval)
  }

  var description: String {
    "\(review?.rawValue ?? "-") stale=\(stale ?? "-") plan=\(planStale ?? "-") approval=\(approval.map { "\($0)" } ?? "-")"
  }
}

enum ChapterTables {
  static func lifecycle(_ novel: UUID, in store: VaultStore) async throws -> [Int: ChapterLifecycleEntry] {
    Dictionary(uniqueKeysWithValues: try await Projection.fetch(ChapterLifecycleDerivation.request(for: novel), in: store).map { ($0.chapter, $0) })
  }

  static func views(_ novel: UUID, in store: VaultStore) async throws -> [Int: LifecycleView] {
    try await lifecycle(novel, in: store).mapValues(LifecycleView.init)
  }

  static func approvals(_ novel: UUID, in store: VaultStore) async throws -> [Int: UUID] {
    Dictionary(uniqueKeysWithValues: try await Projection.fetch(ApprovalInForceDerivation.request(for: novel), in: store).map { ($0.chapter, $0.approval) })
  }

  static func disclosure(_ novel: UUID, in store: VaultStore) async throws -> [String: Int] {
    Dictionary(uniqueKeysWithValues: try await Projection.fetch(ReaderDisclosureDerivation.request(for: novel), in: store).map { ($0.secret, $0.chapter) })
  }

  static func recorded(in store: VaultStore) async throws -> [[String]?] {
    try await Projection.finals(in: store).map { final in try final.disclosed.map(DisclosedColumn.decode) }
  }

  static func knowledge(_ novel: UUID, in store: VaultStore) async throws -> Set<LedgerView> {
    Set(try await Projection.fetch(CharacterKnowledgeDerivation.request(for: novel), in: store).map(LedgerView.init))
  }
}

struct LedgerView: Hashable, CustomStringConvertible {
  let fact: String
  let entity: String
  let chapter: Int
  let source: FactSource
  let status: KnowledgeStatus

  init(_ fact: String, _ entity: String, _ chapter: Int, _ source: FactSource, _ status: KnowledgeStatus) {
    self.fact = fact
    self.entity = entity
    self.chapter = chapter
    self.source = source
    self.status = status
  }

  init(_ entry: CharacterKnowledgeEntry) {
    self.init(entry.fact, entry.entity, entry.chapter, entry.source, entry.status)
  }

  var description: String { "\(entity)→\(fact)@\(chapter) \(source.rawValue) \(status.rawValue)" }
}
