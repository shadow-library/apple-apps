import Foundation
import NovelForgeCore
import Observation
import ShadowAppShell
import ShadowCore
import ShadowJobs
import ShadowStore

@MainActor
@Observable
final class SummarizeModel {
  typealias Summarizer = @Sendable (UUID, Int) async throws(ReviewRequestError) -> ChapterSummaryResult

  enum Phase: Equatable {
    case loading
    case ready
    case summarizing
    case saving
    case saved
    case failed(PresentedError)
  }

  enum Notice: Equatable {
    case conflict
    case unsaved
    case savedByModel
  }

  let chapter: Int
  var summary = ""
  private(set) var state: [String: JSONValue]?
  private(set) var source: SummarySource?
  private(set) var phase = Phase.loading
  private(set) var notice: Notice?
  private(set) var failure: PresentedError?
  @ObservationIgnored private let context: NovelContext
  @ObservationIgnored private let summarizer: Summarizer?
  @ObservationIgnored private var stored = ""

  init(context: NovelContext, chapter: Int, summarizer: Summarizer?) {
    self.context = context
    self.chapter = chapter
    self.summarizer = summarizer
  }

  var isBusy: Bool { phase == .summarizing || phase == .saving || phase == .loading }
  var isUnsavedIsolated: Bool { source?.isolated == true && source?.isFinal == false }
  var hasChanges: Bool { summary != stored }
  var canSave: Bool { source != nil && !isBusy && !trimmed.isEmpty && trimmed != stored.trimmingCharacters(in: .whitespacesAndNewlines) }
  var canSummarize: Bool { source?.hasProse == true && !isBusy }
  var stateText: String? {
    guard let state else { return nil }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(state)).flatMap { String(data: $0, encoding: .utf8) }
  }

  private var trimmed: String { summary.trimmingCharacters(in: .whitespacesAndNewlines) }

  func load() async {
    phase = .loading
    do {
      guard let loaded = try await read() else {
        phase = .failed(AmendErrors.presented(.chapterNotFound(chapter)))
        return
      }
      source = loaded
      (summary, stored) = (loaded.summary, loaded.summary)
      phase = .ready
    } catch {
      phase = .failed(PresentedError(error))
    }
  }

  func summarize() async {
    guard canSummarize else { return }
    guard let summarizer else {
      failure = JobsErrors.notRunningHere
      return
    }
    phase = .summarizing
    failure = nil
    notice = nil
    do {
      let result = try await summarizer(context.novel, chapter)
      summary = result.summary
      state = result.state
      if result.saved {
        await refresh()
        notice = .savedByModel
      } else {
        notice = .unsaved
        phase = .ready
      }
    } catch {
      if case .summary(.conflict(_, let attempted)) = error {
        summary = attempted
        notice = .conflict
      } else {
        failure = AmendErrors.presented(error)
      }
      phase = .ready
    }
  }

  func save() async {
    guard canSave, let source else { return }
    phase = .saving
    failure = nil
    let (store, novel, chapter, text) = (context.store, context.novel, chapter, trimmed)
    do {
      try await store.writeDomain { transaction throws(DomainError) in
        try Self.write(text, over: source, novel: novel, chapter: chapter, at: store.wallClock(), in: &transaction)
      }
      phase = .saved
    } catch {
      failure = AmendErrors.presented(error)
      phase = .ready
    }
  }

  nonisolated static func summarizer(_ engine: JobEngine) -> Summarizer {
    { novel, chapter throws(ReviewRequestError) in try await engine.summarize(novel: novel, chapter: chapter) }
  }

  func dismissFailure() { failure = nil }

  private func refresh() async {
    guard let loaded = try? await read() else {
      stored = ""
      phase = .ready
      return
    }
    source = loaded
    stored = loaded.summary
    phase = .ready
  }

  private func read() async throws(StoreError) -> SummarySource? {
    let (novel, chapter) = (context.novel, chapter)
    return try await context.store.read { transaction in
      try SummarySource.load(novel: novel, chapter: chapter, copy: try DraftWorkingCopy.read(novel: novel, chapter: chapter, in: transaction.database), in: transaction)
    }
  }

  nonisolated private static func write(
    _ summary: String, over source: SummarySource, novel: UUID, chapter: Int, at now: Date, in transaction: inout WriteTransaction
  ) throws(DomainError) {
    guard !source.isFinal else { return try FinalChapters.editSummary(novel: novel, chapter: chapter, summary: summary, in: &transaction) }
    let current: SummarySource?
    do throws(StoreError) {
      let copy = try DraftWorkingCopy.read(novel: novel, chapter: chapter, in: transaction.database)
      current = try SummarySource.load(novel: novel, chapter: chapter, copy: copy, in: transaction)
    } catch {
      throw .store(error)
    }
    guard let current, !current.isFinal else { throw .draftNotFound(chapter) }
    let outcome = try ChapterDrafts.save(novel: novel, chapter: chapter, DraftEdit(body: current.body, summary: summary), base: current.revision, at: now, in: &transaction)
    guard case .held = outcome else { return }
    _ = try ChapterDrafts.commitWorkingCopy(novel: novel, chapter: chapter, in: &transaction)
  }
}
