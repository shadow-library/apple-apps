import Foundation
import MemoirCore
import OSLog
import ShadowAppShell
import ShadowCore
import ShadowStore

/// Closes the owner's ended budget periods and pays the goal milestones savings have reached, for the owner's vault only and only while the app is in
/// the foreground and the vault has Hero and Money on. It runs when the vault opens, on every return to the foreground, when the account's day turns
/// and when Hero and Money come on, which is before any budget edit can be offered for the new day. A run starts scoring money where it never was
/// (`ModuleChanges.startScoring`, D23), then closes each closable period oldest first in a write of its own (`BudgetCloses.close`, which judges the
/// period again as the write reads the vault), then issues every milestone due in one write. Runs are serial: a request during a run makes one more
/// after it, and a run stops before its next write once the app leaves the foreground, leaving the rest to the next. A close another device made first,
/// a period that no longer closes and a replay halt end quietly; a failure is only logged, by its code. Following the vault's changes that ends, as
/// when a read fails, starts again at the next request.
@MainActor
final class BudgetPeriodCloser {
  typealias Triggers = @MainActor (MemoirOpenedVault) -> AsyncThrowingStream<Trigger, any Error>

  nonisolated private static var logger: Logger { Logger(subsystem: AppIdentity.memoir.id, category: "budget-closes") }

  private let triggers: Triggers
  private var opened: MemoirOpenedVault?
  private var isActive = false
  private var following: Task<Void, Never>?
  private var subscription = 0
  private var running: Task<Void, Never>?
  private var runsAgain = false
  /// Runs started since the closer was made.
  private(set) var runs = 0

  init(triggers: @escaping Triggers = BudgetPeriodCloser.triggers) {
    self.triggers = triggers
  }

  /// Whether the vault's changes are being followed.
  var isFollowingChanges: Bool { following != nil }

  func follow(_ opened: MemoirOpenedVault?) {
    let owner = opened.flatMap { $0.isDemo ? nil : $0 }
    if let owner, let current = self.opened, current.stores.main === owner.stores.main { return }
    following?.cancel()
    following = nil
    self.opened = owner
    subscribe()
  }

  @discardableResult
  func phaseChanged(isActive: Bool) -> Task<Void, Never>? {
    let becameActive = isActive && !self.isActive
    self.isActive = isActive
    return becameActive ? request() : nil
  }

  private func subscribe() {
    guard following == nil, let opened else { return }
    subscription += 1
    let current = subscription
    let triggers = triggers(opened)
    following = Task { [weak self] in
      do {
        for try await trigger in triggers where trigger.scores {
          guard let self, !Task.isCancelled else { return }
          self.request()
        }
      } catch {
        guard !Task.isCancelled else { return }
        Self.logger.error("Budget closes stopped following the vault code=\(error.code, privacy: .public)")
      }
      guard let self, !Task.isCancelled, self.subscription == current else { return }
      self.following = nil
    }
  }

  /// Follows nothing and waits for a run under way, as before the vault's files go.
  func stop() async {
    let run = running
    follow(nil)
    await run?.value
  }

  /// One run at a time; a request made while one runs runs once more after it, against the vault followed then. A run for a vault no longer followed
  /// stops after the write under way.
  @discardableResult
  func request() -> Task<Void, Never>? {
    guard opened != nil, isActive else { return nil }
    subscribe()
    if let running {
      runsAgain = true
      return running
    }
    let task = Task {
      repeat {
        runsAgain = false
        if let opened, isActive {
          runs += 1
          await run(opened)
        }
      } while runsAgain
      running = nil
    }
    running = task
    return task
  }

  /// Whether a run for `opened` may write on: the vault is still followed and the app still in the foreground.
  private func goesOn(_ opened: MemoirOpenedVault) -> Bool {
    isActive && self.opened?.stores.main === opened.stores.main
  }

  private func run(_ opened: MemoirOpenedVault) async {
    let context = MemoirScreenContext(opened)
    let writer = context.writer
    do {
      guard try await Self.scores(opened.stores) else { return }
      try await writer.modules.startScoring()
      let today = try await context.today().date
      var closed = 0
      for period in try await BudgetCloseReads.closable(in: opened.stores, today: today, now: opened.clock.now()) {
        guard goesOn(opened) else { return }
        switch try await writer.write({ issuer, transaction in try Self.close(period, issuer: issuer, in: &transaction) }) {
        case .closed?: closed += 1
        case .alreadyClosed?, .notClosable?: continue
        case .replayHalted?:
          Self.logger.notice("Budget closes wait while replay is halted")
          return
        case nil: return
        }
      }
      if closed > 0 { Self.logger.notice("Budget periods closed count=\(closed)") }
      guard goesOn(opened), !(try await GoalMilestones.due(in: opened.stores, today: today)).isEmpty else { return }
      guard goesOn(opened) else { return }
      let issued = try await writer.write { issuer, transaction in try Self.issueMilestones(issuer: issuer, in: &transaction) }
      if issued > 0 { Self.logger.notice("Goal milestones issued count=\(issued)") }
    } catch {
      Self.logger.error("Budget periods could not be closed code=\(error.code, privacy: .public)")
    }
  }

  /// Nil, writing nothing, once the modules no longer score money as the write reads them.
  nonisolated static func close(_ period: ClosablePeriod, issuer: CommandIssuer, in transaction: inout WriteTransaction) throws -> BudgetCloseWrite? {
    guard try scores(transaction) else { return nil }
    return try BudgetCloses.close(period, issuer: issuer, in: &transaction)
  }

  /// None, writing nothing, once the modules no longer score money as the write reads them.
  nonisolated static func issueMilestones(issuer: CommandIssuer, in transaction: inout WriteTransaction) throws -> Int {
    guard try scores(transaction) else { return 0 }
    return try GoalMilestones.issue(issuer: issuer, in: &transaction).count
  }

  nonisolated private static func scores(_ transaction: borrowing WriteTransaction) throws -> Bool {
    scores(try MemoirModules.selection(in: ReadTransaction(database: transaction.database, registry: MemoirSchema.mainRegistry)))
  }

  nonisolated private static func scores(_ stores: MemoirStores) async throws -> Bool {
    try await stores.main.read { transaction in scores(try MemoirModules.selection(in: transaction)) }
  }

  nonisolated private static func scores(_ selection: ModuleSelection) -> Bool {
    selection.contains(.hero) && selection.contains(.money)
  }

  /// The account's day and whether the modules score money, read again after every commit: the day turns' refresh commits, so a new day is seen.
  nonisolated static func triggers(_ opened: MemoirOpenedVault) -> AsyncThrowingStream<Trigger, any Error> {
    let clock = opened.clock
    return opened.stores.main.observeReads { transaction in
      Trigger(day: try clock.today(in: try AccountZone.load(in: transaction)).date, scores: scores(try MemoirModules.selection(in: transaction)))
    }
  }

  nonisolated struct Trigger: Sendable, Equatable {
    let day: LocalDate
    let scores: Bool
  }
}

extension Error {
  nonisolated fileprivate var code: String { (self as? any ShadowError)?.code ?? "unknown" }
}
