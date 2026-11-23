import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import MemoirCore

@Suite("Frankfurter rates client", TestTimeLimit.quick)
struct FrankfurterRatesClientTests {
  private static let eur = MoneyReadsFixture.currency("EUR")
  private static let usd = MoneyReadsFixture.currency("USD")
  private static let nok = MoneyReadsFixture.currency("NOK")
  private static let jpy = MoneyReadsFixture.currency("JPY")
  private static let aed = MoneyReadsFixture.currency("AED")

  private static func client(_ transport: StubHTTPTransport, at instant: Date = FrankfurterFixtures.mondayEvening) -> FrankfurterRatesClient {
    FrankfurterRatesClient(transport: transport, now: { instant })
  }

  private static func failure(_ body: () async throws(RatesClientError) -> Void) async -> RatesClientError? {
    do throws(RatesClientError) {
      try await body()
      return nil
    } catch {
      return error
    }
  }

  @Test func shouldSendOnlyTheBaseTheQuotesAndTheDateAndReadEachRateExactly() async throws {
    let transport = FrankfurterFixtures.transport(["NOK": (200, FrankfurterFixtures.friday)])
    let pairs: Set = [CurrencyPair(base: Self.nok, quote: Self.eur), CurrencyPair(base: Self.nok, quote: Self.usd)]
    let rates = try await Self.client(transport).rates(for: pairs, on: MoneyReadsFixture.date("2026-11-20"))

    #expect(
      rates == [
        CurrencyPair(base: Self.nok, quote: Self.eur): MoneyReadsFixture.decimal("0.093301"), CurrencyPair(base: Self.nok, quote: Self.usd): MoneyReadsFixture.decimal("0.10254"),
      ])
    let request = try #require(transport.requests.first)
    #expect(transport.requests.count == 1)
    #expect(request.httpMethod == "GET")
    #expect(request.httpBody == nil)
    #expect(request.url?.host() == "api.frankfurter.dev")
    #expect(request.url?.path() == "/v2/providers/ecb/rates")
    #expect(FrankfurterFixtures.query(request) == ["date": "2026-11-20", "base": "NOK", "quotes": "EUR,USD"])
    #expect(request.allHTTPHeaderFields == ["Accept": "application/json", "User-Agent": "exchange-rates", "Accept-Language": "en"])
  }

  @Test func shouldKeepEveryDigitOfALongRateWithoutABinaryFloat() async throws {
    let transport = FrankfurterFixtures.transport(["JPY": (200, FrankfurterFixtures.longRate)])
    let pair = CurrencyPair(base: Self.jpy, quote: Self.eur)
    let rates = try await Self.client(transport).rates(for: [pair], on: MoneyReadsFixture.date("2026-11-18"))
    #expect(rates[pair]?.text == "0.00573561234567891")
  }

  @Test func shouldAskOncePerBaseCurrency() async throws {
    let transport = FrankfurterFixtures.transport(["NOK": (200, FrankfurterFixtures.friday), "JPY": (200, FrankfurterFixtures.yenFriday)])
    let pairs: Set = [CurrencyPair(base: Self.nok, quote: Self.eur), CurrencyPair(base: Self.jpy, quote: Self.eur)]
    let rates = try await Self.client(transport).rates(for: pairs, on: MoneyReadsFixture.date("2026-11-20"))
    #expect(rates.count == 2)
    #expect(transport.requests.map { FrankfurterFixtures.query($0)["base"] } == ["JPY", "NOK"])
    #expect(transport.requests.allSatisfy { FrankfurterFixtures.query($0)["quotes"] == "EUR" })
  }

  @Test func shouldTakeFridaysRateForAWeekendDayAtOnce() async throws {
    let transport = FrankfurterFixtures.transport(["NOK": (200, FrankfurterFixtures.friday)])
    let pair = CurrencyPair(base: Self.nok, quote: Self.eur)
    let saturdayMorning = Date(timeIntervalSince1970: 1_795_251_600)
    for day in ["2026-11-21", "2026-11-22"] {
      let rates = try await Self.client(transport, at: saturdayMorning).rates(for: [pair], on: MoneyReadsFixture.date(day))
      #expect(rates[pair]?.text == "0.093301", "\(day) has no rate of its own, so Friday's is final")
    }
  }

  @Test func shouldLeaveOutAnEarlierRateWhileTheAskedDayMayStillBePublished() async throws {
    let transport = FrankfurterFixtures.transport(["NOK": (200, FrankfurterFixtures.friday)])
    let pair = CurrencyPair(base: Self.nok, quote: Self.eur)
    let mondayMorning = Date(timeIntervalSince1970: 1_795_420_800)
    let monday = try await Self.client(transport, at: mondayMorning).rates(for: [pair], on: MoneyReadsFixture.date("2026-11-23"))
    #expect(monday.isEmpty, "Monday's rate is published in the afternoon")
  }

  @Test func shouldJudgeWhenAnEarlierDaysRateIsFinal() {
    let cases: [(answered: String, asked: String, today: String, final: Bool)] = [
      ("2026-11-20", "2026-11-20", "2026-11-20", true),
      ("2026-11-20", "2026-11-21", "2026-11-21", true),
      ("2026-11-20", "2026-11-22", "2026-11-21", true),
      ("2026-11-19", "2026-11-22", "2026-11-23", false),
      ("2026-11-20", "2026-11-23", "2026-11-23", false),
      ("2026-11-20", "2026-11-23", "2026-11-24", false),
      ("2026-11-20", "2026-11-23", "2026-11-25", true),
      ("2026-12-24", "2026-12-25", "2026-12-26", false),
      ("2026-12-24", "2026-12-25", "2026-12-27", true),
      ("2026-11-21", "2026-11-20", "2026-11-30", false),
    ]
    for entry in cases {
      let final = FrankfurterRatesClient.isFinal(
        answeredFor: MoneyReadsFixture.date(entry.answered), asked: MoneyReadsFixture.date(entry.asked), today: MoneyReadsFixture.date(entry.today))
      #expect(final == entry.final, "\(entry)")
    }
  }

  @Test func shouldReadFrankfurtsDateForToday() {
    #expect(FrankfurterRatesClient.publisherToday(at: Date(timeIntervalSince1970: 1_795_388_400)) == MoneyReadsFixture.date("2026-11-23"))
    #expect(FrankfurterRatesClient.publisherToday(at: Date(timeIntervalSince1970: 1_795_388_399)) == MoneyReadsFixture.date("2026-11-22"))
  }

  @Test func shouldLeaveOutACurrencyTheBankDoesNotQuoteAndKeepTheRest() async throws {
    let transport = FrankfurterFixtures.transport(["NOK": (200, FrankfurterFixtures.friday), "AED": (422, FrankfurterFixtures.notQuoted)])
    let quoted = CurrencyPair(base: Self.nok, quote: Self.eur)
    let rates = try await Self.client(transport).rates(for: [quoted, CurrencyPair(base: Self.aed, quote: Self.eur)], on: MoneyReadsFixture.date("2026-11-20"))
    #expect(rates == [quoted: MoneyReadsFixture.decimal("0.093301")])
  }

  @Test func shouldLeaveOutAPairTheAnswerOmits() async throws {
    let transport = FrankfurterFixtures.transport(["EUR": (200, FrankfurterFixtures.empty)])
    let rates = try await Self.client(transport).rates(for: [CurrencyPair(base: Self.eur, quote: Self.aed)], on: MoneyReadsFixture.date("2026-11-20"))
    #expect(rates.isEmpty)
  }

  @Test func shouldFailTheDateOnAServerErrorAnUnreadableAnswerOrNoConnection() async {
    let pair = CurrencyPair(base: Self.nok, quote: Self.eur)
    let day = MoneyReadsFixture.date("2026-11-20")
    let overloaded = Self.client(FrankfurterFixtures.transport(["NOK": (503, FrankfurterFixtures.overloaded)]))
    let unreadable = Self.client(FrankfurterFixtures.transport(["NOK": (200, FrankfurterFixtures.notAnArray)]))
    let offline = Self.client(StubHTTPTransport(error: URLError(.notConnectedToInternet)))

    #expect(await Self.failure { () throws(RatesClientError) in _ = try await overloaded.rates(for: [pair], on: day) } == .refused(status: 503))
    #expect(await Self.failure { () throws(RatesClientError) in _ = try await unreadable.rates(for: [pair], on: day) } == .unreadable("network.decoding"))
    #expect(await Self.failure { () throws(RatesClientError) in _ = try await offline.rates(for: [pair], on: day) } == .unavailable("network.transport"))
  }

  @Test func shouldRecordWhatItFetchesThroughTheRateFiller() async throws {
    let store = try MemoirStore.openInMemory(.main)
    let friday = MoneyReadsFixture.date("2026-11-20")
    try await store.write { transaction in
      try FinanceFixture.settings(home: Self.eur).create(in: &transaction)
      try FinanceFixture.expense(1, amountMinor: 10_000, currency: Self.nok, on: friday).create(in: &transaction)
    }
    let transport = FrankfurterFixtures.transport(["NOK": (200, FrankfurterFixtures.friday)])
    let report = try await RateFiller(client: Self.client(transport)).fill(store, today: MoneyReadsFixture.date("2026-11-23"))
    #expect(report.recordedRates == 1)
    let ledger = try await FinanceFixture.ledger(in: store)
    #expect(ledger.rates == [FxRateRecord(base: Self.nok, quote: Self.eur, date: friday, rate: MoneyReadsFixture.decimal("0.093301"))])
    #expect(ledger.converter?.homeAmount(of: try #require(ledger.expenses.first)) == .converted(933))
  }
}
