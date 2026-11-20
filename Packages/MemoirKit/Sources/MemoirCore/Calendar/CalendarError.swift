import ShadowCore

public enum CalendarError: ShadowError, Equatable {
  case dateOutOfRange
  case minuteOfDayOutOfRange(Int)
  case noWeekdays
  case dayOfMonthOutOfRange(Int)
  case billingDayOutOfRange(Int)

  public var code: String {
    switch self {
    case .dateOutOfRange: "memoir_calendar.date_out_of_range"
    case .minuteOfDayOutOfRange: "memoir_calendar.minute_of_day_out_of_range"
    case .noWeekdays: "memoir_calendar.no_weekdays"
    case .dayOfMonthOutOfRange: "memoir_calendar.day_of_month_out_of_range"
    case .billingDayOutOfRange: "memoir_calendar.billing_day_out_of_range"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .dateOutOfRange: "The date falls outside the years 0000 to 9999."
    case .minuteOfDayOutOfRange(let minute): "Minute \(minute) is not a minute of the day (0 to 1439)."
    case .noWeekdays: "A weekly recurrence needs at least one weekday."
    case .dayOfMonthOutOfRange(let day): "Day \(day) is not a day of the month; a monthly recurrence takes 1 or more and clamps to the month's end."
    case .billingDayOutOfRange(let day): "Billing day \(day) is not between 1 and 31."
    }
  }
}
