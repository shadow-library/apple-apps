import Foundation
import MemoirCore
import Testing
import UserNotifications

@testable import Memoir

@Suite("ReminderCopy", TestTimeLimit.quick)
struct ReminderCopyTests {
  private static let us = Locale(identifier: "en_US")
  private static let uk = Locale(identifier: "en_GB")
  private static let germany = Locale(identifier: "de_DE")

  private static func money(_ minor: Int64, _ code: String) throws -> MoneyAmount {
    MoneyAmount(amountMinor: minor, currency: try #require(CurrencyCode(code)))
  }

  @Test("should format an amount exactly from its minor units with the currency's exponent and the owner's locale")
  func formatsMoneyExactly() throws {
    #expect(ReminderCopy.amount(try Self.money(1_299, "EUR"), locale: Self.germany) == "12,99\u{A0}€")
    #expect(ReminderCopy.amount(try Self.money(1_299, "USD"), locale: Self.us) == "$12.99")
    #expect(ReminderCopy.amount(try Self.money(1_500, "JPY"), locale: Self.us) == "¥1,500", "no decimals for a zero-exponent currency")
    #expect(ReminderCopy.amount(try Self.money(1_234, "KWD"), locale: Self.us) == "KWD\u{A0}1.234", "three decimals for the dinar")
    #expect(ReminderCopy.amount(try Self.money(500, "GBP"), locale: Self.uk) == "£5.00", "trailing zeros kept to the exponent")
    #expect(
      ReminderCopy.amount(try Self.money(9_007_199_254_740_993, "USD"), locale: Self.us) == "$90,071,992,547,409.93", "past a Double's exact integers")
  }

  @Test("should leave out an amount whose currency this version does not know")
  func dropsAnUnknownCurrency() throws {
    let unknown = try Self.money(1_299, "XYZ")
    #expect(ReminderCopy.amount(unknown, locale: Self.us) == nil)
    #expect(ReminderCopy.subscriptionBody(dueOn: TestClock.day0, lead: .onDay, amount: unknown, locale: Self.us) == "Renews today.")
  }

  @Test("should write a quest's start in the owner's locale with its lead")
  func writesQuestBodies() {
    #expect(ReminderCopy.time(minuteOfDay: 480, locale: Self.us) == "8:00\u{202F}AM")
    #expect(ReminderCopy.time(minuteOfDay: 1_230, locale: Self.uk) == "20:30")
    #expect(ReminderCopy.time(minuteOfDay: 1_230, locale: Self.germany) == "20:30")
    #expect(ReminderCopy.questBody(startMinute: 480, leadMinutes: 15, isRescheduled: false, locale: Self.us) == "Starts in 15 minutes, at 8:00\u{202F}AM.")
    #expect(ReminderCopy.questBody(startMinute: 1_230, leadMinutes: 90, isRescheduled: false, locale: Self.uk) == "Starts in 1 hour, 30 minutes, at 20:30.")
    #expect(ReminderCopy.questBody(startMinute: 1_230, leadMinutes: 0, isRescheduled: false, locale: Self.uk) == "Starts now, at 20:30.")
    #expect(
      ReminderCopy.questBody(startMinute: 1_230, leadMinutes: 10, isRescheduled: true, locale: Self.uk)
        == "Starts in 10 minutes, at 20:30, the time you moved it to.")
    #expect(ReminderCopy.questBody(startMinute: nil, leadMinutes: 0, isRescheduled: false, locale: Self.uk) == "On your plan for today.")
  }

  @Test("should say when a subscription renews from its lead, with its amount")
  func writesSubscriptionBodies() throws {
    let music = try Self.money(1_299, "EUR")
    let due = TestClock.day(7)
    #expect(ReminderCopy.subscriptionBody(dueOn: due, lead: .onDay, amount: music, locale: Self.uk) == "Renews today for €12.99.")
    #expect(ReminderCopy.subscriptionBody(dueOn: due, lead: .oneDay, amount: music, locale: Self.uk) == "Renews tomorrow for €12.99.")
    #expect(ReminderCopy.subscriptionBody(dueOn: due, lead: .oneWeek, amount: music, locale: Self.uk) == "Renews on Monday 9 March for €12.99.")
    #expect(ReminderCopy.subscriptionBody(dueOn: due, lead: .threeDays, amount: music, locale: Self.us) == "Renews on Monday, March 9 for €12.99.")
  }

  @Test("should pin a request's instant to a zone, so a later change of the device's zone does not move it")
  func pinsTheTrigger() throws {
    let fireAt = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60 + 10 * 86_400)
    let chatham = try #require(TimeZone(identifier: "Pacific/Chatham"))
    let trigger = SystemReminderNotifications.trigger(at: fireAt, pinnedTo: chatham)
    #expect(trigger.nextTriggerDate() == fireAt)
    #expect(trigger.dateComponents.timeZone == chatham && !trigger.repeats)
  }
}
