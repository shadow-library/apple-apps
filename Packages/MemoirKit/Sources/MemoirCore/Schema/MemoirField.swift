public protocol MemoirField: RawRepresentable, CaseIterable, Hashable, Sendable where RawValue == String {}

enum CommonField: String {
  case naturalKey = "natural_key"
  case removed
}

public enum CommandMember: String, MemoirField {
  case type
  case payload
  case instantMillis = "instant_millis"
  case utcOffsetMinutes = "utc_offset_minutes"
  case issuedOn = "issued_on"
  case occurrence
  case rulesetVersion = "ruleset_version"
}

public enum OccurrenceMember: String, MemoirField {
  case quest
  case date
}

public enum CommandNoteMember: String, MemoirField {
  case text
}

public enum QuestField: String, MemoirField {
  case name
  case notes
  case reminderEnabled = "reminder_enabled"
  case reminderLeadMinutes = "reminder_lead_minutes"
}

public enum JournalEntryField: String, MemoirField {
  case date
  case mood
  case tags
  case loggedAtMillis = "logged_at_millis"
}

public enum JournalBodyMember: String, MemoirField {
  case text
}

public enum MealField: String, MemoirField {
  case date
  case name
  case calories
  case mealType = "meal_type"
  case note
  case preset
  case loggedAtMillis = "logged_at_millis"
}

public enum MealPresetField: String, MemoirField {
  case name
  case calories
  case mealType = "meal_type"
  case note
}

public enum SideQuestField: String, MemoirField {
  case date
  case name
  case loggedAtMillis = "logged_at_millis"
}

public enum ExpenseField: String, MemoirField {
  case amountMinor = "amount_minor"
  case currency
  case occurredOn = "occurred_on"
  case category
  case merchant
  case note
  case receipt
  case rate
  case loggedAtMillis = "logged_at_millis"
  case manualRate = "manual_rate"
  case budget
  case fromSavingsMinor = "from_savings_minor"
  case goal
  case cycle
}

public enum ExpenseCycleMember: String, MemoirField {
  case subscription
  case amountMinor = "amount_minor"
  case occurredOn = "occurred_on"
  case category
}

public enum ExpenseRateMember: String, MemoirField {
  case rate
  case date
  case quote
}

public enum ManualRateMember: String, MemoirField {
  case rate
  case quote
}

public enum ExpenseChangeMember: String, MemoirField {
  case expense
  case changes
  case reason
}

public enum ExpenseFieldChangeMember: String, MemoirField {
  case field
  case from
  case to
}

public enum SubscriptionField: String, MemoirField {
  case name
  case note
  case amountMinor = "amount_minor"
  case currency
  case frequency
  case customIntervalDays = "custom_interval_days"
  case billingDay = "billing_day"
  case anchorOn = "anchor_on"
  case category
  case reminderEnabled = "reminder_enabled"
  case reminderLead = "reminder_lead"
  case active
  case budget
}

public enum ExpenseCategoryField: String, MemoirField {
  case label
  case archived
  case essential
}

public enum ReceiptField: String, MemoirField {
  case blob
  case contentType = "content_type"
  case byteCount = "byte_count"
}

public enum FxRateField: String, MemoirField {
  case rate
}

public enum BudgetField: String, MemoirField {
  case name
  case currency
  case limitMinor = "limit_minor"
  case period
  case stagedLimit = "staged_limit"
  case oneOffFromMinor = "one_off_from_minor"
  case stagedOneOff = "staged_one_off"
  case createdOn = "created_on"
}

public enum BudgetPeriodMember: String, MemoirField {
  case kind
  case from
  case through
}

public enum StagedAmountMember: String, MemoirField {
  case amountMinor = "amount_minor"
  case from
}

public enum SavingsDepositField: String, MemoirField {
  case deposit
}

public enum SavingsDepositMember: String, MemoirField {
  case amountMinor = "amount_minor"
  case currency
  case rate
  case closedOn = "closed_on"
  case command
  case spentMinor = "spent_minor"
  case limitMinor = "limit_minor"
  case medianExpenseMinor = "median_expense_minor"
}

public enum SavingsGoalField: String, MemoirField {
  case name
  case symbol
  case targetMinor = "target_minor"
  case currency
  case targetDate = "target_date"
  case rank
  case createdOn = "created_on"
  case state
}

public enum AccountSettingsField: String, MemoirField {
  case defaultCurrency = "default_currency"
  case enabledCurrencies = "enabled_currencies"
  case monthlyBudget = "monthly_budget"
  case schedule
  case weekStart = "week_start"
  case moduleHero = "module_hero"
  case moduleQuests = "module_quests"
  case moduleMoney = "module_money"
  case moduleJournal = "module_journal"
  case moduleMeals = "module_meals"
  case moduleBody = "module_body"
  case moneyScoredFrom = "money_scored_from"
}

public enum ScheduleMember: String, MemoirField {
  case start
  case end
}

public enum MoneyMember: String, MemoirField {
  case amountMinor = "amount_minor"
  case currency
}

public enum MetricField: String, MemoirField {
  case name
  case unit
  case valueType = "value_type"
  case direction
  case defaultValue = "default_value"
  case glyph
}

/// `value` and `source` are v1's and stay declared, but nothing writes them: v2 keeps the owner's entry as one register, `entry`, so two devices
/// writing it at once can never leave a value without its source.
public enum MetricDayField: String, MemoirField {
  case value
  case source
  case imported
  case entry
}

public enum MetricEntryMember: String, MemoirField {
  case value
  case source
}

public enum QuestThresholdField: String, MemoirField {
  case threshold
}

public enum QuestThresholdMember: String, MemoirField {
  case metric
  case value
  case comparison
}

public enum HealthSettingsField: String, MemoirField {
  case reader
  case activityOnICloud = "activity_on_icloud"
}

public enum HealthReaderMember: String, MemoirField {
  case device
  case name
  case claimedAtMillis = "claimed_at_millis"
}

public enum WeightField: String, MemoirField {
  case kilograms
  case loggedAtMillis = "logged_at_millis"
}

public enum InsightScheduleField: String, MemoirField {
  case question
  case active
  case minuteOfDay = "minute_of_day"
  case setOn = "set_on"
  case setAtMinute = "set_at_minute"
}

public enum InsightField: String, MemoirField {
  case job
  case question
  case answer
  case patterns
  case suggestions
  case limitationNote = "limitation_note"
  case citations
  case model
  case promptVersion = "prompt_version"
  case createdMillis = "created_millis"
}

public enum InsightSuggestionMember: String, MemoirField {
  case kind
  case quest
  case text
}
