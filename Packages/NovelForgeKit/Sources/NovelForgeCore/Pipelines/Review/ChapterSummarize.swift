import Foundation
import ShadowAI
import ShadowCore
import ShadowStore

extension JobEngine {
  /// apps/novel-forge-server/src/modules/generation/generation.service.ts:768-799: a helper call outside any job, through the engine's routers and the novel's
  /// live hard line. An isolated chapter that is not final gets its summary and state back unsaved; every other summary is saved over the prose it read.
  public func summarize(novel: UUID, chapter: Int, pace: Pace? = nil) async throws(ReviewRequestError) -> ChapterSummaryResult {
    let now = services.now()
    let (source, plan, novelPace): (ChapterSummary.Source, ChapterPlanContent?, Pace)
    do {
      (source, plan, novelPace) = try await store.summaryRead { transaction throws(ChapterSummaryError) in
        let source = try ChapterSummary.source(novel: novel, chapter: chapter, at: now, in: transaction)
        do throws(ChapterReviewError) {
          let costTier = try ChapterReviews.stored { () throws(StoreError) in try NovelRecord.read(id: novel, in: transaction) }.entry?.record.costTier.known
          return (source, try ChapterReviews.plan(novel: novel, chapter: chapter, in: transaction), costTier?.pace ?? .steady)
        } catch {
          throw ChapterSummaryError(error)
        }
      }
    } catch {
      throw .summary(error)
    }
    let route: ChapterCallRoute
    do {
      route = try ChapterCallRouter.route(
        ChapterCallSource(novel: novel, chapter: chapter, role: .summary, plan: plan, isolated: source.isolated), unrestrictedAvailable: services.unrestrictedAvailable)
    } catch {
      throw .route(code: error.code, description: error.errorDescription)
    }
    let request = chapterSummarizeRequest(chapterProse: source.body)
    let result: StructuredResult
    do {
      result = try await services.call(
        route, pace: pace ?? novelPace, screening: OrderedJSONObject([("chapterProse", .string(source.body))]),
        request: { call in request.modelRequest(model: call.route.model, maxOutputTokens: call.route.maxOutputTokens, effort: call.route.effort) },
        name: chapterSummarizeSchemaName, schema: JSONValue(schema: chapterSummarizeSchema))
    } catch {
      throw .model(code: error.code, description: error.errorDescription)
    }
    guard let parsed = try? CanonicalJSON.decode(result.json), let summary = parsed["summary"]?.stringValue, let state = parsed["state"]?.objectValue else {
      throw .model(code: "structured.decoding", description: "The summary could not be read.")
    }
    if source.isolated, !source.final { return ChapterSummaryResult(summary: summary, state: state, saved: false, revision: nil) }
    do {
      let revision = try await store.summaryWrite { transaction throws(ChapterSummaryError) in
        try ChapterSummary.save(summary, novel: novel, chapter: chapter, over: source, in: &transaction)
      }
      return ChapterSummaryResult(summary: summary, state: state, saved: true, revision: revision)
    } catch {
      throw .summary(error)
    }
  }
}

extension VaultStore {
  func summaryRead<T: Sendable>(_ body: @Sendable (ReadTransaction) throws(ChapterSummaryError) -> T) async throws(ChapterSummaryError) -> T {
    do {
      return try await read { transaction in try body(transaction) }
    } catch {
      throw ChapterSummaryError(error)
    }
  }

  func summaryWrite<T: Sendable>(_ body: @Sendable (inout WriteTransaction) throws(ChapterSummaryError) -> T) async throws(ChapterSummaryError) -> T {
    do {
      return try await write { transaction in try body(&transaction) }
    } catch {
      throw ChapterSummaryError(error)
    }
  }
}
