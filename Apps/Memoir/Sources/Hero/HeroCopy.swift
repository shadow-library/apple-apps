import Foundation
import MemoirCore

/// The Hero area's sentences built from the read models, in memoir-web's words (`synced-hero-provider.ts`, `hero.provider.ts`, `labels.ts`).
nonisolated enum HeroCopy {
  static func heroName(_ name: HeroName) -> String {
    switch name {
    case .title(let title): HeroCatalogue.name(of: title)
    case .chooseTitle: String(localized: "Choose a name", table: "Hero")
    case .untitled: String(localized: "New hero", table: "Hero")
    }
  }

  static func subtitle(_ deck: HeroDeck) -> String {
    [
      String(localized: "Level \(deck.level.level)", table: "Hero"), String(localized: "\(deck.activeDays) active days", table: "Hero"),
      String(localized: "\(deck.achievementsEarned) achievements", table: "Hero"),
    ]
    .joined(separator: " · ")
  }

  static func stat(_ stat: StatAffinity) -> String {
    switch stat {
    case .body: String(localized: "Body", table: "Hero")
    case .mind: String(localized: "Mind", table: "Hero")
    case .wealth: String(localized: "Wealth", table: "Hero")
    case .discipline: String(localized: "Discipline", table: "Hero")
    }
  }

  static func statNote(_ stat: StatAffinity) -> String {
    switch stat {
    case .body: String(localized: "Movement, sleep, food, strength", table: "Hero")
    case .mind: String(localized: "Reading, writing, study, focus", table: "Hero")
    case .wealth: String(localized: "Spending, saving, admin", table: "Hero")
    case .discipline: String(localized: "Anchors, tidiness, follow-through", table: "Hero")
    }
  }

  static var noHPYet: String { String(localized: "No HP yet", table: "Hero") }

  /// `hpNoteFor` (`hero.provider.ts:22-26`).
  static func hpNote(_ hp: DayHP?) -> String {
    guard let hp, hp.hpMax > 0 else { return String(localized: "Arrives with your first quest kept.", table: "Hero") }
    return hp.hpEnd >= hp.hpMax ? String(localized: "full", table: "Hero") : String(localized: "Regenerates overnight, on its own.", table: "Hero")
  }

  /// A Returner or Recovery day shows "Returning" whatever the momentum (`synced-hero-provider.ts:282`).
  static func momentum(_ bucket: MomentumBucket?, comingBack: ComingBackReason?) -> String? {
    if comingBack == .returner || comingBack == .recovery { return String(localized: "Returning", table: "Hero") }
    switch bucket {
    case .cold?: return String(localized: "Settling", table: "Hero")
    case .steady?: return String(localized: "Steady", table: "Hero")
    case .warm?: return String(localized: "Warm", table: "Hero")
    case nil: return nil
    }
  }

  static func crownLabel(_ cadence: CrownCadence) -> String {
    switch cadence {
    case .daily: String(localized: "today", table: "Hero")
    case .weekly: String(localized: "this week", table: "Hero")
    }
  }

  static func crownNote(_ crown: CrownWindow) -> String {
    switch crown.cadence {
    case .daily: String(localized: "Closes at the end of today · \(crown.keptPercent)% kept.", table: "Hero")
    case .weekly:
      String(
        localized: "Day \(crown.dayIndex) of \(crown.dayCount) · closes \(HeroDates.text(crown.closesOn, year: false)) · \(crown.keptPercent)% kept.",
        table: "Hero")
    }
  }

  static func crownClose(_ close: CrownClose) -> String {
    let closed = HeroDates.text(close.closedOn, year: false)
    guard close.periodStart != close.closedOn else { return closed }
    return "\(HeroDates.text(close.periodStart, year: false)) – \(closed)"
  }

  static func eventTitle(_ entry: ProgressionEntry) -> String {
    let quest = entry.questName
    switch entry.event.type {
    case .questComplete: return quest.map { String(localized: "\($0) kept", table: "Hero") } ?? String(localized: "A quest kept", table: "Hero")
    case .questPartial: return quest.map { String(localized: "\($0) partly kept", table: "Hero") } ?? String(localized: "A quest partly kept", table: "Hero")
    case .questLate: return quest.map { String(localized: "\($0) kept late", table: "Hero") } ?? String(localized: "A quest kept late", table: "Hero")
    case .recovery: return quest.map { String(localized: "\($0) kept", table: "Hero") } ?? String(localized: "A recovery quest kept", table: "Hero")
    case .levelUp: return String(localized: "Level \(entry.event.levelAfter) reached", table: "Hero")
    case .achievementUnlock:
      return entry.event.achievement.map { String(localized: "\(HeroCatalogue.name(of: $0)) earned", table: "Hero") }
        ?? String(localized: "An achievement earned", table: "Hero")
    case .coinGrant: return String(localized: "Coins granted", table: "Hero")
    case .crownBanked: return String(localized: "Crown banked", table: "Hero")
    case .sideQuest: return String(localized: "Side quest logged", table: "Hero")
    case .journal: return String(localized: "Journal entry written", table: "Hero")
    case .meal: return String(localized: "Meal logged", table: "Hero")
    case .weight: return String(localized: "Weight logged", table: "Hero")
    case .coinSpend: return String(localized: "Cosmetic unlocked", table: "Hero")
    case .recoverySpawned:
      return quest.map { String(localized: "Recovery quest offered for \($0)", table: "Hero") } ?? String(localized: "Recovery quest offered", table: "Hero")
    case .recoveryCompleted: return String(localized: "Recovery quest kept", table: "Hero")
    case .recoveryExpired: return String(localized: "Recovery quest closed unkept", table: "Hero")
    case .crownInit: return String(localized: "Crown period opened", table: "Hero")
    case .crownForfeit: return String(localized: "Crown share lost on \(quest ?? String(localized: "a quest", table: "Hero"))", table: "Hero")
    case .returnerFired: return String(localized: "Welcome back", table: "Hero")
    }
  }

  static func eventMeta(_ event: HeroEvent) -> String? {
    guard let stat = event.statAffinity, event.statDelta > 0 else { return nil }
    return String(localized: "\(self.stat(stat)) +\(event.statDelta)", table: "Hero")
  }

  /// `eventValue` (`synced-hero-provider.ts:190-194`), with coins as a word where the reference draws ◈; nil when the event moved neither.
  static func eventValue(_ event: HeroEvent) -> String? {
    var parts: [String] = []
    if event.xpDelta > 0 { parts.append(String(localized: "+\(event.xpDelta) XP", table: "Hero")) }
    if event.coinsDelta > 0 { parts.append(String(localized: "+\(event.coinsDelta) coins", table: "Hero")) }
    if event.coinsDelta < 0 { parts.append(String(localized: "−\(Int(clamping: event.coinsDelta.magnitude)) coins", table: "Hero")) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  static func coins(_ count: Int) -> String {
    String(localized: "\(count) coins", table: "Hero")
  }

  static func intensity(_ mode: IntensityMode) -> String {
    switch mode {
    case .lowIntensity: String(localized: "Gentle", table: "Hero")
    case .standard: String(localized: "Standard", table: "Hero")
    case .highIntensity: String(localized: "Demanding", table: "Hero")
    }
  }

  static func intensityDescription(_ mode: IntensityMode) -> String {
    switch mode {
    case .lowIntensity: String(localized: "A miss never costs HP, HP refills faster overnight, and the crown is counted over the whole week.", table: "Hero")
    case .standard:
      String(
        localized: "A missed, skipped or postponed anchor or routine quest costs one HP when the day closes, and the crown is counted day by day.", table: "Hero")
    case .highIntensity: String(localized: "Fewer HP that refill more slowly, and the crown counted day by day.", table: "Hero")
    }
  }

  /// `shieldNote` (`synced-hero-provider.ts:203-206`).
  static func shieldNote(_ shields: ShieldStanding) -> String {
    guard shields.cap > 0 else { return String(localized: "None of your quests can hold a shield yet. Quests on a streak earn them as you keep them.", table: "Hero") }
    return String(
      localized:
        "You hold \(shields.available) of \(shields.cap) shields across your quests. A shield keeps a quest’s streak alive through a missed occurrence, and the day is marked shielded in History.",
      table: "Hero")
  }

  static func shields(_ shields: ShieldStanding) -> String {
    String(localized: "\(shields.available) of \(shields.cap)", table: "Hero")
  }
}

/// Calendar days shown in the owner's locale: a `LocalDate` is a civil day with no zone, so it is formatted as midnight UTC in UTC.
nonisolated enum HeroDates {
  static func text(_ day: LocalDate, year: Bool = true) -> String {
    guard let date = date(day) else { return day.isoString }
    let style = year ? Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt) : Date.FormatStyle(timeZone: .gmt).day().month(.abbreviated)
    return date.formatted(style)
  }

  /// `formatRelativeDay`: today and yesterday by name, other days by date.
  static func relative(_ day: LocalDate, today: LocalDate?) -> String {
    guard let today else { return text(day, year: false) }
    switch today.days(since: day) {
    case 0: return String(localized: "Today", table: "Hero")
    case 1: return String(localized: "Yesterday", table: "Hero")
    default: return text(day, year: day.year != today.year)
    }
  }

  private static func date(_ day: LocalDate) -> Date? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    return calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day))
  }
}
