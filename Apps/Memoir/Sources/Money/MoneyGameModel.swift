import Foundation
import MemoirCore
import Observation
import ShadowAppShell
import ShadowCore
import ShadowStore

/// Money in the game as Today, Money and Hero show it, read in one transaction: replay's standing, the deposit record of each recent close (the money
/// truth, which replay does not hold), Home's current period for its danger badge, and the account's day the labels count from.
nonisolated struct MoneyGameSnapshot: Sendable, Equatable {
  let today: LocalDate
  let standing: MoneyGameStanding
  let deposits: [MoneyCloseKey: SavingsDeposit]
  let home: BudgetPeriodStanding?

  static func load(in transaction: ReadTransaction, clock: MemoirClock) throws -> MoneyGameSnapshot {
    let today = try clock.today(in: try AccountZone.load(in: transaction)).date
    let standing = try MoneyGameStanding.load(MoneyGameQuery(), in: transaction)
    var deposits = [MoneyCloseKey: SavingsDeposit]()
    for close in standing.recentCloses {
      let key = MemoirKey.savingsDeposit(budget: close.key.budget, periodStart: close.key.periodStart)
      if let deposit = try SavingsDepositRecord.read(key: key, in: transaction).entry?.record.deposit { deposits[close.key] = deposit }
    }
    let home = try BudgetStandings.make(try BudgetBook.load(from: transaction), today: today)?.homeBudget
    return MoneyGameSnapshot(today: today, standing: standing, deposits: deposits, home: home)
  }

  /// Whether the money streak means anything yet: nothing shows it before the first money command taken under money rules.
  var hasActivity: Bool { standing.lastActivityDay != nil }

  /// Home's period while it is at risk or over, for its badge; nil while it is on track or has no limit.
  var homeInDanger: BudgetPeriodStanding? {
    guard let home else { return nil }
    switch home.pace {
    case .atRisk, .over: return home
    case .onTrack, .noLimit: return nil
    }
  }

  /// The account's open day when "No spend" may be logged for it.
  var noSpendToday: MoneyLogDay? {
    standing.today.flatMap { $0.noSpend == .available ? $0 : nil }
  }

  /// The earlier days of the late window that "No spend" may still cover.
  var noSpendBackFill: [MoneyLogDay] {
    standing.backFill.filter { $0.noSpend == .available }
  }
}

/// The closes whose result the owner has seen on this device, by budget and period. A close replay supersedes by an earlier one keeps its key, so it is
/// never shown twice; the demo keeps its own in the demo's suite.
struct MoneyCloseAcknowledgements {
  static let key = "\(AppIdentity.memoir.id).money.seen-closes"
  static let limit = 64

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var closes: Set<MoneyCloseKey> {
    Set((defaults.stringArray(forKey: Self.key) ?? []).compactMap(Self.close(from:)))
  }

  func acknowledge(_ closes: some Sequence<MoneyCloseKey>) {
    var stored = defaults.stringArray(forKey: Self.key) ?? []
    for close in closes.map(Self.text(of:)) where !stored.contains(close) { stored.append(close) }
    defaults.set(Array(stored.suffix(Self.limit)), forKey: Self.key)
  }

  private static func text(of close: MoneyCloseKey) -> String {
    "\(close.budget.uuidString)|\(close.periodStart.isoString)"
  }

  private static func close(from text: String) -> MoneyCloseKey? {
    let parts = text.split(separator: "|")
    guard parts.count == 2, let budget = UUID(uuidString: String(parts[0])), let start = LocalDate(isoString: String(parts[1])) else { return nil }
    return MoneyCloseKey(budget: budget, periodStart: start)
  }
}

/// What logging "No spend" for a day came to.
enum NoSpendOutcome: Equatable {
  case logged
  /// The standing no longer offers the day, as the write read it.
  case unavailable(ActionBlock)
  case failed(PresentedError)
  case cancelled
}

/// Money in the game for one screen: the snapshot, the closes not yet seen here, and "No spend" for a day of the logging window. The standing's own
/// availability decides whether a day may be logged, read again inside the write so a second window or device that covered it meanwhile is respected.
@MainActor
@Observable
final class MoneyGameModel {
  let game = ReadObserver<MoneyGameSnapshot>()
  private(set) var acknowledged: Set<MoneyCloseKey>
  private(set) var logging: LocalDate?
  var problem: String?

  @ObservationIgnored let context: MemoirScreenContext
  @ObservationIgnored private let acknowledgements: MoneyCloseAcknowledgements

  init(context: MemoirScreenContext, acknowledgements: MoneyCloseAcknowledgements? = nil) {
    let acknowledgements = acknowledgements ?? MoneyCloseAcknowledgements(defaults: context.defaults)
    self.context = context
    self.acknowledgements = acknowledgements
    acknowledged = acknowledgements.closes
  }

  var snapshot: MoneyGameSnapshot? { game.state.value }

  /// Reads the closes seen again with every snapshot, so one dismissed in another window goes here too.
  func run() async {
    let main = context.stores.main
    let clock = context.clock
    await game.run(
      { main.observeReads { transaction in try MoneyGameSnapshot.load(in: transaction, clock: clock) } },
      onValue: { [weak self] _ in self?.readAcknowledged() })
  }

  private func readAcknowledged() {
    let seen = acknowledgements.closes
    if seen != acknowledged { acknowledged = seen }
  }

  /// Newest first.
  var newCloses: [MoneyCloseSummary] {
    snapshot?.standing.recentCloses.filter { !acknowledged.contains($0.key) } ?? []
  }

  func acknowledgeCloses() {
    let closes = newCloses.map(\.key)
    acknowledgements.acknowledge(closes)
    acknowledged.formUnion(closes)
  }

  @discardableResult
  func logNoSpend(on date: LocalDate) async -> NoSpendOutcome {
    guard logging == nil else { return .cancelled }
    logging = date
    problem = nil
    defer { logging = nil }
    let outcome: NoSpendOutcome
    do {
      let registry = context.stores.main.registry
      let block = try await context.writer.write { issuer, transaction -> ActionBlock? in
        let standing = try MoneyGameStanding.load(MoneyGameQuery(), in: ReadTransaction(database: transaction.database, registry: registry))
        switch standing.noSpend(on: date) {
        case .available:
          _ = try issuer.issue(.moneyNoSpend(NoSpendDay(date: date)), in: &transaction)
          return nil
        case .unavailable(let block): return block
        case .availableUntil, .needsConfirmation: return .loggingWindowClosed
        }
      }
      outcome = block.map(NoSpendOutcome.unavailable) ?? .logged
    } catch {
      outcome = WritingErrors.presented(error).map(NoSpendOutcome.failed) ?? .cancelled
    }
    problem = MoneyGameCopy.problem(outcome)
    return outcome
  }
}
