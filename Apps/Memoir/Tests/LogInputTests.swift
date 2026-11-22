import Foundation
import MemoirCore
import ShadowAppShell
import Testing

@testable import Memoir

@Suite("Log input and format", TestTimeLimit.quick)
struct LogInputTests {
  private static let english = Locale(identifier: "en_GB")
  private static let german = Locale(identifier: "de_DE")

  private static func decimal(_ text: String) throws -> DecimalText { try #require(DecimalText(text)) }

  @Test("should wrap the selection in bold and italic and keep it selected, as applyMarkdownTool does")
  func wrapsTheSelection() {
    #expect(MarkdownTool.bold.apply(to: "a word here", selectionStart: 2, selectionEnd: 6) == .init(text: "a **word** here", selectionStart: 4, selectionEnd: 8))
    #expect(MarkdownTool.italic.apply(to: "", selectionStart: 0, selectionEnd: 0) == .init(text: "__", selectionStart: 1, selectionEnd: 1))
  }

  @Test("should prefix the selection's line with quote, list and heading markers")
  func prefixesTheLine() {
    #expect(MarkdownTool.list.apply(to: "one\ntwo", selectionStart: 5, selectionEnd: 5) == .init(text: "one\n- two", selectionStart: 7, selectionEnd: 7))
    #expect(MarkdownTool.heading.apply(to: "title", selectionStart: 3, selectionEnd: 3) == .init(text: "## title", selectionStart: 6, selectionEnd: 6))
    #expect(MarkdownTool.quote.apply(to: "a\nb", selectionStart: 2, selectionEnd: 3) == .init(text: "a\n> b", selectionStart: 4, selectionEnd: 5))
  }

  @Test("should count offsets in UTF-16 units, so text after an emoji is edited where the reference would")
  func countsUTF16Units() {
    #expect(MarkdownTool.bold.apply(to: "🙂 ok", selectionStart: 3, selectionEnd: 5) == .init(text: "🙂 **ok**", selectionStart: 5, selectionEnd: 7))
  }

  @Test("should read typed decimals exactly in the owner's locale and refuse what it would have to guess")
  func readsDecimals() throws {
    #expect(DecimalInput.parse(" 72.40 ", locale: Self.english) == .success(try Self.decimal("72.4")))
    #expect(DecimalInput.parse("007", locale: Self.english) == .success(try Self.decimal("7")))
    #expect(DecimalInput.parse(".5", locale: Self.english) == .success(try Self.decimal("0.5")))
    #expect(DecimalInput.parse("7,5", locale: Self.german) == .success(try Self.decimal("7.5")))
    #expect(DecimalInput.parse("7.5", locale: Self.german) == .failure(.notANumber), "a full stop where the locale writes a comma is not guessed")
    #expect(DecimalInput.parse("1,234", locale: Self.english) == .failure(.notANumber), "grouping is refused")
    #expect(DecimalInput.parse("", locale: Self.english) == .failure(.empty))
    #expect(DecimalInput.parse("-3", locale: Self.english) == .failure(.negative))
    #expect(DecimalInput.parse("-0", locale: Self.english) == .success(try Self.decimal("0")))
    #expect(DecimalInput.parse("1.2.3", locale: Self.english) == .failure(.notANumber))
    #expect(DecimalInput.parse("abc", locale: Self.english) == .failure(.notANumber))
    #expect(DecimalInput.parse(".", locale: Self.english) == .failure(.notANumber))
  }

  @Test("should move a decimal point exactly in either direction")
  func shiftsDecimals() throws {
    #expect(DecimalInput.shifted(try Self.decimal("2.25"), by: 3) == DecimalText("2250"))
    #expect(DecimalInput.shifted(try Self.decimal("0.0015"), by: 3) == DecimalText("1.5"))
    #expect(DecimalInput.shifted(try Self.decimal("2250"), by: -3) == DecimalText("2.25"))
    #expect(DecimalInput.shifted(try Self.decimal("5"), by: -3) == DecimalText("0.005"))
  }

  @Test("should store water typed in litres as millilitres, a duration typed in hours as whole minutes and refuse a fractional count")
  func storesTypedMetricValues() async throws {
    let builtins = try await LogTesting.builtinDescriptors()
    let water = try #require(builtins[.water])
    let sleep = try #require(builtins[.sleep])
    let steps = try #require(builtins[.steps])
    #expect(MetricFormat.stored("2.25", for: water, locale: Self.english) == .success(try Self.decimal("2250")))
    #expect(MetricFormat.stored("7.5", for: sleep, locale: Self.english) == .success(try Self.decimal("450")))
    #expect(MetricFormat.stored("7.01", for: sleep, locale: Self.english) == .success(try Self.decimal("421")))
    #expect(MetricFormat.stored("8000", for: steps, locale: Self.english) == .success(try Self.decimal("8000")))
    #expect(MetricFormat.stored("80.5", for: steps, locale: Self.english) == .failure(.notWhole))
    #expect(MetricFormat.stored("", for: steps, locale: Self.english) == .failure(.empty))
    #expect(MetricFormat.input(try Self.decimal("2250"), of: water, locale: Self.german) == "2,25")
    #expect(MetricFormat.input(try Self.decimal("450"), of: sleep, locale: Self.english) == "7.5")
  }

  @Test("should give its example in the locale's decimal format")
  func givesALocalExample() {
    #expect(MetricEntryProblem.notANumber.message(for: "Steps", locale: Self.german).contains("7,5"))
    #expect(MetricEntryProblem.notANumber.message(for: "Steps", locale: Self.english).contains("7.5"))
    #expect(WeightInputProblem.notANumber.message(in: .kilograms, locale: Self.german).contains("72,4"))
  }

  @Test("should show water under a litre in millilitres and above it in litres")
  func showsWater() throws {
    #expect(MetricFormat.water(try Self.decimal("750")).contains("750"))
    #expect(MetricFormat.water(try Self.decimal("750")).contains("ml"))
    #expect(MetricFormat.water(try Self.decimal("2250")).contains("L"))
  }

  @Test("should write HealthKit's doubles as exact decimals rounded to each metric's places, and drop what is not a value")
  func writesHealthValues() {
    #expect(HealthValueText.decimal(72.4000000001, places: 2) == DecimalText("72.4"))
    #expect(HealthValueText.decimal(8123.5, places: 0) == DecimalText("8124"))
    #expect(HealthValueText.decimal(0.04, places: 1) == DecimalText("0"))
    #expect(HealthValueText.decimal(0.05, places: 2) == DecimalText("0.05"))
    #expect(HealthValueText.decimal(-1, places: 0) == nil)
    #expect(HealthValueText.decimal(.nan, places: 0) == nil)
    #expect(HealthValueText.decimal(.infinity, places: 0) == nil)
  }

  @Test("should name the mood most days had, rounding halves up, as moodNote does")
  func notesTheMood() {
    let day = TestClock.day0
    #expect(LogFormat.moodNote([DayValue(date: day, value: 3), DayValue(date: day, value: 4)]).contains(LogFormat.moodLabel(4)))
    #expect(LogFormat.moodNote([DayValue(date: day, value: nil)]) == String(localized: "No mood logged in the last 28 days.", table: "Log"))
  }

  @Test("should say nothing while clear and keep every level advisory")
  func notesTheEntryCap() {
    #expect(LogFormat.capNote(EntryCapAdvisory(module: .meals, used: 79)) == nil)
    #expect(LogFormat.capNote(EntryCapAdvisory(module: .meals, used: 80))?.contains("80") == true)
    #expect(LogFormat.capNote(EntryCapAdvisory(module: .meals, used: 101))?.contains("Everything still saves") == true)
  }

  @Test("should read HealthKit as available only on an iPhone or iPad build signed with it, on a device that has Health data")
  func resolvesAvailability() {
    let signed: [String: Any] = ["ShadowCapabilities": ["HealthKit": "YES"]]
    let unsigned: [String: Any] = ["ShadowCapabilities": ["HealthKit": "NO"]]
    #expect(HealthAvailability.resolve(isPhoneOrPad: true, infoDictionary: signed) { true } == .available)
    #expect(HealthAvailability.resolve(isPhoneOrPad: true, infoDictionary: signed) { false } == .unavailableOnDevice)
    #expect(HealthAvailability.resolve(isPhoneOrPad: true, infoDictionary: unsigned) { true } == .notEntitled)
    #expect(HealthAvailability.resolve(isPhoneOrPad: true, infoDictionary: nil) { true } == .notEntitled)
    #expect(HealthAvailability.resolve(isPhoneOrPad: false, infoDictionary: signed) { true } == .otherPlatform)
  }
}
