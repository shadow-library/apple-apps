import Foundation
import ShadowStore

public struct ComingBackQuery: Sendable, Hashable {
  public init() {}
}

/// A quest's misses in the week before the open day, oldest first (`lib/sync/projection.ts:983-1001`).
public struct RecentMisses: Sendable, Hashable, Identifiable {
  public static let windowDays = 7

  public let quest: UUID
  public let name: String?
  public let misses: [Miss]

  public var id: UUID { quest }
  public var allShielded: Bool { misses.allSatisfy(\.shielded) }

  public struct Miss: Sendable, Hashable {
    public let date: LocalDate
    public let shielded: Bool
  }
}

/// The choices the screen offers for the reason (`synced-hero-provider.ts:90-138`); the words are the app's.
public enum ComingBackChoice: String, Sendable, Hashable {
  case keepOneQuestToday
  case keepRecoveryQuest
  case keepComebackQuest
  case reviewWeek
}

/// The Returner ritual of the open day: how long the absence was and where its shield went.
public struct ReturnerStanding: Sendable, Hashable {
  public let lastActiveDate: LocalDate
  public let daysAbsent: Int
  public let shieldTarget: UUID?
  public let shieldTargetName: String?
  public let shieldPending: Bool
}

/// "Coming back": why the open day frames a return, what was missed in the week before, the Comeback and Returner, the shields, the open choices and the
/// intensity in force and staged.
public struct ComingBack: ReplayReadModel {
  public let openDay: LocalDate?
  public let reason: ComingBackReason?
  /// The Comeback was armed today and its bonus already claimed (`synced-hero-provider.ts:161-165`).
  public let comebackClaimed: Bool
  public let choices: [ComingBackChoice]
  /// Latest miss first.
  public let recentlyMissed: [RecentMisses]
  public let comeback: ComebackStanding?
  public let returner: ReturnerStanding?
  public let recovery: RecoveryOffer?
  /// Returner shields waiting for the next quest created.
  public let pendingReturnerShields: Int
  public let shields: ShieldStanding
  public let hp: DayHP?
  public let crown: CrownWindow?
  public let intensityMode: IntensityMode
  /// Staged for the next day the walk opens, so never shown as already in force.
  public let pendingIntensityMode: IntensityMode?
  public let returnerThresholdDays: Int
  public let lastActiveDate: LocalDate?
  public let changesOn: LocalDate?

  public static func load(_: ComingBackQuery, in transaction: ReadTransaction) throws(StoreError) -> ComingBack {
    let context = try QuestReadContext.load(in: transaction)
    let ruleset = context.ruleset
    let row = context.openDayRow
    guard let day = context.openDay else {
      return ComingBack(
        openDay: nil, reason: nil, comebackClaimed: false, choices: [], recentlyMissed: [], comeback: nil, returner: nil, recovery: nil, pendingReturnerShields: 0,
        shields: ShieldStanding(context.quests, ruleset: ruleset), hp: nil, crown: nil, intensityMode: .standard, pendingIntensityMode: nil,
        returnerThresholdDays: ruleset.returnerThreshold(nil), lastActiveDate: nil, changesOn: nil)
    }
    let recoveryRow = try MemoirDerived.recoveries(from: day, through: day, in: transaction).first
    let reason = ComingBackReason.on(row, recovery: recoveryRow)
    let claimed = reason == .comeback && row?.comebackArmed == false
    let returner = try MemoirDerived.returners(from: day, through: day, in: transaction).first.map { row in
      ReturnerStanding(
        lastActiveDate: row.event.lastActiveDate, daysAbsent: row.event.daysAbsent, shieldTarget: row.event.shieldTarget,
        shieldTargetName: row.event.shieldTarget.flatMap { context.records[$0]?.name }, shieldPending: row.event.shieldPending)
    }
    return ComingBack(
      openDay: day, reason: reason, comebackClaimed: claimed, choices: choices(for: reason, claimed: claimed),
      recentlyMissed: try missed(before: day, context: context, in: transaction), comeback: row.map { ComebackStanding($0, ruleset: ruleset) }, returner: returner,
      recovery: recoveryRow.map { TodayBoard.offer($0.recovery, relation: .today, context: context) },
      pendingReturnerShields: context.hero?.pendingReturnerShields ?? 0, shields: ShieldStanding(context.quests, ruleset: ruleset), hp: row?.hp,
      crown: try CrownWindow.load(containing: day, row: row, ruleset: ruleset, in: transaction), intensityMode: row?.intensityMode ?? .standard,
      pendingIntensityMode: context.hero?.pendingIntensityMode, returnerThresholdDays: ruleset.returnerThreshold(context.hero?.returnerThresholdDays),
      lastActiveDate: context.hero?.lastActiveDate, changesOn: context.changesOn)
  }

  static func choices(for reason: ComingBackReason?, claimed: Bool) -> [ComingBackChoice] {
    switch reason {
    case nil: []
    case .returner?: [.keepOneQuestToday, .reviewWeek]
    case .recovery?: [.keepRecoveryQuest, .reviewWeek]
    case .comeback?: claimed ? [.reviewWeek] : [.keepComebackQuest, .reviewWeek]
    }
  }

  private static func missed(before day: LocalDate, context: QuestReadContext, in transaction: ReadTransaction) throws(StoreError) -> [RecentMisses] {
    let logs = try MemoirDerived.questLogs(from: day.movedBy(days: -RecentMisses.windowDays), through: day.movedBy(days: -1), in: transaction)
    let byQuest = Dictionary(grouping: logs.filter { $0.entry.state == .missed }, by: \.occurrence.quest)
    return byQuest.map { quest, rows in
      RecentMisses(
        quest: quest, name: context.records[quest]?.name,
        misses: rows.sorted { $0.occurrence.date < $1.occurrence.date }.map { RecentMisses.Miss(date: $0.occurrence.date, shielded: $0.shielded) })
    }.sorted { lhs, rhs in
      let left = lhs.misses.last?.date ?? .earliest
      let right = rhs.misses.last?.date ?? .earliest
      return left != right ? left > right : UUID.precedes(lhs.quest, rhs.quest)
    }
  }
}
