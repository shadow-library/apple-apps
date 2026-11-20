import Foundation
import ShadowCore
import ShadowStore
import ShadowText

public enum ChapterSummaryError: ShadowError, Equatable {
  case noProse(Int)
  case generating(Int)
  /// The prose changed while the summary was written, so it may describe text that is gone; the author decides whether to keep it.
  case conflict(chapter: Int, attempted: String)
  case domain(DomainError)
  case store(StoreError)

  public var code: String {
    switch self {
    case .noProse: "CHP_007"
    case .generating: "DRF_019"
    case .conflict: "DRF_013"
    case .domain(let error): error.code
    case .store(let error): error.code
    }
  }

  // apps/novel-forge-server/src/classes/app-error-code.ts:19,71-74
  public var errorDescription: String? {
    switch self {
    case .noProse: "Draft has no prose yet — import or generate the chapter before summarizing it"
    case .generating(let chapter): "Chapter \(chapter) is being written by the AI right now — wait for it to finish, or cancel it to write the chapter yourself"
    case .conflict: "This chapter changed while it was being summarized. Reload it and try again."
    case .domain(let error): error.errorDescription
    case .store(let error): error.errorDescription
    }
  }

  public static func == (left: ChapterSummaryError, right: ChapterSummaryError) -> Bool {
    left.code == right.code && left.errorDescription == right.errorDescription
  }
}

/// What summarizing returned. An isolated chapter that is not final gets its summary and state back unsaved, as the author's to keep through a draft save,
/// since the state is what finalize checks (CHP_005); every other summary is saved, as `revision` says for a draft.
public struct ChapterSummaryResult: Sendable, Equatable {
  public let summary: String
  public let state: [String: JSONValue]
  public let saved: Bool
  /// The draft revision the summary was saved in; nil for a final chapter or an unsaved summary.
  public let revision: String?
}

/// Summarizing a chapter's prose (apps/novel-forge-server/src/modules/generation/generation.service.ts:768-799), hand-written or AI, final or not.
enum ChapterSummary {
  struct Source: Equatable, Sendable {
    let body: String
    let isolated: Bool
    let final: Bool
    let revision: String?
  }

  static func source(novel: UUID, chapter: Int, at now: Date, in transaction: ReadTransaction) throws(ChapterSummaryError) -> Source {
    let source = try read(novel: novel, chapter: chapter, in: transaction)
    guard !source.body.jsTrim().isEmpty else { throw .noProse(chapter) }
    if source.final { return source }
    let generating: Bool
    do throws(ChapterReviewError) {
      generating = try ChapterReviews.isGenerating(novel: novel, chapter: chapter, at: now, in: transaction)
    } catch {
      throw ChapterSummaryError(error)
    }
    if generating { throw .generating(chapter) }
    return source
  }

  /// draft-save.ts:96-126: saved only over the prose that was summarized; a working copy over the head is committed with it, so no typed text is lost.
  static func save(_ summary: String, novel: UUID, chapter: Int, over read: Source, in transaction: inout WriteTransaction) throws(ChapterSummaryError) -> String? {
    let current = try self.read(novel: novel, chapter: chapter, in: transaction)
    guard current.final == read.final, current.body.jsEquals(read.body), sameUnits(current.revision, read.revision) else {
      throw .conflict(chapter: chapter, attempted: summary)
    }
    if current.final {
      try domain { () throws(DomainError) in try FinalChapters.editSummary(novel: novel, chapter: chapter, summary: summary, in: &transaction) }
      return nil
    }
    let head = try domain { () throws(DomainError) in try transaction.liveDraft(novel: novel, chapter: chapter) }
    let copy = try domain { () throws(DomainError) in
      try storeCall { () throws(StoreError) in try DraftWorkingCopy.read(novel: novel, chapter: chapter, in: transaction.database) }
    }
    var content = head.content
    if let copy, copy.base.utf8.elementsEqual(head.revision.utf8) {
      guard copy.content.body.jsEquals(read.body) else { throw .conflict(chapter: chapter, attempted: summary) }
      content = copy.content
    }
    guard !sameUnits(content.summary, summary) else { return head.revision }
    content.summary = summary
    return try domain { () throws(DomainError) in try ChapterDrafts.commit(content, novel: novel, chapter: chapter, in: &transaction) }
  }

  private static func domain<T>(_ body: () throws(DomainError) -> T) throws(ChapterSummaryError) -> T {
    do {
      return try body()
    } catch {
      throw .domain(error)
    }
  }

  private static func read<Transaction: StateReading & ~Copyable>(novel: UUID, chapter: Int, in transaction: borrowing Transaction) throws(ChapterSummaryError) -> Source {
    do throws(DomainError) {
      let finalRef = try ChapterRefs.final(novel: novel, chapter: chapter)
      if let final = try readable(try storeCall { () throws(StoreError) in try FinalChapterRecord.read(finalRef, in: transaction) }, ref: finalRef)?.record {
        return Source(body: final.text.body, isolated: final.canon.isolated, final: true, revision: nil)
      }
      let ref = try ChapterRefs.draft(novel: novel, chapter: chapter)
      guard let entry = try readable(try storeCall { () throws(StoreError) in try DraftRecord.read(ref, in: transaction) }, ref: ref), !entry.isRemoved else {
        throw .draftNotFound(chapter)
      }
      let head = try storeCall { () throws(StoreError) in try DraftRecord.history(ref, in: transaction) }.history?.head
      return Source(body: entry.record.content.body, isolated: entry.record.content.isolated, final: false, revision: head)
    } catch {
      throw .domain(error)
    }
  }
}

extension ChapterSummaryError {
  /// `ChapterReviews.isGenerating` throws only a store error or an unavailable activity.
  init(_ error: ChapterReviewError) {
    switch error {
    case .store(let error): self = .store(error)
    case .domain(let error): self = .domain(error)
    default: self = .domain(.lifecycleUnavailable(nil))
    }
  }

  init(_ error: StoreError) {
    guard case .aborted(let cause) = error else {
      self = .store(error)
      return
    }
    switch cause {
    case let cause as ChapterSummaryError: self = cause
    case let cause as DomainError: self = .domain(cause)
    default: self = .store(error)
    }
  }
}
