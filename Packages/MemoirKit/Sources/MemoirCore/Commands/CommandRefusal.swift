import ShadowCore

public enum FieldProblem: String, Sendable, Hashable {
  case required
  case notObject = "not_object"
  case notString = "not_string"
  case notBoolean = "not_boolean"
  case notInteger = "not_integer"
  case notArray = "not_array"
  case notAllowed = "not_allowed"
  case notDate = "not_date"
  case notIdentifier = "not_identifier"
  case outOfRange = "out_of_range"
  case tooLong = "too_long"
  case empty
  case duplicate
}

/// Why a command is refused before it is issued, or why a stored payload does not decode. `field` names the field as the reference's
/// `ValidationError` does, and `referenceCode` is the reference's `AppErrorCode` where it refuses the same input.
public enum CommandRefusal: ShadowError, Equatable {
  case unknownType(String)
  case invalidField(field: String, problem: FieldProblem)
  case unexpectedField(String)
  case occurrenceRequired(MemoirCommandKind)
  case occurrenceUnexpected(MemoirCommandKind)
  case anchorNeedsStartTime
  case duplicateLockedQuest
  case categoryNotArchivable(CategoryKey)
  case unknownCategory(String)
  case unknownCosmetic(String)
  case cosmeticNotForSale(CosmeticID)
  case unknownTitle(String)
  case healthThresholdUnsupported
  case oneTextPerCommand
  case textRequired(field: String)
  case textUnexpected
  case calendar(field: String, CalendarError)
  case finance(FinanceError)
  case payload(MemoirCommandError)

  public var field: String? {
    switch self {
    case .invalidField(let field, _), .textRequired(let field), .calendar(let field, _): field
    case .unexpectedField(let field): field
    case .healthThresholdUnsupported: "healthThreshold"
    case .unknownType, .occurrenceRequired, .occurrenceUnexpected, .anchorNeedsStartTime, .duplicateLockedQuest, .categoryNotArchivable, .unknownCategory, .unknownCosmetic,
      .cosmeticNotForSale,
      .unknownTitle,
      .oneTextPerCommand, .textUnexpected, .finance, .payload:
      nil
    }
  }

  public var referenceCode: String? {
    switch self {
    case .unknownType: "CMD_001"
    case .anchorNeedsStartTime: "QST_003"
    case .duplicateLockedQuest: "LCK_001"
    case .categoryNotArchivable: "FIN_007"
    case .unknownCategory: "FIN_005"
    case .unknownCosmetic: "CSM_002"
    case .cosmeticNotForSale: "CSM_004"
    case .unknownTitle: "TTL_001"
    case .invalidField, .unexpectedField, .occurrenceRequired, .occurrenceUnexpected, .healthThresholdUnsupported, .oneTextPerCommand, .textRequired, .textUnexpected,
      .calendar, .finance, .payload:
      nil
    }
  }

  public var code: String {
    switch self {
    case .unknownType: "memoir_command.unknown_type"
    case .invalidField: "memoir_command.invalid_field"
    case .unexpectedField: "memoir_command.unexpected_field"
    case .occurrenceRequired: "memoir_command.occurrence_required"
    case .occurrenceUnexpected: "memoir_command.occurrence_unexpected"
    case .anchorNeedsStartTime: "memoir_command.anchor_needs_start_time"
    case .duplicateLockedQuest: "memoir_command.duplicate_locked_quest"
    case .categoryNotArchivable: "memoir_command.category_not_archivable"
    case .unknownCategory: "memoir_command.unknown_category"
    case .unknownCosmetic: "memoir_command.unknown_cosmetic"
    case .cosmeticNotForSale: "memoir_command.cosmetic_not_for_sale"
    case .unknownTitle: "memoir_command.unknown_title"
    case .healthThresholdUnsupported: "memoir_command.health_threshold_unsupported"
    case .oneTextPerCommand: "memoir_command.one_text_per_command"
    case .textRequired: "memoir_command.text_required"
    case .textUnexpected: "memoir_command.text_unexpected"
    case .calendar: "memoir_command.calendar"
    case .finance(let error): error.code
    case .payload(let error): error.code
    }
  }

  public var errorDescription: String? {
    switch self {
    case .unknownType(let type): "No command is called \(type)."
    case .invalidField(let field, let problem): "The field \(field) is invalid (\(problem.rawValue))."
    case .unexpectedField(let field): "The field \(field) is not part of this command; content belongs in the record the command names."
    case .occurrenceRequired(let kind): "\(kind.rawValue) acts on a quest occurrence and needs one."
    case .occurrenceUnexpected(let kind): "\(kind.rawValue) does not act on a quest occurrence."
    case .anchorNeedsStartTime: "An anchor quest needs a start time."
    case .duplicateLockedQuest: "A plan lock names each quest once."
    case .categoryNotArchivable(let key): "The category \(key) cannot be archived."
    case .unknownCategory(let key): "No built-in category is called \(key)."
    case .unknownCosmetic(let id): "No cosmetic is called \(id)."
    case .cosmeticNotForSale(let id): "The cosmetic \(id.rawValue) is unlocked by an achievement and cannot be bought."
    case .unknownTitle(let id): "No title is called \(id), so it cannot have been earned."
    case .healthThresholdUnsupported: "Quest health thresholds are not available yet; they need a record kind of their own."
    case .oneTextPerCommand: "A command keeps one text in its note record; send the reason note and the reflection as two commands."
    case .textRequired(let field): "The command says it carries \(field), but no text came with it."
    case .textUnexpected: "Text came with a command that has no place for it."
    case .calendar(let field, let error): "The field \(field) is refused: \(error.errorDescription ?? error.code)"
    case .finance(let error): error.errorDescription
    case .payload(let error): error.errorDescription
    }
  }
}
