import Foundation
import MemoirCore
import Observation
import ShadowAppShell
import ShadowStore

@MainActor
@Observable
final class TodayViewModel: QuestActionHosting {
  let context: MemoirScreenContext
  let actions: QuestActionsModel
  private let observer = ReadObserver<TodaySnapshot>()

  init(context: MemoirScreenContext) {
    self.context = context
    actions = QuestActionsModel(writer: context.writer)
  }

  var state: Loadable<TodaySnapshot> { observer.state }
  var snapshot: TodaySnapshot? { state.value }

  /// Runs for as long as the screen is shown; a day turn's refresh commits, so the snapshot moves to the new day.
  func observe() async {
    let clock = context.clock
    let main = context.stores.main
    await observer.run { main.observeReads { transaction in try TodaySnapshot.load(in: transaction, clock: clock) } }
  }

  func occurrence(_ id: Occurrence) -> BoardOccurrence? {
    snapshot?.occurrence(id)
  }

  func perform(_ request: QuestActionRequest) async -> QuestActionOutcome {
    await actions.perform(request, on: occurrence(request.occurrence), at: moment())
  }

  func existingReason(of occurrence: BoardOccurrence) async -> QuestActionReason {
    await actions.existingReason(of: occurrence)
  }

  /// The account's day and minute now, with that day's lock when the board shows the account's open day.
  func moment() -> QuestActionMoment? {
    guard let snapshot, let minute = minuteOfDay() else { return nil }
    return QuestActionMoment(date: snapshot.today.date, minuteOfDay: minute, lock: snapshot.board.date == snapshot.today.date ? snapshot.board.lock : nil)
  }

  func completeRecovery(reflection: String) async -> QuestActionOutcome {
    await actions.completeRecovery(snapshot?.board.recovery, reflection: reflection)
  }

  var nowMillis: Int64 { MemoirClock.millis(context.clock.now()) }

  func minutesUntilSleep() -> Int? {
    snapshot?.minutesUntilSleep(at: nowMillis, deviceZone: context.clock.deviceZone())
  }

  /// The account's minute now, for refusing a reschedule to a time already past.
  func minuteOfDay() -> Int? {
    snapshot?.minuteOfDay(at: nowMillis, deviceZone: context.clock.deviceZone())
  }

  /// The account's clock zone, for showing an instant such as a Recovery quest's expiry.
  func timeZone() -> TimeZone {
    guard let snapshot else { return context.clock.deviceZone() }
    return snapshot.zone.resolve(at: nowMillis, device: context.clock.deviceZone()).clock.timeZone
  }
}
