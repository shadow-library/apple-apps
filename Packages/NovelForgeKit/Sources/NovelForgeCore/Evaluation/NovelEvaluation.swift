import Foundation
import ShadowCore
import ShadowStore

public struct EvaluationChapter: Sendable, Hashable {
  public let chapter: Int
  public let body: String
  public let hookType: String?
  public let judge: String?
  public let reviewStatus: String
  public let status: String
  public let approved: Bool

  public init(chapter: Int, body: String, hookType: String?, judge: String?, reviewStatus: String, status: String, approved: Bool) {
    self.chapter = chapter
    self.body = body
    self.hookType = hookType
    self.judge = judge
    self.reviewStatus = reviewStatus
    self.status = status
    self.approved = approved
  }
}

public enum NovelEvaluationError: ShadowError {
  case store(StoreError)
  case review(ChapterReviewError)
  case domain(DomainError)

  public var code: String {
    switch self {
    case .store(let error): error.code
    case .review(let error): error.code
    case .domain(let error): error.code
    }
  }

  public var errorDescription: String? {
    switch self {
    case .store(let error): error.errorDescription
    case .review(let error): error.errorDescription
    case .domain(let error): error.errorDescription
    }
  }
}

public struct EvaluationSkip: Sendable, Hashable {
  public let chapter: Int
  public let reason: String

  public init(chapter: Int, reason: String) {
    self.chapter = chapter
    self.reason = reason
  }
}

public struct EvaluationChapters: Sendable, Equatable {
  public let chapters: [EvaluationChapter]
  public let skipped: [EvaluationSkip]
}

public enum NovelEvaluation {
  public static let defaultPriorWindow = 10

  /// tests/eval/deterministic-metrics.ts:70-131 reads `chapters.content` (`final`) or `drafts.body` (`draft`); here a final chapter reads its canon and any other its draft head.
  /// An empty body is dropped as `if (row.content)` drops it (:85, :93); a body this version cannot read is skipped and counted.
  public static func chapters(novel: UUID, in store: VaultStore) async throws(NovelEvaluationError) -> EvaluationChapters {
    let loaded: EvaluationRows
    do throws(StoreError) {
      loaded = try await store.write { transaction in try EvaluationRows.load(novel: novel, in: &transaction) }
    } catch {
      guard case .aborted(let cause as DomainError) = error else { throw .store(error) }
      throw .domain(cause)
    }
    var chapters: [EvaluationChapter] = []
    for row in loaded.rows {
      let judge: String?
      do throws(ChapterReviewError) {
        judge = try await store.chapterReviews(novel: novel, chapter: row.chapter).latest.first { $0.review.reviewKind == .known(.judge) }?.review.verdict
      } catch {
        throw .review(error)
      }
      chapters.append(
        EvaluationChapter(
          chapter: row.chapter, body: row.body, hookType: row.hookType, judge: judge, reviewStatus: row.reviewStatus, status: row.isFinal ? "final" : "draft",
          approved: row.approved))
    }
    return EvaluationChapters(chapters: chapters, skipped: loaded.skipped)
  }

  public static func applyPlanCard(of job: EntityRef, novel: UUID, in store: VaultStore, now: Date) async throws(ProposalApplyError) -> Bool {
    guard case .applied = try await store.applyProposal(PlanCards.id(of: job), selection: .whole, context: ProposalApplyContext(novel: novel, now: now)) else { return false }
    return true
  }

  public static func wordTarget(novel: UUID, in store: VaultStore) async throws(StoreError) -> WordTarget? {
    try await store.read { transaction in
      guard case .readable(let entry) = NovelRecord.reading(try transaction.state(of: NovelForgeKey.novel(novel), scope: .vault), of: NovelForgeKey.novel(novel)) else {
        return nil
      }
      return entry.record.wordTarget
    }
  }

  /// tests/eval/deterministic-metrics.ts:120-127: each chapter is compared with the `priorWindow` chapters before it; 0 takes all, as `slice(-0)` does.
  public static func proseMetrics(_ chapters: [EvaluationChapter], priorWindow: Int = defaultPriorWindow, wordTarget: WordTarget? = nil) -> String {
    let ordered = chapters.sorted { $0.chapter < $1.chapter }
    let inputs = ordered.map { ChapterMetricsInput(chapter: $0.chapter, body: $0.body, hookType: $0.hookType) }
    var priors: [Int: [String]] = [:]
    for chapter in ordered {
      let earlier = ordered.filter { $0.chapter < chapter.chapter }.map(\.body)
      priors[chapter.chapter] = priorWindow == 0 ? earlier : Array(earlier.suffix(priorWindow))
    }
    return ProseMetrics.computeDeterministicMetricsReport(inputs, priorBodiesByChapter: priors, target: .resolve(wordTarget)).json.jsonText
  }
}

private struct EvaluationRows: Sendable {
  let rows: [EvaluationRow]
  let skipped: [EvaluationSkip]

  static func load(novel: UUID, in transaction: inout WriteTransaction) throws -> EvaluationRows {
    var rows: [EvaluationRow] = []
    var skipped: [EvaluationSkip] = []
    for entry in try transaction.lifecycleEntries(novel: novel).sorted(by: { $0.chapter < $1.chapter }) {
      let body: String
      var approved = entry.approval != nil
      if entry.isFinal {
        let ref = try ChapterRefs.final(novel: novel, chapter: entry.chapter)
        let state = try storeCall { () throws(StoreError) in try transaction.state(of: ref, scope: .vault) }
        guard case .readable(let final) = FinalChapterRecord.reading(state, of: ref) else {
          skipped.append(EvaluationSkip(chapter: entry.chapter, reason: "unreadable_canon"))
          continue
        }
        body = final.record.text.body
        approved = approved || final.record.canon.approval != nil
      } else {
        let presence: DraftPresence
        do {
          presence = try transaction.draft(novel: novel, chapter: entry.chapter)
        } catch DomainError.unreadable {
          skipped.append(EvaluationSkip(chapter: entry.chapter, reason: "unreadable_draft"))
          continue
        }
        guard case .live(let head) = presence else { continue }
        body = head.content.body
      }
      guard !body.isEmpty else {
        skipped.append(EvaluationSkip(chapter: entry.chapter, reason: "empty_body"))
        continue
      }
      let hook = try transaction.planHead(novel: novel, chapter: entry.chapter)?.record.content.endingContract?.hookType
      rows.append(
        EvaluationRow(
          chapter: entry.chapter, body: body, hookType: hook.map(\.rawValue), reviewStatus: (entry.review ?? .needsReview).rawValue, isFinal: entry.isFinal,
          approved: approved))
    }
    return EvaluationRows(rows: rows, skipped: skipped)
  }
}

private struct EvaluationRow: Sendable {
  let chapter: Int
  let body: String
  let hookType: String?
  let reviewStatus: String
  let isFinal: Bool
  let approved: Bool
}
