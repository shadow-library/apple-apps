import Foundation
import ShadowStore

/// Everything a reminder plan reads, from the main store only (the projection's quest and log rows, the quest and subscription records, the settings and
/// the confirm-cycle commands), so no health- or activity-class value can reach a reminder. It holds no instant: the plan applies `now` to it.
public struct ReminderSources: Sendable, Equatable {
  /// The reference stores the lead in a `smallint` (`quests.reminder_lead_min`, at least zero).
  static let maximumLeadMinutes = Int(Int16.max)
  /// Logs from two days before the open day on: a reminder's occurrence is no earlier than the day before the clock's today, which a backward zone change
  /// leaves at most a day behind the open day.
  static let logLookbackDays = 2

  struct Quest: Sendable, Equatable {
    let id: UUID
    let name: String
    let leadMinutes: Int
    let schedule: QuestSchedule

    init(id: UUID, name: String, leadMinutes: Int, schedule: QuestSchedule) {
      self.id = id
      self.name = name
      self.leadMinutes = min(max(leadMinutes, 0), ReminderSources.maximumLeadMinutes)
      self.schedule = schedule
    }
  }

  struct Logged: Sendable, Equatable {
    let state: QuestLogState
    let rescheduledToMinute: Int?
  }

  struct Subscription: Sendable, Equatable {
    let id: UUID
    let name: String
    let amount: MoneyAmount
    let nextDue: LocalDate
    let lead: SubscriptionReminderLead
  }

  struct Confirmed: Sendable, Equatable {
    let cycle: CycleConfirmation
    let issuedOn: LocalDate
  }

  let zone: AccountZone
  let wakeWindow: ScheduleWindow
  let quests: [Quest]
  /// Deleted or paused quests whose record still asks for a reminder, so a reminder they had shown can be withdrawn.
  let inactiveQuests: [Quest]
  let logs: [Occurrence: Logged]
  let subscriptions: [Subscription]
  /// The open cycles of the subscriptions that ask for a reminder while the Money module is off, so a reminder they had shown can be withdrawn.
  let pausedSubscriptions: [Subscription]
  /// The confirmations of the reminded subscriptions' cycles, with the day each was issued on.
  let confirmations: [Confirmed]
  let halt: ReplayHalt?

  /// A settings record this version cannot read leaves the standard wake window and every module on, and a failed subscription read leaves only the quest
  /// reminders. Quests are reminded only with the Quests module and subscriptions only with the Money module; without its module every reminded quest or
  /// subscription counts as paused, so the reminders it had shown are withdrawn.
  public static func load(in transaction: ReadTransaction) throws(MemoirReadError) -> ReminderSources {
    do throws(StoreError) {
      let hero = try MemoirDerived.hero(in: transaction)
      let settings = try AccountSettingsRecord.read(key: .accountSettings, in: transaction).entry?.record
      let modules = ModuleSelection(settings: settings)
      var (quests, inactive) = try reminded(MemoirDerived.quests(in: transaction), in: transaction)
      if !modules.contains(.quests) {
        inactive = (quests + inactive).sorted { $0.id.uuidString < $1.id.uuidString }
        quests = []
      }
      var (subscriptions, confirmations) = subscriptions(in: transaction)
      var paused = [Subscription]()
      if !modules.contains(.money) {
        paused = subscriptions
        (subscriptions, confirmations) = ([], [])
      }
      return ReminderSources(
        zone: hero?.zone ?? .unset, wakeWindow: settings?.schedule ?? .standard, quests: quests, inactiveQuests: inactive,
        logs: try logs(of: Set(quests.map(\.id)), from: hero?.openDay, in: transaction), subscriptions: subscriptions, pausedSubscriptions: paused, confirmations: confirmations,
        halt: hero?.halt)
    } catch {
      throw MemoirReadError(error)
    }
  }

  /// Quests that keep occurrences (not Recovery) and whose record asks for a reminder, active and inactive apart; a quest whose record is missing or
  /// unreadable has none.
  private static func reminded(_ rows: [QuestRow], in transaction: ReadTransaction) throws(StoreError) -> (active: [Quest], inactive: [Quest]) {
    var records = [UUID: QuestRecord]()
    for entry in try QuestRecord.listing(in: transaction).entries where !entry.isRemoved { records[entry.record.id] = entry.record }
    let quests = rows.compactMap { row -> (quest: Quest, active: Bool)? in
      guard let record = records[row.id], record.reminderEnabled, row.schedule.strictness != .recovery else { return nil }
      return (Quest(id: row.id, name: record.name, leadMinutes: record.reminderLeadMinutes, schedule: row.schedule), row.schedule.active)
    }.sorted { $0.quest.id.uuidString < $1.quest.id.uuidString }
    return (quests.filter(\.active).map(\.quest), quests.filter { !$0.active }.map(\.quest))
  }

  private static func logs(of quests: Set<UUID>, from openDay: LocalDate?, in transaction: ReadTransaction) throws(StoreError) -> [Occurrence: Logged] {
    guard !quests.isEmpty else { return [:] }
    let start = openDay.flatMap { $0.adding(days: -logLookbackDays) } ?? .earliest
    var logs = [Occurrence: Logged]()
    for row in try MemoirDerived.questLogs(from: start, through: .latest, in: transaction) where quests.contains(row.occurrence.quest) {
      logs[row.occurrence] = Logged(state: row.entry.state, rescheduledToMinute: row.entry.rescheduledToMinute)
    }
    return logs
  }

  /// The open cycle of each active subscription with a reminder on and a lead this version knows, as `SubscriptionStanding.reminderOn` reads it; a
  /// subscription whose terms this version cannot read has none. Only the open cycle is reminded: the next one opens when the owner confirms this one.
  /// The commands are decoded for their confirmations only when some subscription asks for a reminder.
  private static func subscriptions(in transaction: ReadTransaction) -> (subscriptions: [Subscription], confirmations: [Confirmed]) {
    let candidates: [(SubscriptionRecord, SubscriptionReminderLead)]
    let confirmations: [Confirmed]
    do throws(StoreError) {
      candidates = try ReadSources.listing(SubscriptionRecord.self, in: transaction).records.compactMap { subscription in
        guard subscription.active, subscription.reminderEnabled, let lead = subscription.reminderLead.known else { return nil }
        return (subscription, lead)
      }
      guard !candidates.isEmpty else { return ([], []) }
      confirmations = try ReadSources.commands(in: transaction).commands.compactMap { command, body in
        guard case .subscriptionConfirmCycle(let confirmation) = body else { return nil }
        return Confirmed(cycle: confirmation, issuedOn: command.issuedOn)
      }
    } catch {
      return ([], [])
    }
    let reminded = candidates.compactMap { subscription, lead -> Subscription? in
      guard let schedule = try? SubscriptionSchedule(subscription: subscription, confirmations: confirmations.map(\.cycle)) else { return nil }
      return Subscription(
        id: subscription.id, name: subscription.name, amount: MoneyAmount(amountMinor: subscription.amountMinor, currency: subscription.currency),
        nextDue: schedule.nextDue, lead: lead)
    }.sorted { $0.id.uuidString < $1.id.uuidString }
    let ids = Set(reminded.map(\.id))
    return (reminded, confirmations.filter { ids.contains($0.cycle.subscription) })
  }
}
