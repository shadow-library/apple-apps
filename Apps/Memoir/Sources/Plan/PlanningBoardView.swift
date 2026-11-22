import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// `features/planning/index.tsx`: the week or month as planned, its locks and loads, the Crown, the reschedule budget and the plan lock of today.
struct PlanningBoardView: View {
  @State private var model: PlanBoardModel

  init(context: MemoirScreenContext) {
    _model = State(initialValue: PlanBoardModel(context: context))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        Text("Design the week rather than react to it. Every move here obeys the same rules the day does.", tableName: "Plan")
          .shadowFont(.subheadline)
          .foregroundStyle(ShadowColor.textSecondary)
        controls
        lockControl
        if let failure = model.failure {
          ShadowCallout(Text("The plan wasn’t changed", tableName: "Plan"), message: failure.text, intent: .danger)
        }
        content
      }
      .padding(Spacing.space4)
    }
    .navigationTitle(Text("Planning Board", tableName: "Plan"))
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        NavigationLink(value: MemoirRoute.destination(.weeklyReview)) { Text("Weekly review", tableName: "Plan") }.shadowBarItem()
      }
    }
    .shadowScreen(.root)
    .task { await model.followToday() }
    .task(id: model.query) { await model.observe() }
  }

  private var controls: some View {
    @Bindable var model = model
    return ShadowFlowLayout {
      Picker(selection: $model.scope) {
        Text("Week", tableName: "Plan").tag(PlanPeriod.week)
        Text("Month", tableName: "Plan").tag(PlanPeriod.month)
      } label: {
        Text("Period", tableName: "Plan")
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      HStack(spacing: Spacing.space2) {
        Button {
          model.step(-1)
        } label: {
          Label(title: { Text("Previous period", tableName: "Plan") }, icon: { Image(systemName: "chevron.left") }).labelStyle(.iconOnly)
        }
        .keyboardShortcut(.leftArrow, modifiers: .command)
        periodLabel.shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary).monospacedDigit()
        Button {
          model.step(1)
        } label: {
          Label(title: { Text("Next period", tableName: "Plan") }, icon: { Image(systemName: "chevron.right") }).labelStyle(.iconOnly)
        }
        .keyboardShortcut(.rightArrow, modifiers: .command)
        Button {
          model.showToday()
        } label: {
          Text("Today", tableName: "Plan")
        }
        .keyboardShortcut("t", modifiers: .command)
      }
      .buttonStyle(.shadowPlain)
    }
  }

  @ViewBuilder
  private var periodLabel: some View {
    if let board = model.snapshot.state.value?.board {
      switch board.scope {
      case .week:
        Text(QuestCalendar.date(board.from)..<QuestCalendar.date(board.through), format: .interval.day().month(.abbreviated).year())
      case .month:
        Text(QuestCalendar.date(board.from), format: .dateTime.month(.wide).year())
      }
    } else {
      Text(verbatim: " ")
    }
  }

  @ViewBuilder
  private var lockControl: some View {
    switch model.lockControl {
    case .hidden:
      EmptyView()
    case .notThisWeek:
      Text("Only today’s plan can be locked.", tableName: "Plan").shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
    case .lock(let quests, let availability, let capacity):
      VStack(alignment: .leading, spacing: Spacing.space1) {
        lockButton(Text("Lock today’s plan", tableName: "Plan"), availability: availability)
        if case .unavailable(let block) = availability, let reason = QuestsCopy.block(block) {
          Text(verbatim: reason).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
        } else if let capacity, capacity.warning != .none {
          Text("Today’s plan has \(quests.count) quests; your recent days hold about \(capacity.capacity.capacity).", tableName: "Plan")
            .shadowFont(.footnote).foregroundStyle(ShadowColor.warningText)
        }
      }
    case .unlock(let availability):
      lockButton(Text("Unlock today’s plan", tableName: "Plan"), availability: availability)
    }
  }

  private func lockButton(_ title: Text, availability: ActionAvailability) -> some View {
    Button {
      Task { await model.toggleLock() }
    } label: {
      title
    }
    .buttonStyle(.shadowBordered)
    .disabled(availability != .available || model.isLocking)
  }

  @ViewBuilder
  private var content: some View {
    switch model.snapshot.state {
    case .loading:
      if let failure = model.dayFailure {
        ShadowContentUnavailable(Text("The plan couldn’t be loaded", tableName: "Plan"), kind: .error, message: failure.text)
      } else {
        ProgressView().frame(maxWidth: .infinity)
      }
    case .failed(let error):
      ShadowContentUnavailable(Text("The plan couldn’t be loaded", tableName: "Plan"), kind: .error, message: error.text)
    case .loaded(let snapshot) where snapshot.isEmpty:
      ShadowContentUnavailable(
        Text("Nothing planned yet", tableName: "Plan"), systemImage: MemoirDestination.planningBoard.systemImage,
        message: Text("Create your first quest and it will show up here.", tableName: "Plan")
      ) {
        NavigationLink(value: MemoirRoute.quest(.new)) { Text("New quest", tableName: "Plan") }.buttonStyle(.shadowFilled)
      }
    case .loaded(let snapshot):
      board(snapshot.board)
    }
  }

  @ViewBuilder
  private func board(_ board: PlanBoard) -> some View {
    if let carryOver = board.carryOver { carryOverCallout(carryOver) }
    if let month = board.month {
      PlanMonthGrid(cells: month, weekStart: board.weekStart) { model.showWeek(of: $0) }
    } else {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Spacing.space3, alignment: .top)], spacing: Spacing.space3) {
        ForEach(board.days) { PlanDayCard(day: $0) }
      }
    }
    ShadowAdaptiveColumns(maxColumns: 3, minColumnWidth: 220) {
      if let crown = board.crown { crownCard(crown) }
      rescheduleCard(board.busiestReschedule)
      glanceCard(board)
    }
  }

  /// `carryOver` (`fixture-provider.ts:446-466`).
  private func carryOverCallout(_ carryOver: CarryOver) -> some View {
    let name = QuestsCopy.name(carryOver.name)
    let title =
      carryOver.missed == 1
      ? Text("Yesterday left one commitment open", tableName: "Plan") : Text("Yesterday left \(carryOver.missed) commitments open", tableName: "Plan")
    let message =
      carryOver.streakEnded
      ? Text(
        "\(name) was scheduled and not completed. Its best run, \(carryOver.longestDays) days, stays in History. Review the quest, or leave it.", tableName: "Plan")
      : Text("\(name) was scheduled and not completed. The record stays in History. Review the quest, or leave it.", tableName: "Plan")
    return ShadowCallout(title, message: message, intent: .warning) {
      NavigationLink(value: MemoirRoute.quest(.detail(carryOver.quest))) { Text("Review the quest", tableName: "Plan") }.buttonStyle(.shadowBordered)
    }
  }

  /// `crownSummary` (`features/planning/index.tsx:238-242`).
  private func crownCard(_ crown: CrownWindow) -> some View {
    let kept = (Double(crown.keptPercent) / 100).formatted(.percent.precision(.fractionLength(0)))
    let label = crown.cadence == .daily ? String(localized: "today", table: "Plan") : String(localized: "this week", table: "Plan")
    return ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        Text("Current crown · \(label)", tableName: "Plan").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
        ProgressView(value: Double(crown.keptPercent), total: 100)
          .progressViewStyle(.shadowLinear)
          .accessibilityLabel(Text("Crown \(label): \(kept) kept", tableName: "Plan"))
        Group {
          switch crown.cadence {
          case .daily:
            Text("\(kept) of the crown kept so far. Today’s crown is banked when the day closes.", tableName: "Plan")
          case .weekly:
            Text(
              "Day \(crown.dayIndex) of \(crown.dayCount) · \(kept) of the crown kept so far. This week’s crown is banked when the week closes on \(QuestsCopy.shortDate(crown.closesOn)).",
              tableName: "Plan")
          }
        }
        .shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
    }
  }

  /// `rescheduleSummary` (`features/planning/index.tsx:244-248`).
  private func rescheduleCard(_ busiest: BusiestReschedule?) -> some View {
    let cap = busiest?.budget.cap ?? RescheduleBudget.cap
    let rule = String(
      localized: "Each quest can move \(cap) times in any 7 days. Past the cap, moves still happen — they are recorded as postpones with a reason instead.", table: "Plan")
    return ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        Text("Reschedule budget", tableName: "Plan").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
        HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
          Text(verbatim: "\(busiest?.budget.used ?? 0) / \(cap)").shadowFont(.title2).monospacedDigit().foregroundStyle(ShadowColor.textPrimary)
          Text("used in the last 7 days", tableName: "Plan").shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
        }
        Group {
          if let busiest {
            Text("Most moved: \(QuestsCopy.name(busiest.name)). \(rule)", tableName: "Plan")
          } else {
            Text("No quest has moved in the last 7 days. \(rule)", tableName: "Plan")
          }
        }
        .shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
    }
  }

  /// `glance` (`fixture-provider.ts:493-505`).
  private func glanceCard(_ board: PlanBoard) -> some View {
    let glance = board.glance
    return ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space2) {
        Group {
          switch board.scope {
          case .week: Text("At a glance · this week", tableName: "Plan")
          case .month: Text("At a glance · \(QuestCalendar.date(board.from).formatted(.dateTime.month(.wide).year()))", tableName: "Plan")
          }
        }
        .shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
        Group {
          Text("\(glance.scheduled) occurrences scheduled · \(glance.completed) kept so far", tableName: "Plan")
          if let heaviest = glance.heaviestDay { Text("Heaviest day \(QuestsCopy.shortDate(heaviest))", tableName: "Plan") }
          if let hp = glance.hp, let hpMax = glance.hpMax { Text("HP \(hp) of \(hpMax) now", tableName: "Plan") }
          Text("\(glance.shields.available) shields held now", tableName: "Plan")
        }
        .shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
    }
  }
}

/// `PlanDayCard` (`features/planning/index.tsx:273-298`, `fixture-provider.ts:523-556`).
private struct PlanDayCard: View {
  let day: PlanDay

  var body: some View {
    let scheduled = day.occurrences.filter(\.isScheduled)
    ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space2) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 0) {
            Text(QuestCalendar.date(day.date), format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
              .shadowFont(.headline)
              .foregroundStyle(day.relation == .today ? ShadowColor.accentText : ShadowColor.textPrimary)
            loadSummary.shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
          }
          Spacer()
          if day.lock == .active { ShadowBadge(Text("locked", tableName: "Plan"), intent: .info, systemImage: "lock") }
        }
        QuestLoadBar(minutes: day.load.minutes)
        ForEach(scheduled) { occurrence in
          NavigationLink(value: MemoirRoute.quest(.detail(occurrence.quest.id))) {
            VStack(alignment: .leading, spacing: 0) {
              Text(verbatim: QuestsCopy.name(occurrence.quest.name)).shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
              Text(verbatim: Self.meta(occurrence)).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Spacing.space2)
            .overlay(alignment: .leading) { Rectangle().fill(PlanTone(occurrence.effectiveState).color).frame(width: Spacing.space05) }
            .contentShape(Rectangle())
          }
          .buttonStyle(.shadowRow)
        }
        if let note = day.lockNote {
          Group {
            switch note {
            case .wasLocked: Text("This day was locked.", tableName: "Plan")
            case .locked: Text("Locked. Moves past the reschedule cap are recorded as postpones with a reason.", tableName: "Plan")
            }
          }
          .shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
        }
      }
    }
    .overlay {
      if day.relation == .today {
        RoundedRectangle(cornerRadius: ShadowCardMetrics().cornerRadius, style: .continuous).strokeBorder(ShadowColor.accent)
      }
    }
  }

  private var loadSummary: Text {
    let duration = QuestsCopy.duration(day.load.minutes)
    return day.load.isOverCapacity
      ? Text("\(day.load.occurrences) quests · about \(duration) · over capacity", tableName: "Plan")
      : Text("\(day.load.occurrences) quests · about \(duration)", tableName: "Plan")
  }

  static func meta(_ occurrence: BoardOccurrence) -> String {
    let state = occurrence.effectiveState.map { QuestsCopy.state($0).localizedLowercase }
    var meta = [QuestsCopy.time(occurrence.quest.startMinute), state].compactMap(\.self).joined(separator: " · ")
    if meta.isEmpty { meta = String(localized: "all day", table: "Plan") }
    guard occurrence.log?.shielded == true else { return meta }
    return String(localized: "\(meta) · shield spent", table: "Plan")
  }
}

/// The month grid (`features/planning/index.tsx:250-271`): each day's scheduled outcomes as dots; a day opens its week.
private struct PlanMonthGrid: View {
  let cells: [PlanMonthCell]
  let weekStart: LocalDate.Weekday
  let open: (LocalDate) -> Void

  var body: some View {
    ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.space1), count: 7), spacing: Spacing.space1) {
          ForEach(QuestCalendar.week(from: weekStart), id: \.self) { day in
            Text(verbatim: QuestsCopy.weekday(day)).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
          }
          ForEach(cells) { cell in
            if cell.isInMonth {
              Button {
                open(cell.date)
              } label: {
                PlanMonthCellView(cell: cell)
              }
              .buttonStyle(.plain)
              .accessibilityLabel(label(cell))
            } else {
              Color.clear.frame(minHeight: Spacing.space10).accessibilityHidden(true)
            }
          }
        }
        ShadowFlowLayout {
          legend(.kept, Text("kept", tableName: "Plan"))
          legend(.partial, Text("partial", tableName: "Plan"))
          legend(.closed, Text("skipped or missed", tableName: "Plan"))
          legend(.open, Text("still open", tableName: "Plan"))
        }
        .shadowFont(.caption)
        .foregroundStyle(ShadowColor.textSecondary)
      }
    }
  }

  private func legend(_ tone: PlanTone, _ title: Text) -> some View {
    HStack(spacing: Spacing.space1) {
      Circle().fill(tone.color).frame(width: Spacing.space2, height: Spacing.space2)
      title
    }
  }

  /// `monthCellLabel` (`features/planning/index.tsx:236-239`).
  private func label(_ cell: PlanMonthCell) -> Text {
    let date = QuestsCopy.shortDate(cell.date)
    return cell.lock == .active
      ? Text("\(date), locked, \(cell.outcomes.count) occurrences", tableName: "Plan")
      : Text("\(date), not locked, \(cell.outcomes.count) occurrences", tableName: "Plan")
  }
}

private struct PlanMonthCellView: View {
  let cell: PlanMonthCell

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      HStack(spacing: Spacing.space1) {
        Text(cell.date.day, format: .number).shadowFont(.caption).monospacedDigit()
          .foregroundStyle(cell.relation == .today ? ShadowColor.accentText : ShadowColor.textPrimary)
        if cell.lock == .active { Image(systemName: "lock.fill").shadowFont(.caption2).foregroundStyle(ShadowColor.textSecondary) }
      }
      ShadowFlowLayout(spacing: Spacing.space05) {
        ForEach(Array(cell.outcomes.enumerated()), id: \.offset) { _, state in
          Circle().fill(PlanTone(state).color).frame(width: Spacing.space1 + Spacing.space05, height: Spacing.space1 + Spacing.space05)
        }
      }
    }
    .frame(maxWidth: .infinity, minHeight: Spacing.space10, alignment: .topLeading)
    .padding(Spacing.space1)
    .background(cell.relation == .today ? ShadowColor.accentSoft : ShadowColor.surfaceWell, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .contentShape(Rectangle())
  }
}

/// `outcomeTone` (`quest-presenters.ts:62-67`) over the board's state, where an occurrence still open has none.
private enum PlanTone {
  case kept
  case partial
  case open
  case closed

  init(_ state: QuestLogState?) {
    switch state {
    case .completed: self = .kept
    case .partial, .recovery, .late: self = .partial
    case .rescheduled, nil: self = .open
    case .skipped, .missed, .postponed: self = .closed
    }
  }

  var color: Color {
    switch self {
    case .kept: ShadowColor.successSolid
    case .partial: ShadowColor.warningSolid
    case .open: ShadowColor.infoSolid
    case .closed: ShadowColor.neutralSolid
    }
  }
}

#Preview {
  if let context = try? MemoirScreenContext.inMemory() {
    NavigationStack {
      PlanningBoardView(context: context)
    }
  }
}
