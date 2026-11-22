import Foundation
import MemoirCore
import ShadowAppShell
import ShadowStore
import ShadowSyncRuntime
import Synchronization
import Testing

@testable import Memoir

@MainActor
@Suite("QuestBuilderModel", TestTimeLimit.standard)
struct QuestBuilderModelTests {
  private static func ready(_ mode: QuestBuilderMode, in context: MemoirScreenContext) async throws -> QuestBuilderModel {
    let model = QuestBuilderModel(mode: mode, context: context)
    await model.load()
    #expect(model.phase == .ready)
    return model
  }

  @Test("should create the record and quest.create in one write, with the form's schedule from today")
  func createsAQuest() async throws {
    let context = try QuestsTesting.context()
    let model = try await Self.ready(.create, in: context)
    model.form.name = "  Read 20 pages "
    model.form.strictness = .anchor
    model.form.startMinute = 7 * 60
    model.form.reminderEnabled = true
    model.form.reminderLeadMinutes = 15

    let id = try #require(await model.save())

    let bodies = try await QuestsTesting.bodies(in: context)
    guard bodies.count == 1, case .questCreate(let creation) = bodies[0] else {
      Issue.record("expected one quest.create, got \(bodies)")
      return
    }
    #expect(creation.questId == id)
    #expect(creation.schedule.strictness == .anchor && creation.schedule.startTimeMinutes == 420 && creation.schedule.durationMinutes == 25)
    #expect(creation.schedule.statAffinity == .mind && !creation.schedule.optionalStreakOptIn)
    #expect(creation.schedule.recurrence == (try RecurrenceRule(frequency: .weekly(QuestForm.standardWeekdays), startDate: TestClock.day0)))
    #expect(try await QuestsTesting.record(id, in: context) == QuestRecord(id: id, name: "Read 20 pages", reminderEnabled: true, reminderLeadMinutes: 15))
  }

  nonisolated enum Invalid: CaseIterable, Sendable {
    case blankName
    case anchorWithoutTime
    case noWeekdays
    case longDuration
    case longInterval

    var issue: QuestFormIssue {
      switch self {
      case .blankName: .draft(.nameRequired)
      case .anchorWithoutTime: .draft(.anchorNeedsStartTime)
      case .noWeekdays: .noWeekdays
      case .longDuration: .draft(.durationOutOfRange(241))
      case .longInterval: .draft(.intervalOutOfRange(31))
      }
    }

    func apply(to form: inout QuestForm) {
      switch self {
      case .blankName: form.name = " "
      case .anchorWithoutTime: form.strictness = .anchor
      case .noWeekdays: form.weekdays = []
      case .longDuration: form.durationMinutes = 241
      case .longInterval:
        form.repeats = .everyNDays
        form.interval = 31
      }
    }
  }

  @Test("should block saving with the typed issues and write nothing", arguments: Invalid.allCases)
  func blocksInvalidDrafts(_ invalid: Invalid) async throws {
    let context = try QuestsTesting.context()
    let model = try await Self.ready(.create, in: context)
    model.form.name = "Walk"
    invalid.apply(to: &model.form)

    #expect(await model.save() == nil)

    #expect(model.issues == [invalid.issue])
    #expect(!model.canSave)
    #expect(model.failure == nil)
    #expect(try await QuestsTesting.bodies(in: context).isEmpty)
    #expect(try await context.stores.quests().isEmpty)
  }

  @Test("should follow the draft in the week preview without writing")
  func previewsTheDraft() async throws {
    let context = try QuestsTesting.context()
    try await QuestsTesting.quest("Walk", duration: 30, in: context)
    let model = try await Self.ready(.create, in: context)
    model.form.name = "Read"
    model.form.repeats = .everyNDays
    model.form.interval = 1
    model.form.durationMinutes = 40

    try await QuestsObservation { await model.observePreview() }.during {
      try await TestClock.until("the preview loads") { model.isPreviewCurrent }
    }
    #expect(model.preview?.days.map(\.minutes) == Array(repeating: 70, count: 7))
    #expect(model.preview?.dailyCadence == 7)
    #expect(model.canSave)

    model.form.durationMinutes = 200
    #expect(!model.isPreviewCurrent, "a changed draft is not saved against the old preview")
    try await QuestsObservation { await model.observePreview() }.during {
      try await TestClock.until("the preview follows") { model.isPreviewCurrent }
    }
    #expect(model.preview?.days.first?.minutes == 230)
    #expect(model.preview?.overload?.minutes == 230)
    #expect(try await QuestsTesting.bodies(in: context).count == 1, "only the existing quest's create")
  }

  @Test("should edit the record and issue quest.update for the schedule in one write")
  func editsAQuest() async throws {
    let context = try QuestsTesting.context()
    let id = try await QuestsTesting.quest("Walk", in: context)
    let model = try await Self.ready(.edit(id), in: context)
    #expect(model.issues == [.unchanged], "nothing has changed yet")
    #expect(model.form.name == "Walk" && model.form.repeats == .everyNDays && model.form.interval == 1)

    model.form.name = "Long walk"
    model.form.durationMinutes = 45
    model.form.strictness = .goal
    #expect(await model.save() == id)

    let bodies = try await QuestsTesting.bodies(in: context)
    let expected = try QuestSchedulePatch(strictness: .goal, durationMinutes: 45, optionalStreakOptIn: false)
    #expect(bodies.last == .questUpdate(QuestUpdate(questId: id, patch: expected)))
    #expect(try await QuestsTesting.record(id, in: context)?.name == "Long walk")
  }

  @Test("should rename without a command when only the words change")
  func renamesWithoutACommand() async throws {
    let context = try QuestsTesting.context()
    let id = try await QuestsTesting.quest("Walk", in: context)
    let model = try await Self.ready(.edit(id), in: context)
    model.form.name = "Evening walk"

    #expect(await model.save() == id)

    #expect(try await QuestsTesting.bodies(in: context).count == 1)
    #expect(try await QuestsTesting.record(id, in: context)?.name == "Evening walk")
  }

  @Test("should hold the schedule while today's plan is locked and still save the other fields")
  func holdsALockedSchedule() async throws {
    let context = try QuestsTesting.context()
    let id = try await QuestsTesting.quest("Walk", in: context)
    try await context.writer.issue(.planSetLock(try PlanLock(locking: [id])))
    let model = try await Self.ready(.edit(id), in: context)
    #expect(model.scheduleEdit == .unavailable(.lockedInTodaysPlan))

    model.form.strictness = .goal
    model.form.startMinute = nil
    #expect(model.values.strictness == .routine && model.values.startMinute == 480)
    #expect(model.issues == [.unchanged], "the locked fields are not a change")
    model.form.durationMinutes = 20
    #expect(await model.save() == id)

    let expected = try QuestSchedulePatch(durationMinutes: 20)
    #expect(try await QuestsTesting.bodies(in: context).last == .questUpdate(QuestUpdate(questId: id, patch: expected)))
  }

  @Test("should prefill a duplicate and create it as a new quest, leaving the original alone")
  func duplicatesAQuest() async throws {
    let context = try QuestsTesting.context()
    let original = try await QuestsTesting.quest("Walk", strictness: .anchor, start: 360, duration: 15, in: context)
    let model = try await Self.ready(.duplicate(original), in: context)
    #expect(!model.isEditing)
    #expect(model.form.name == "Walk" && model.form.strictness == .anchor && model.form.startMinute == 360 && model.form.durationMinutes == 15)
    #expect(model.form.repeats == .everyNDays && model.form.interval == 1)

    let copy = try #require(await model.save())

    #expect(copy != original)
    let quests = try await context.stores.quests()
    #expect(Set(quests.map(\.id)) == [original, copy])
    #expect(quests.allSatisfy { $0.name == "Walk" })
    guard case .questCreate(let creation) = try await QuestsTesting.bodies(in: context).last else {
      Issue.record("expected quest.create")
      return
    }
    #expect(creation.questId == copy && creation.schedule.startTimeMinutes == 360)
  }

  @Test("should fall back to the builder's defaults for what a duplicate cannot carry")
  func duplicatesWithinTheBuilder() async throws {
    let context = try QuestsTesting.context()
    let original = try await QuestsTesting.quest("Rest", strictness: .recovery, duration: 300, frequency: .monthly(.dayOfMonth(2)), in: context)
    let model = try await Self.ready(.duplicate(original), in: context)

    #expect(model.form.strictness == .routine)
    #expect(model.form.durationMinutes == QuestForm.standardDuration)
    #expect(model.form.repeats == .weekly && model.form.weekdays == QuestForm.standardWeekdays)
  }

  @Test("should keep a monthly schedule an edit cannot write")
  func keepsAFixedRecurrence() async throws {
    let context = try QuestsTesting.context()
    let id = try await QuestsTesting.quest("Pay rent", frequency: .monthly(.dayOfMonth(2)), in: context)
    let model = try await Self.ready(.edit(id), in: context)
    #expect(model.fixedRecurrence != nil)

    model.form.repeats = .weekly
    model.form.weekdays = []
    model.form.durationMinutes = 10
    #expect(!model.issues.contains(.noWeekdays))
    #expect(await model.save() == id)

    let expected = try QuestSchedulePatch(durationMinutes: 10)
    #expect(try await QuestsTesting.bodies(in: context).last == .questUpdate(QuestUpdate(questId: id, patch: expected)))
  }

  @Test("should set the builder's threshold in the activity store and clear it on edit, never in a command")
  func setsAndClearsTheThreshold() async throws {
    let context = try QuestsTesting.context()
    let model = try await Self.ready(.create, in: context)
    model.form.name = "Walk"
    model.form.threshold = true

    let id = try #require(await model.save())
    #expect(try await QuestThresholdReader.load(id, in: context.stores) == QuestThresholdSummary.standard)
    #expect(try await context.stores.activity.read { transaction in try QuestThresholdRecord<ActivityMetric>.read(id: id, in: transaction).entry } != nil)

    let edit = try await Self.ready(.edit(id), in: context)
    #expect(edit.form.threshold)
    edit.form.threshold = false
    #expect(await edit.save() == id)
    #expect(try await QuestThresholdReader.load(id, in: context.stores) == nil)
    #expect(try await QuestsTesting.bodies(in: context).count == 1, "the threshold is not a schedule change")
  }

  @Test("should hold the schedule when today's plan is locked after the builder opened")
  func holdsAScheduleLockedSinceOpening() async throws {
    let context = try QuestsTesting.context()
    let id = try await QuestsTesting.quest("Walk", in: context)
    let model = try await Self.ready(.edit(id), in: context)
    #expect(model.scheduleEdit == .available)
    model.form.strictness = .goal
    model.form.durationMinutes = 20

    try await context.writer.issue(.planSetLock(try PlanLock(locking: [id])))
    #expect(await model.save() == id)

    #expect(model.scheduleEdit == .unavailable(.lockedInTodaysPlan))
    let expected = try QuestSchedulePatch(durationMinutes: 20)
    #expect(try await QuestsTesting.bodies(in: context).last == .questUpdate(QuestUpdate(questId: id, patch: expected)))
  }

  @Test("should say the quest was created when its threshold was not, and add the threshold when saved again")
  func recoversAFailedThreshold() async throws {
    struct Refused: Error {}
    let context = try QuestsTesting.context()
    let stores = context.stores
    let attempts = Mutex(0)
    let writer = QuestThresholdWriter(
      set: { threshold in
        let attempt = attempts.withLock { count in
          count += 1
          return count
        }
        if attempt == 1 { throw Refused() }
        try await QuestThresholds.set(threshold, in: stores)
      }, clear: { _ in })
    let model = QuestBuilderModel(mode: .create, context: context, thresholds: writer)
    await model.load()
    model.form.name = "Walk"
    model.form.threshold = true

    #expect(await model.save() == nil)

    #expect(model.isThresholdPending)
    #expect(model.failure != nil)
    let id = try #require(try await context.stores.quests().first?.id)
    #expect(model.mode == .edit(id))
    #expect(model.form.threshold && model.issues.isEmpty, "the threshold is still to be added")

    #expect(await model.save() == id)
    #expect(!model.isThresholdPending)
    #expect(try await QuestThresholdReader.load(id, in: stores) == QuestThresholdSummary.standard)
    #expect(try await QuestsTesting.bodies(in: context).count == 1, "the quest was created once")
  }

  @Test("should turn the reminder on when a new quest gets a time, at ten minutes before")
  func remindsATimedNewQuest() async throws {
    let context = try QuestsTesting.context()
    let model = try await Self.ready(.create, in: context)
    model.form.name = "Walk"
    model.form.setStartMinute(420)
    #expect(model.form.reminderEnabled)

    let id = try #require(await model.save())

    #expect(try await QuestsTesting.record(id, in: context) == QuestRecord(id: id, name: "Walk", reminderEnabled: true, reminderLeadMinutes: 10))
  }

  @Test("should turn the reminder on when an edit adds a time, and off when it clears it")
  func remindsWhenATimeIsAdded() async throws {
    let context = try QuestsTesting.context()
    let id = try await QuestsTesting.quest("Read", start: nil, in: context)
    let model = try await Self.ready(.edit(id), in: context)
    #expect(!model.form.reminderEnabled)

    model.form.setStartMinute(600)
    #expect(await model.save() == id)
    #expect(try await QuestsTesting.record(id, in: context)?.reminderEnabled == true)

    let again = try await Self.ready(.edit(id), in: context)
    again.form.setStartMinute(630)
    #expect(again.form.reminderEnabled, "moving a time keeps the reminder")
    again.form.setStartMinute(nil)
    #expect(await again.save() == id)
    #expect(try await QuestsTesting.record(id, in: context)?.reminderEnabled == false)
  }

  @Test("should say a threshold may live on another device only while a class store does not sync here")
  func knowsWhereAThresholdLives() {
    let both: Set<SyncStoreRoute> = [MemoirSyncRoutes.activity, MemoirSyncRoutes.health]
    #expect(!QuestThresholdReader.mayLiveElsewhere(isSyncing: false, syncingRoutes: []))
    #expect(!QuestThresholdReader.mayLiveElsewhere(isSyncing: true, syncingRoutes: both))
    #expect(QuestThresholdReader.mayLiveElsewhere(isSyncing: true, syncingRoutes: [MemoirSyncRoutes.health]))
    #expect(QuestThresholdReader.mayLiveElsewhere(isSyncing: true, syncingRoutes: []))
  }

  @Test("should say a quest to edit is missing")
  func reportsAMissingQuest() async throws {
    let context = try QuestsTesting.context()
    let model = QuestBuilderModel(mode: .edit(UUID()), context: context)

    await model.load()

    #expect(model.phase == .missing)
    #expect(await model.save() == nil)
  }
}
