import Foundation
import MemoirCore
import Observation
import ShadowAppShell
import ShadowStore

nonisolated enum QuestBuilderMode: Hashable, Sendable {
  case create
  case edit(UUID)
  case duplicate(UUID)
}

/// Where the builder writes a quest's threshold: the class stores through `QuestThresholds`, after the quest's own write.
nonisolated struct QuestThresholdWriter: Sendable {
  let set: @Sendable (QuestThreshold) async throws -> Void
  let clear: @Sendable (UUID) async throws -> Void

  static func stores(_ stores: MemoirStores) -> QuestThresholdWriter {
    QuestThresholdWriter(
      set: { threshold in try await QuestThresholds.set(threshold, in: stores) }, clear: { quest in try await QuestThresholds.clear(quest: quest, in: stores) })
  }
}

/// The quest an edit or a duplicate starts from: its schedule from replay, its words and reminder from its record, and its threshold from its class's store.
nonisolated struct QuestBuilderSource: Sendable, Equatable {
  let quest: QuestSnapshot
  let record: QuestRecord?
  let threshold: QuestThresholdSummary?
  let scheduleEdit: ActionAvailability

  static func load(_ id: UUID, in stores: MemoirStores) async throws(StoreError) -> QuestBuilderSource? {
    let read = try await stores.main.read { transaction in
      (try QuestDetail.load(QuestDetailQuery(quest: id, historyLimit: 0), in: transaction), try QuestRecord.read(id: id, in: transaction).entry?.record)
    }
    guard let quest = read.0.summary?.quest else { return nil }
    return QuestBuilderSource(
      quest: quest, record: read.1, threshold: try await QuestThresholdReader.load(id, in: stores), scheduleEdit: read.0.scheduleEdit)
  }

  var form: QuestForm { QuestForm(quest: quest, record: record, threshold: threshold) }

  /// A monthly or yearly schedule the builder cannot write (`BUILDER_FREQUENCIES`).
  var fixedRecurrence: RecurrenceRule? {
    switch quest.recurrence.frequency {
    case .daily, .weekly: nil
    case .monthly, .yearly: quest.recurrence
    }
  }
}

/// New, edit and duplicate (`quest-builder-screen.tsx`). The live week preview and its issues come from `DraftPreview`, read again before saving so a
/// stale preview never lets an invalid draft through; a create is the record and `quest.create` in one write, an edit the record and `quest.update` in one.
@MainActor
@Observable
final class QuestBuilderModel {
  enum Phase: Equatable {
    case loading
    case ready
    case missing
    case failed(PresentedError)
  }

  private let context: MemoirScreenContext
  private let thresholds: QuestThresholdWriter
  private(set) var mode: QuestBuilderMode
  private(set) var phase = Phase.loading
  private(set) var source: QuestBuilderSource?
  private(set) var today: LocalDate?
  private(set) var preview: DraftPreview?
  private(set) var previewedDraft: QuestDraft?
  private(set) var isSaving = false
  var form = QuestForm()
  var nameTouched = false
  var failure: PresentedError?
  /// The quest was created but its threshold was not written; the builder now edits it, so saving again adds the threshold.
  private(set) var isThresholdPending = false

  init(mode: QuestBuilderMode, context: MemoirScreenContext, thresholds: QuestThresholdWriter? = nil) {
    self.mode = mode
    self.context = context
    self.thresholds = thresholds ?? .stores(context.stores)
  }

  var isEditing: Bool {
    guard case .edit = mode else { return false }
    return true
  }

  /// The schedule is locked when the quest was locked as the builder opened, or when the latest preview finds it in today's lock since.
  var scheduleEdit: ActionAvailability {
    guard isEditing else { return .available }
    if let source, source.scheduleEdit != .available { return source.scheduleEdit }
    return preview?.scheduleEdit ?? .available
  }

  var isScheduleLocked: Bool { scheduleEdit != .available }

  var fixedRecurrence: RecurrenceRule? { isEditing ? source?.fixedRecurrence : nil }

  /// The values a save writes: the form, with the schedule fields held at the quest's own while they are locked.
  var values: QuestForm {
    guard isEditing, isScheduleLocked, let source else { return form }
    return form.lockingSchedule(to: source.form)
  }

  var recurrence: RecurrenceRule? {
    if let fixedRecurrence { return fixedRecurrence }
    guard let today else { return nil }
    return values.recurrence(base: isEditing ? source?.quest.recurrence : nil, today: today)
  }

  /// The draft the preview measures; a weekly quest with no day yet runs on none of the days.
  var draft: QuestDraft? {
    guard let today, phase == .ready else { return nil }
    let values = values
    let editing = isEditing ? source?.quest.id : nil
    let isActive = isEditing ? source?.quest.isActive ?? true : true
    if let recurrence {
      return QuestDraft(
        name: values.name, strictness: values.strictness, startTimeMinutes: values.startMinute, durationMinutes: values.durationMinutes, recurrence: recurrence,
        isActive: isActive, editing: editing)
    }
    guard let placeholder = try? RecurrenceRule(frequency: .weekly(Set(LocalDate.Weekday.allCases)), startDate: today) else { return nil }
    return QuestDraft(
      name: values.name, strictness: values.strictness, startTimeMinutes: values.startMinute, durationMinutes: values.durationMinutes, recurrence: placeholder,
      isActive: false, editing: editing)
  }

  var edit: QuestEdit? {
    guard isEditing, let source else { return nil }
    return try? QuestEdit(
      quest: source.quest, record: source.record, hadThreshold: source.threshold != nil, form: values, scheduleLocked: isScheduleLocked,
      recurrence: fixedRecurrence == nil ? recurrence : nil)
  }

  var issues: [QuestFormIssue] {
    var issues = (preview?.issues ?? []).map(QuestFormIssue.draft)
    if fixedRecurrence == nil, values.repeats == .weekly, values.weekdays.isEmpty { issues.append(.noWeekdays) }
    if issues.isEmpty, isEditing, edit?.isEmpty != false { issues.append(.unchanged) }
    return issues.sorted { $0.rank < $1.rank }
  }

  var isPreviewCurrent: Bool { draft != nil && previewedDraft == draft }

  var canSave: Bool { phase == .ready && !isSaving && isPreviewCurrent && issues.isEmpty }

  /// What the threshold toggle would set or keeps: the quest's own while it has one, else the builder's standard.
  var thresholdShown: QuestThresholdSummary? { (isEditing ? source?.threshold : nil) ?? .standard }

  /// `keepingForm` keeps what the owner typed, as when a create whose threshold failed turns into an edit of the quest it made.
  func load(keepingForm: Bool = false) async {
    do {
      today = try await context.today().date
      switch mode {
      case .create:
        phase = .ready
      case .edit(let id):
        guard let source = try await QuestBuilderSource.load(id, in: context.stores) else {
          phase = .missing
          return
        }
        self.source = source
        if !keepingForm { form = source.form }
        phase = .ready
      case .duplicate(let id):
        guard let source = try await QuestBuilderSource.load(id, in: context.stores) else {
          phase = .missing
          return
        }
        form = QuestForm.duplicating(source.quest, record: source.record, threshold: source.threshold)
        phase = .ready
      }
    } catch {
      phase = .failed(WritingErrors.presented(error) ?? PresentedError(error))
    }
  }

  /// Follows the draft as the owner changes it; nothing is written.
  func observePreview() async {
    guard let draft else { return }
    do {
      for try await preview in context.stores.main.observe(DraftPreview.self, DraftPreviewQuery(draft: draft)) {
        self.preview = preview
        previewedDraft = draft
      }
    } catch {
      if let presented = WritingErrors.presented(error) { failure = presented }
    }
  }

  /// The saved quest's id, or nil when nothing was saved and `failure` or the issues say why.
  func save() async -> UUID? {
    guard phase == .ready, !isSaving, draft != nil else { return nil }
    isSaving = true
    defer { isSaving = false }
    failure = nil
    for attempt in 0..<2 where attempt == 0 || !isPreviewCurrent {
      guard let draft else { return nil }
      do {
        preview = try await context.stores.main.load(DraftPreview.self, DraftPreviewQuery(draft: draft))
        previewedDraft = draft
      } catch {
        failure = WritingErrors.presented(error)
        return nil
      }
    }
    guard isPreviewCurrent, issues.isEmpty else { return nil }
    switch mode {
    case .create, .duplicate: return await create()
    case .edit(let id): return await update(id)
    }
  }

  private func create() async -> UUID? {
    guard let recurrence else { return nil }
    let values = values
    let id = UUID()
    let reminder = values.reminder
    do {
      let schedule = try QuestSchedule(
        strictness: values.strictness, startTimeMinutes: values.startMinute, durationMinutes: values.durationMinutes, statAffinity: values.statAffinity,
        optionalStreakOptIn: values.strictness == .optional, recurrence: recurrence)
      let record = QuestRecord(id: id, name: values.trimmedName, reminderEnabled: reminder.enabled, reminderLeadMinutes: reminder.lead)
      try await context.writer.issue(.questCreate(QuestCreation(questId: id, schedule: schedule)), creating: record)
    } catch {
      failure = WritingErrors.presented(error)
      return nil
    }
    guard values.threshold else { return id }
    guard await setThreshold(of: id) else {
      mode = .edit(id)
      isThresholdPending = true
      await load(keepingForm: true)
      return nil
    }
    return id
  }

  private func update(_ id: UUID) async -> UUID? {
    let edit: QuestEdit
    do {
      guard let source else { return nil }
      edit = try QuestEdit(
        quest: source.quest, record: source.record, hadThreshold: source.threshold != nil, form: values, scheduleLocked: isScheduleLocked,
        recurrence: fixedRecurrence == nil ? recurrence : nil)
    } catch {
      failure = WritingErrors.presented(error)
      return nil
    }
    if edit.record != nil || edit.patch != nil {
      do {
        try await context.writer.write { issuer, transaction in
          if let record = edit.record {
            if case .absent = try QuestRecord.read(id: id, in: transaction) {
              try record.create(in: &transaction)
            } else {
              try QuestRecord.edit(id: id, in: &transaction) { $0 = record }
            }
          }
          if let patch = edit.patch { _ = try issuer.issue(.questUpdate(QuestUpdate(questId: id, patch: patch)), in: &transaction) }
        }
      } catch {
        failure = WritingErrors.presented(error)
        return nil
      }
    }
    switch edit.threshold {
    case .keep:
      break
    case .set:
      guard await setThreshold(of: id) else { return nil }
    case .clear:
      do {
        try await thresholds.clear(id)
      } catch {
        failure = WritingErrors.presented(error)
        return nil
      }
    }
    isThresholdPending = false
    return id
  }

  private func setThreshold(of id: UUID) async -> Bool {
    guard let threshold = QuestThresholdSummary.standard(for: id) else { return false }
    do {
      try await thresholds.set(threshold)
      return true
    } catch {
      failure = WritingErrors.presented(error)
      return false
    }
  }
}
