import Foundation
import ShadowStore

public enum ReminderReads {
  public static func plan(in stores: MemoirStores, query: ReminderQuery, now: Date) async throws(MemoirReadError) -> ReminderPlan {
    ReminderPlan.make(try await sources(in: stores), query: query, now: now)
  }

  public static func sources(in stores: MemoirStores) async throws(MemoirReadError) -> ReminderSources {
    try await readCall { () async throws(StoreError) in try await stores.main.read { transaction in try ReminderSources.load(in: transaction) } }
  }

  /// Emits the plan, then again whenever a commit changes it (a command or record written here or merged from another device) and at its `changesAt`,
  /// when a reminder has fired or the day has turned. A plan equal to the last one is not emitted again.
  public static func observePlan(
    in stores: MemoirStores, query: ReminderQuery, now: @escaping @Sendable () -> Date = { Date() },
    waitUntil: @escaping @Sendable (Date) async throws -> Void = ProjectionDayTurns.sleep(until:)
  ) -> AsyncThrowingStream<ReminderPlan, any Error> {
    let reads = stores.main.observeReads { transaction in try ReminderSources.load(in: transaction) }
    let (stream, continuation) = AsyncThrowingStream<ReminderPlan, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let task = Task {
      let (events, sink) = AsyncStream<PlanEvent>.makeStream()
      let reader = Task {
        do {
          for try await sources in reads { sink.yield(.sources(sources)) }
          sink.yield(.finished)
        } catch {
          sink.yield(.failed(error))
        }
      }
      var timer: Task<Void, Never>?
      defer {
        reader.cancel()
        timer?.cancel()
      }
      var latest: ReminderSources?
      var last: ReminderPlan?
      for await event in events {
        switch event {
        case .sources(let sources): latest = sources
        case .tick: break
        case .failed(let error):
          continuation.finish(throwing: MemoirReadError(observed: error))
          return
        case .finished:
          continuation.finish()
          return
        }
        guard let latest else { continue }
        let plan = ReminderPlan.make(latest, query: query, now: now())
        timer?.cancel()
        if plan != last { continuation.yield(plan) }
        last = plan
        let changesAt = plan.changesAt
        timer = Task {
          guard (try? await waitUntil(changesAt)) != nil, !Task.isCancelled else { return }
          sink.yield(.tick)
        }
      }
      continuation.finish()
    }
    continuation.onTermination = { @Sendable _ in task.cancel() }
    return stream
  }
}

private enum PlanEvent: Sendable {
  case sources(ReminderSources)
  case tick
  case failed(any Error)
  case finished
}
