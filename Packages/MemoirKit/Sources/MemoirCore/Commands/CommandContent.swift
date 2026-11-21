/// The reference's checks on the content a command names, which lives in records here; a caller runs them before writing the record and issuing the
/// command. Fields are named as the reference's `ValidationError` names them.
public protocol CommandContent {
  func validate() throws(CommandRefusal)
}

enum ContentRules {
  static let reasonNoteMaximumLength = 120

  static func name(_ text: String, field: String = "name") throws(CommandRefusal) {
    guard !text.isEmpty else { throw .invalidField(field: field, problem: .required) }
  }

  static func nonNegative(_ value: Int, field: String) throws(CommandRefusal) {
    guard value >= 0 else { throw .invalidField(field: field, problem: .outOfRange) }
  }

  /// JavaScript's `length` counts UTF-16 code units, so the reason note's limit does too.
  static func reasonNote(_ text: String) throws(CommandRefusal) {
    guard !text.isEmpty else { throw .invalidField(field: CommandTextSlot.reasonNote.rawValue, problem: .required) }
    guard text.utf16.count <= reasonNoteMaximumLength else { throw .invalidField(field: CommandTextSlot.reasonNote.rawValue, problem: .tooLong) }
  }

  static func reflection(_ text: String) throws(CommandRefusal) {
    guard !text.isEmpty else { throw .invalidField(field: CommandTextSlot.reflection.rawValue, problem: .empty) }
  }
}

extension QuestRecord: CommandContent {
  public func validate() throws(CommandRefusal) {
    try ContentRules.name(name)
  }
}

extension JournalEntryRecord: CommandContent {
  public static let moods = 1...5

  public func validate() throws(CommandRefusal) {
    try ContentRules.name(text, field: "text")
    if let mood, !Self.moods.contains(mood) { throw .invalidField(field: "mood", problem: .outOfRange) }
  }
}

extension MealRecord: CommandContent {
  public func validate() throws(CommandRefusal) {
    try ContentRules.name(name)
    try ContentRules.nonNegative(calories, field: "calories")
  }
}

extension MealPresetRecord: CommandContent {
  public func validate() throws(CommandRefusal) {
    try ContentRules.name(name)
    try ContentRules.nonNegative(calories, field: "calories")
  }
}

extension SideQuestRecord: CommandContent {
  public func validate() throws(CommandRefusal) {
    try ContentRules.name(name)
  }
}

extension WeightRecord: CommandContent {
  public func validate() throws(CommandRefusal) {
    guard !kilograms.text.hasPrefix("-"), kilograms.text != "0" else { throw .invalidField(field: "kg", problem: .outOfRange) }
  }
}

extension MetricRecord: CommandContent {
  public func validate() throws(CommandRefusal) {
    try ContentRules.name(name)
  }
}

/// Finance's `BillingTerms` decide the cycle: a billing day outside 1 to 31, which the reference leaves to its database check, and a custom interval of
/// zero or less, which the reference accepts and then never advances, are refused.
extension SubscriptionRecord: CommandContent {
  public func validate() throws(CommandRefusal) {
    try ContentRules.name(name)
    do throws(FinanceError) {
      _ = try BillingTerms(self)
    } catch {
      switch error {
      case .billingDayOutOfRange(let day): throw .calendar(field: "billingDay", .billingDayOutOfRange(day))
      case .customIntervalNotPositive: throw .invalidField(field: "customIntervalDays", problem: .outOfRange)
      case .unknownFrequency: throw .invalidField(field: "frequency", problem: .notAllowed)
      default: throw .finance(error)
      }
    }
  }
}
