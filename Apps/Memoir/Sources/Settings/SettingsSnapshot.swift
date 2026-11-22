import Foundation
import MemoirCore
import ShadowStore

/// The vault's settings record as Settings finds it: absent until onboarding (or the home currency) creates it.
nonisolated enum AccountStanding: Sendable, Equatable {
  case unset
  case set(AccountSettingsRecord)
  case unreadable

  var record: AccountSettingsRecord? {
    guard case .set(let record) = self else { return nil }
    return record
  }
}

/// `weekStart` 0 is Sunday and anything else Monday, as the core reads it (`QuestReadContext.weekStart`).
nonisolated enum WeekStart: Int, CaseIterable, Sendable {
  case monday = 1
  case sunday = 0

  init(stored: Int) {
    self = stored == 0 ? .sunday : .monday
  }
}

/// What Settings shows, read in one transaction: the settings record, the zone and intensity in force with what is staged for the next day, and the
/// titles the hero holds.
nonisolated struct SettingsSnapshot: Sendable, Equatable {
  let account: AccountStanding
  let zone: AccountZone
  let intensity: IntensityMode
  /// Staged for the next day the walk opens; nil when nothing is staged or the staged mode is the one in force (`pendingValue`,
  /// `synced-account-provider.ts`).
  let pendingIntensity: IntensityMode?
  let titles: [TitleStanding]

  static func load(in transaction: ReadTransaction) throws(StoreError) -> SettingsSnapshot {
    let account: AccountStanding =
      switch try AccountSettingsRecord.read(key: .accountSettings, in: transaction) {
      case .absent: .unset
      case .readable(let entry): .set(entry.record)
      case .unreadable: .unreadable
      }
    let comingBack = try ComingBack.load(ComingBackQuery(), in: transaction)
    let pending = comingBack.pendingIntensityMode.flatMap { $0 == comingBack.intensityMode ? nil : $0 }
    return SettingsSnapshot(
      account: account, zone: try AccountZone.load(in: transaction), intensity: comingBack.intensityMode, pendingIntensity: pending,
      titles: try HeroDeck.load(HeroDeckQuery(), in: transaction).titles)
  }

  /// A zone staged for the next day, unless it is the zone already in force.
  var pendingZone: String? {
    guard let staged = zone.staged, staged.identifier != zone.inForce else { return nil }
    return staged.identifier
  }

  /// The zone the next day will be lived in: the staged one, else the one in force; nil before any zone is set.
  var chosenZone: String? { pendingZone ?? zone.inForce }

  var chosenIntensity: IntensityMode { pendingIntensity ?? intensity }

  var displayedTitle: TitleID? { titles.first(where: \.isDisplayed)?.id }

  var earnedTitles: [TitleStanding] { titles.filter { $0.earnedOn != nil } }
}
