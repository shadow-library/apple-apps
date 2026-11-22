import Foundation
import MemoirCore
import Observation
import ShadowAppShell
import ShadowCore
import ShadowStore

/// memoir-web `SubscriptionEntryPanel`: name, amount, currency, frequency, next due date, category and the reminder; editing and deleting are native.
@MainActor
@Observable
final class SubscriptionForm {
  static let frequencies: [SubscriptionFrequency] = [.weekly, .monthly, .quarterly, .yearly, .custom]
  static let customDays = 1...366

  let options: MoneyOptions
  let format: AmountFormat
  let locale: Locale
  var name: String
  var amountText: String
  var currency: CurrencyCode
  var frequency: SubscriptionFrequency
  var customIntervalDays: Int
  var nextDue: LocalDate
  var category: CategoryKey
  var reminderEnabled: Bool
  var reminderLead: SubscriptionReminderLead
  private(set) var isSaving = false
  private(set) var failure: PresentedError?
  @ObservationIgnored let original: SubscriptionRecord?
  /// The latest confirmed billing date; the next due date can only move past it (`SubscriptionSchedule` ignores an anchor at or before it).
  @ObservationIgnored let lastConfirmed: LocalDate?
  @ObservationIgnored private let opening: Terms?
  @ObservationIgnored private let writer: MemoirWriter

  /// A new subscription, or `original` with the next due date and latest confirmation its schedule derives from the confirmed cycles.
  init(
    editing original: SubscriptionRecord? = nil, nextDue derivedDue: LocalDate? = nil, lastConfirmed: LocalDate? = nil, options: MoneyOptions,
    context: MemoirScreenContext, locale: Locale
  ) {
    self.original = original
    self.lastConfirmed = lastConfirmed
    self.options = options
    writer = context.writer
    format = AmountFormat(locale: locale)
    self.locale = locale
    guard let original else {
      opening = nil
      name = ""
      amountText = ""
      currency = options.home ?? MoneyOptions.referenceCurrencies[0]
      frequency = .monthly
      customIntervalDays = SubscriptionCycle.defaultCustomIntervalDays
      nextDue = options.today
      category = CategoryKey("subs") ?? MoneyBook.builtInCategories[0]
      reminderEnabled = true
      reminderLead = .oneDay
      return
    }
    let terms = Terms(
      name: original.name, amountMinor: original.amountMinor, currency: original.currency, frequency: original.frequency.known ?? .monthly,
      customIntervalDays: original.frequency.known == .custom ? original.customIntervalDays ?? SubscriptionCycle.defaultCustomIntervalDays : nil,
      nextDue: derivedDue ?? original.anchorOn, category: original.category, reminderEnabled: original.reminderEnabled,
      reminderLead: original.reminderLead.known ?? .oneDay)
    opening = terms
    name = terms.name
    amountText = MoneyText.editable(original.amountMinor, original.currency, format: format)
    currency = terms.currency
    frequency = terms.frequency
    customIntervalDays = original.customIntervalDays ?? SubscriptionCycle.defaultCustomIntervalDays
    nextDue = terms.nextDue
    category = terms.category
    reminderEnabled = terms.reminderEnabled
    reminderLead = terms.reminderLead
  }

  /// The form for editing a subscription, opened on the next due date its confirmed cycles derive; `nil` when it is gone.
  static func load(_ id: UUID, context: MemoirScreenContext, locale: Locale) async throws -> SubscriptionForm? {
    let options = try await MoneyOptions.load(context)
    let (reading, confirmations) = try await context.stores.main.read { transaction in
      (try SubscriptionRecord.read(id: id, in: transaction), try MoneyBook.load(from: transaction).confirmations)
    }
    guard case .readable(let entry) = reading, !entry.isRemoved else { return nil }
    let schedule = try? SubscriptionSchedule(subscription: entry.record, confirmations: confirmations)
    return SubscriptionForm(
      editing: entry.record, nextDue: schedule?.nextDue, lastConfirmed: schedule?.lastConfirmed, options: options, context: context, locale: locale)
  }

  var isEditing: Bool { original != nil }

  /// A subscription whose frequency or reminder lead a newer app wrote cannot be edited here without losing it; it can still be deleted.
  var isReadOnly: Bool {
    guard let original else { return false }
    return original.frequency.known == nil || original.reminderLead.known == nil
  }

  var currencies: [CurrencyCode] { options.currencies(including: currency) }

  var categories: [CategoryEntry] { options.categories(including: category) }

  /// memoir-web lets a new subscription start today at the earliest; an edited one's next due date stays after its latest confirmed cycle.
  var earliestDue: LocalDate? {
    guard isEditing else { return options.today }
    return lastConfirmed?.adding(days: 1)
  }

  var amount: Result<Int64, AmountInputRefusal> {
    do throws(AmountInputRefusal) {
      return .success(try AmountInput.minorUnits(amountText, currency: currency, format: format))
    } catch {
      return .failure(error)
    }
  }

  var amountIssue: String? {
    guard !amountText.trimmingCharacters(in: .whitespaces).isEmpty, case .failure(let refusal) = amount else { return nil }
    return MoneyLabels.amountIssue(refusal, currency: currency, format: format)
  }

  var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// memoir-web: "Enter a name" once something only blank is typed.
  var nameIssue: String? {
    guard !name.isEmpty, trimmedName.isEmpty else { return nil }
    return String(localized: "Enter a name", table: "Money")
  }

  var dueIssue: String? {
    guard let lastConfirmed, isEditing, nextDue <= lastConfirmed else { return nil }
    let day = MoneyDates.text(lastConfirmed, locale: locale)
    return String(localized: "The cycle of \(day) is already confirmed, so the next one comes after it.", table: "Money")
  }

  var hasChanges: Bool {
    guard let opening else { return !name.isEmpty || !amountText.isEmpty }
    return terms != opening
  }

  var canSave: Bool {
    guard !isSaving, !isReadOnly, !trimmedName.isEmpty, case .success = amount, Self.customDays.contains(customIntervalDays) else { return false }
    if let earliestDue, nextDue < earliestDue { return false }
    return !isEditing || hasChanges
  }

  /// The subscription's id once written; `nil` when nothing was written.
  func save() async -> UUID? {
    guard canSave, let terms else { return nil }
    isSaving = true
    failure = nil
    defer { isSaving = false }
    do {
      if let original, let opening {
        let id = original.id
        _ = try await writer.write { issuer, transaction in
          try SubscriptionWrites.update(id, issuer: issuer, in: &transaction) { terms.apply(changedFrom: opening, to: &$0) }
        }
        return id
      }
      let subscription = terms.record(id: UUID.v7(at: writer.clock.now()))
      try await writer.write { issuer, transaction in try SubscriptionWrites.create(subscription, issuer: issuer, in: &transaction) }
      return subscription.id
    } catch {
      failure = WritingErrors.presented(error)
      return nil
    }
  }

  func delete() async -> Bool {
    guard let id = original?.id, !isSaving else { return false }
    isSaving = true
    failure = nil
    defer { isSaving = false }
    do {
      try await writer.write { issuer, transaction in try SubscriptionWrites.delete(id, issuer: issuer, in: &transaction) }
      return true
    } catch {
      failure = WritingErrors.presented(error)
      return false
    }
  }

  func edited() {
    failure = nil
  }

  private var terms: Terms? {
    guard case .success(let minor) = amount else { return nil }
    return Terms(
      name: trimmedName, amountMinor: minor, currency: currency, frequency: frequency, customIntervalDays: frequency == .custom ? customIntervalDays : nil,
      nextDue: nextDue, category: category, reminderEnabled: reminderEnabled, reminderLead: reminderLead)
  }

  /// What the form edits. An edit writes only the terms the owner moved, so a pause or a note written elsewhere while the form is open stays.
  private nonisolated struct Terms: Equatable, Sendable {
    let name: String
    let amountMinor: Int64
    let currency: CurrencyCode
    let frequency: SubscriptionFrequency
    let customIntervalDays: Int?
    let nextDue: LocalDate
    let category: CategoryKey
    let reminderEnabled: Bool
    let reminderLead: SubscriptionReminderLead

    /// memoir-web takes the billing day from the next due date (`finance.provider.ts:284`).
    func record(id: UUID) -> SubscriptionRecord {
      SubscriptionRecord(
        id: id, name: name, amountMinor: amountMinor, currency: currency, frequency: .known(frequency), customIntervalDays: customIntervalDays,
        billingDay: nextDue.day, anchorOn: nextDue, category: category, reminderEnabled: reminderEnabled, reminderLead: .known(reminderLead))
    }

    func apply(changedFrom opening: Terms, to subscription: inout SubscriptionRecord) {
      if name != opening.name { subscription.name = name }
      if amountMinor != opening.amountMinor { subscription.amountMinor = amountMinor }
      if currency != opening.currency { subscription.currency = currency }
      if frequency != opening.frequency || customIntervalDays != opening.customIntervalDays {
        subscription.frequency = .known(frequency)
        subscription.customIntervalDays = customIntervalDays
      }
      if nextDue != opening.nextDue {
        subscription.anchorOn = nextDue
        subscription.billingDay = nextDue.day
      }
      if category != opening.category { subscription.category = category }
      if reminderEnabled != opening.reminderEnabled { subscription.reminderEnabled = reminderEnabled }
      if reminderLead != opening.reminderLead { subscription.reminderLead = .known(reminderLead) }
    }
  }
}
