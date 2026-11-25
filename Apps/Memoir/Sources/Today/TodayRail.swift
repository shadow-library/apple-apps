import MemoirCore
import ShadowDesignSystem
import SwiftUI

struct TodayUpcomingEntry: Hashable, Identifiable {
  let id: String
  let when: String
  let title: String
  let meta: String
}

extension TodaySnapshot {
  static let upcomingLimit = 4
  static let laterTodayLimit = 2

  /// `upcoming` (`fixture-provider.ts:398-414`): today's open quests with a time, the first of tomorrow's, and the Crown's close.
  var upcoming: [TodayUpcomingEntry] {
    let today = board.date
    let later = board.occurrences.filter { ($0.status == .open || $0.status == .recorded(.rescheduled)) && $0.plannedMinute != nil }
      .sorted { ($0.plannedMinute ?? 0) < ($1.plannedMinute ?? 0) }
      .prefix(Self.laterTodayLimit)
      .map { occurrence in
        TodayUpcomingEntry(
          id: "\(occurrence.quest.id)-today", when: occurrence.plannedMinute.map(TodayFormat.time(minuteOfDay:)) ?? "", title: QuestActionCopy.name(occurrence.quest),
          meta: Self.laterMeta(occurrence))
      }
    let next = tomorrow.map { occurrence in
      TodayUpcomingEntry(
        id: "\(occurrence.quest.id)-next", when: TodayFormat.relativeDay(occurrence.occurrence.date, from: today), title: QuestActionCopy.name(occurrence.quest),
        meta: occurrence.quest.startMinute.map(TodayFormat.time(minuteOfDay:)) ?? String(localized: "all day", table: "Today"))
    }
    var crown = [TodayUpcomingEntry]()
    if hasActiveQuests, let window = board.summary?.crown {
      crown.append(
        TodayUpcomingEntry(
          id: "crown", when: TodayFormat.relativeDay(window.closesOn, from: today), title: String(localized: "Crown closes", table: "Today"),
          meta: String(localized: "\(window.keptPercent)% kept so far", table: "Today")))
    }
    return Array((later + next + crown).prefix(Self.upcomingLimit))
  }

  private static func laterMeta(_ occurrence: BoardOccurrence) -> String {
    if case .recorded(.rescheduled) = occurrence.status {
      guard let start = occurrence.quest.startMinute else { return String(localized: "Today · moved", table: "Today") }
      return String(localized: "Today · moved from \(TodayFormat.time(minuteOfDay: start))", table: "Today")
    }
    return occurrence.locked ? String(localized: "Today · locked plan", table: "Today") : String(localized: "Today", table: "Today")
  }
}

/// `features/today/day-rail.tsx`, the streaks and what comes next; quick logs and recent activity belong to the Log and History screens.
struct TodayRail: View {
  let snapshot: TodaySnapshot

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space4) {
      streaks
      upcoming
    }
  }

  private var streaks: some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      HStack {
        Text("Streaks", tableName: "Today").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary).accessibilityAddTraits(.isHeader)
        Spacer()
        ModuleLink(MemoirRoute.destination(.insights)) { Text("All", tableName: "Today") }.buttonStyle(.shadowPlain)
      }
      if snapshot.streaks.entries.isEmpty {
        Text("No streaks yet. One starts the first day you keep a quest.", tableName: "Today").todayNote()
      } else {
        ForEach(snapshot.streaks.entries) { entry in
          TodayStreakRow(entry: entry, today: snapshot.streaks.date)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .shadowCard()
  }

  private var upcoming: some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      Text("Coming up", tableName: "Today").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary).accessibilityAddTraits(.isHeader)
      let entries = snapshot.upcoming
      if entries.isEmpty {
        Text("Nothing else is scheduled yet.", tableName: "Today").todayNote()
      } else {
        ForEach(entries) { entry in
          HStack(alignment: .firstTextBaseline, spacing: Spacing.space3) {
            Text(verbatim: entry.when).shadowFont(.footnote).monospacedDigit().foregroundStyle(ShadowColor.textSecondary)
            VStack(alignment: .leading, spacing: Spacing.space05) {
              Text(verbatim: entry.title).shadowFont(.body).foregroundStyle(ShadowColor.textPrimary).lineLimit(1)
              Text(verbatim: entry.meta).todayNote()
            }
          }
          .accessibilityElement(children: .combine)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .shadowCard()
  }
}

struct TodayStreakRow: View {
  let entry: StreakBoardEntry
  let today: LocalDate

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      HStack {
        Text(verbatim: entry.name ?? String(localized: "Unnamed quest", table: "Today")).shadowFont(.body).foregroundStyle(ShadowColor.textPrimary).lineLimit(1)
        Spacer(minLength: Spacing.space2)
        Text(verbatim: label).shadowFont(.footnote).monospacedDigit().foregroundStyle(ShadowColor.textSecondary)
      }
      HStack(spacing: Spacing.space1) {
        ForEach(entry.week, id: \.date) { day in
          RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(color(day)).frame(height: Spacing.space2)
        }
      }
      .accessibilityHidden(true)
      if let note { Text(verbatim: note).todayNote() }
    }
    .accessibilityElement(children: .combine)
  }

  /// `streakLabel` (`fixture-provider.ts:361-364`).
  private var label: String {
    switch entry.streak.standing {
    case .running(let days): String(localized: "\(days) d", table: "Today")
    case .ended(let longest): String(localized: "ended at \(longest)", table: "Today")
    case .notStarted: String(localized: "not started", table: "Today")
    }
  }

  /// `streakEndNote` (`fixture-provider.ts:367-376`) with `closedAgo` (`:150-155`).
  private var note: String? {
    guard entry.showsEnd else { return nil }
    guard let ended = entry.endedOn else { return String(localized: "The record stays.", table: "Today") }
    let days = today.days(since: ended)
    let closed =
      switch days {
      case ...0: String(localized: "Closed today", table: "Today")
      case 1: String(localized: "Closed yesterday", table: "Today")
      default: String(localized: "Closed \(days) days ago", table: "Today")
      }
    return String(localized: "\(closed). The record stays.", table: "Today")
  }

  private func color(_ day: StreakBoardDay) -> Color {
    guard day.isScheduled else { return ShadowColor.fillTrack }
    switch TodayTone(day.state) {
    case .kept: return ShadowColor.successSolid
    case .partial: return ShadowColor.accent
    case .open: return ShadowColor.borderDefault
    case .closed: return ShadowColor.neutralSolid
    }
  }
}

extension View {
  func todayNote() -> some View {
    shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary).fixedSize(horizontal: false, vertical: true)
  }
}
