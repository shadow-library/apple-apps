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
}

public enum ExpenseRateMember: String, MemoirField {
  case rate
  case date
  case quote
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
}

public enum ExpenseCategoryField: String, MemoirField {
  case label
  case archived
}

public enum ReceiptField: String, MemoirField {
  case blob
  case contentType = "content_type"
  case byteCount = "byte_count"
}

public enum FxRateField: String, MemoirField {
  case rate
}

public enum AccountSettingsField: String, MemoirField {
  case defaultCurrency = "default_currency"
  case enabledCurrencies = "enabled_currencies"
  case monthlyBudget = "monthly_budget"
  case schedule
  case weekStart = "week_start"
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
