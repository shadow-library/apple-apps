import Foundation
import ShadowStore

/// The Reflect surfaces: history, insight statistics and the weekly review. Quest outcomes, unlocks and the hero come from the replay projection
/// (`MemoirDerived`), never from running replay. `bodyClasses` names the classes whose stores are read for weight and metrics (`.activity`, `.health`);
/// each is read only from its own store, and an empty set reads neither.
public enum ReflectReads {
  public static func history(in stores: MemoirStores, matching query: HistoryQuery, bodyClasses: Set<SyncClass>, today: LocalDate) async throws(MemoirReadError)
    -> HistoryPage
  {
    let (general, body) = try await load(stores, bodyClasses: bodyClasses) { transaction in try ReflectGeneral.load(today: today, in: transaction) }
    return try finance { () throws(FinanceError) in try HistoryPage.make(general, body: body, query: query) }
  }

  public static func observeHistory(in stores: MemoirStores, matching query: HistoryQuery, bodyClasses: Set<SyncClass>, today: LocalDate)
    -> AsyncThrowingStream<HistoryPage, any Error>
  {
    observe(
      stores, bodyClasses: bodyClasses, main: { transaction in try ReflectGeneral.load(today: today, in: transaction) },
      build: { general, body in
        try finance { () throws(FinanceError) in try HistoryPage.make(general, body: body, query: query) }
      })
  }

  public static func insights(in stores: MemoirStores, period: InsightPeriod, bodyClasses: Set<SyncClass>, today: LocalDate) async throws(MemoirReadError)
    -> InsightStatistics
  {
    let (general, body) = try await load(stores, bodyClasses: bodyClasses) { transaction in try ReflectGeneral.load(today: today, in: transaction) }
    return try finance { () throws(FinanceError) in try InsightStatistics.make(general, body: body, period: period, today: today) }
  }

  public static func observeInsights(in stores: MemoirStores, period: InsightPeriod, bodyClasses: Set<SyncClass>, today: LocalDate)
    -> AsyncThrowingStream<InsightStatistics, any Error>
  {
    observe(
      stores, bodyClasses: bodyClasses, main: { transaction in try ReflectGeneral.load(today: today, in: transaction) },
      build: { general, body in
        try finance { () throws(FinanceError) in try InsightStatistics.make(general, body: body, period: period, today: today) }
      })
  }

  public static func review(in stores: MemoirStores, bodyClasses: Set<SyncClass>, today: LocalDate) async throws(MemoirReadError) -> WeeklyReview {
    let (main, body) = try await load(stores, bodyClasses: bodyClasses) { transaction in try ReviewMain.load(today: today, in: transaction) }
    return try finance { () throws(FinanceError) in try WeeklyReview.make(main.general, body: body, answers: main.answers, today: today) }
  }

  public static func observeReview(in stores: MemoirStores, bodyClasses: Set<SyncClass>, today: LocalDate) -> AsyncThrowingStream<WeeklyReview, any Error> {
    observe(
      stores, bodyClasses: bodyClasses, main: { transaction in try ReviewMain.load(today: today, in: transaction) },
      build: { main, body in
        try finance { () throws(FinanceError) in try WeeklyReview.make(main.general, body: body, answers: main.answers, today: today) }
      })
  }

  private struct ReviewMain: Sendable, Equatable {
    let general: ReflectGeneral
    let answers: ReviewAnswers

    static func load(today: LocalDate, in transaction: ReadTransaction) throws -> ReviewMain {
      guard let week = WeeklyReview.weekUnderReview(today: today) else { throw MemoirReadError.finance(.dateOutOfRange) }
      return ReviewMain(general: try ReflectGeneral.load(today: today, in: transaction), answers: try WeeklyReviewAnswers.answers(week: week.start, in: transaction))
    }
  }

  private static func load<Main: Sendable>(
    _ stores: MemoirStores, bodyClasses: Set<SyncClass>, _ main: @escaping @Sendable (ReadTransaction) throws -> Main
  ) async throws(MemoirReadError) -> (Main, ReflectBodySource) {
    let general = try await readCall { () async throws(StoreError) in try await stores.main.read(main) }
    var body = ReflectBodySource.none
    if bodyClasses.contains(.activity) {
      body = body.merged(with: try await readCall { () async throws(StoreError) in try await stores.activity.read { try ReflectBodySource.activity(in: $0) } })
    }
    if bodyClasses.contains(.health) {
      body = body.merged(with: try await readCall { () async throws(StoreError) in try await stores.restricted.read { try ReflectBodySource.health(in: $0) } })
    }
    return (general, body)
  }

  private static func observe<Main: Sendable & Equatable, Output: Sendable & Equatable>(
    _ stores: MemoirStores, bodyClasses: Set<SyncClass>, main: @escaping @Sendable (ReadTransaction) throws -> Main,
    build: @escaping @Sendable (Main, ReflectBodySource) throws -> Output
  ) -> AsyncThrowingStream<Output, any Error> {
    let general = ObservedRead(stores.main, main)
    let activity = ObservedRead(stores.activity) { try ReflectBodySource.activity(in: $0) }
    let health = ObservedRead(stores.restricted) { try ReflectBodySource.health(in: $0) }
    switch (bodyClasses.contains(.activity), bodyClasses.contains(.health)) {
    case (true, true): return ReadObservation.observe(general, activity, health) { try build($0, $1.merged(with: $2)) }
    case (true, false): return ReadObservation.observe(general, activity) { try build($0, $1) }
    case (false, true): return ReadObservation.observe(general, health) { try build($0, $1) }
    case (false, false): return ReadObservation.observe(general) { try build($0, .none) }
    }
  }

  private static func finance<Value>(_ body: () throws(FinanceError) -> Value) throws(MemoirReadError) -> Value {
    do throws(FinanceError) {
      return try body()
    } catch {
      throw .finance(error)
    }
  }
}
