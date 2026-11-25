import Foundation
import MemoirCore
import Observation
import ShadowAppShell
import ShadowCore
import ShadowStore

/// Creates a savings goal or edits one: its name, symbol, target in the home currency read through `AmountInput`, and an optional target date. A bought
/// or set-aside goal keeps its target and date. Writes go only through `GoalEdits`, which refuses as the plan says.
@MainActor
@Observable
final class GoalForm {
  let editing: SavingsGoalRecord?
  /// The goal's own currency when editing (the home one unless two devices disagreed on it), the home currency otherwise.
  let currency: CurrencyCode
  let today: LocalDate
  let format: AmountFormat
  var name: String
  var symbol: String
  var targetText: String
  var hasTargetDate: Bool
  var targetDate: LocalDate
  private(set) var isSaving = false
  private(set) var failure: PresentedError?
  @ObservationIgnored private let opening: GoalDraft?
  @ObservationIgnored private let context: MemoirScreenContext

  init(editing goal: SavingsGoalRecord? = nil, home: CurrencyCode, today: LocalDate, context: MemoirScreenContext, locale: Locale) {
    editing = goal
    currency = goal?.currency ?? home
    self.today = today
    self.context = context
    let format = AmountFormat(locale: locale)
    self.format = format
    opening = goal.map(GoalDraft.init)
    name = goal?.name ?? ""
    symbol = goal?.symbol ?? GoalCopy.symbols[0]
    targetText = goal.map { MoneyText.editable($0.targetMinor, $0.currency, format: format) } ?? ""
    hasTargetDate = goal?.targetDate != nil
    targetDate = goal?.targetDate ?? today.adding(months: 6) ?? today
  }

  var isEditing: Bool { editing != nil }

  /// `GoalEdits.update` refuses to move the target or date of a goal no longer active.
  var canChangeTarget: Bool { editing.map { $0.state == .known(.active) } ?? true }

  /// The curated symbols, and the goal's own first when it came from elsewhere with another.
  var symbols: [String] { GoalCopy.symbols.contains(symbol) ? GoalCopy.symbols : [symbol] + GoalCopy.symbols }

  var target: Result<Int64, AmountInputRefusal> {
    do throws(AmountInputRefusal) {
      return .success(try AmountInput.minorUnits(targetText, currency: currency, format: format))
    } catch {
      return .failure(error)
    }
  }

  var targetIssue: String? {
    guard !targetText.trimmingCharacters(in: .whitespaces).isEmpty, case .failure(let refusal) = target else { return nil }
    return MoneyLabels.amountIssue(refusal, currency: currency, format: format)
  }

  var draft: GoalDraft? {
    guard case .success(let minor) = target else { return nil }
    return GoalDraft(name: name, symbol: symbol, targetMinor: minor, targetDate: hasTargetDate ? targetDate : nil)
  }

  var hasChanges: Bool {
    guard let opening else { return !name.isEmpty || !targetText.isEmpty }
    return draft != opening
  }

  var canSave: Bool {
    guard !isSaving, draft != nil, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    return opening == nil || hasChanges
  }

  func edited() {
    failure = nil
  }

  /// The goal's id once written; nil when the target does not read or the write failed, with the failure shown.
  func save() async -> UUID? {
    guard canSave, let draft else { return nil }
    isSaving = true
    failure = nil
    defer { isSaving = false }
    do {
      let today = try await context.today().date
      if let editing {
        let id = editing.id
        _ = try await context.writer.write { _, transaction in try GoalEdits.update(id, today: today, in: &transaction) { $0 = draft } }
        return id
      }
      let id = UUID.v7(at: context.clock.now())
      _ = try await context.writer.write { _, transaction in try GoalEdits.create(draft, id: id, today: today, in: &transaction) }
      return id
    } catch {
      failure = WritingErrors.presented(error)
      return nil
    }
  }
}
