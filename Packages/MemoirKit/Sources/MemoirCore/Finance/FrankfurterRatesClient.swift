import Foundation
import ShadowCore
import ShadowNetworking

/// Daily reference rates of the European Central Bank from Frankfurter (`api.frankfurter.dev`), which needs no key: one request per base currency
/// and date to `/v2/providers/ecb/rates`, carrying only the base, the quote currencies and the date. Rates are read from the answer's decimal digits,
/// never through a binary float.
///
/// The service answers a day without a publication (a weekend, a TARGET holiday, or today before about 16:00 in Frankfurt) with the latest earlier
/// rate and that rate's own `date`. A recorded rate is final (first writer wins), so an earlier rate is taken for the asked day only once nothing can
/// still be published for it: the day is a weekend and the answer is the Friday before it, or the day ended in Frankfurt at least a day ago. Until then
/// the pair is left out and asked again later. A currency the bank does not quote is refused with 422 (404 on the older API) and left out.
public struct FrankfurterRatesClient: RatesClient {
  public static let host = "api.frankfurter.dev"
  static let path = "v2/providers/ecb/rates"
  static let publisherZone = "Europe/Berlin"
  static let unsupportedStatuses: Set<Int> = [404, 422]
  /// `URLSession` would otherwise send the app's name and build, the CFNetwork and Darwin versions, and the device's preferred languages.
  static let headers = ["User-Agent": "exchange-rates", "Accept-Language": "en"]

  private let client: APIClient
  private let now: @Sendable () -> Date

  public init(transport: any HTTPTransport = URLSessionTransport(), now: @escaping @Sendable () -> Date = { Date() }) {
    var components = URLComponents()
    components.scheme = "https"
    components.host = Self.host
    guard let url = components.url else { preconditionFailure("an https URL with a host is valid") }
    client = APIClient(baseURL: url, transport: transport)
    self.now = now
  }

  public func rates(for pairs: Set<CurrencyPair>, on date: LocalDate) async throws(RatesClientError) -> [CurrencyPair: DecimalText] {
    let today = Self.publisherToday(at: now())
    var rates = [CurrencyPair: DecimalText]()
    for (base, quotes) in Dictionary(grouping: pairs, by: \.base).sorted(by: { $0.key.code < $1.key.code }) {
      let wanted = Set(quotes.map(\.quote))
      guard let rows = try await fetch(base: base, quotes: wanted, on: date) else { continue }
      for row in rows where row.base == base.code {
        guard let quote = CurrencyCode(row.quote), wanted.contains(quote), let answered = LocalDate(isoString: row.date),
          Self.isFinal(answeredFor: answered, asked: date, today: today), let rate = Self.positive(row.rate)
        else { continue }
        rates[CurrencyPair(base: base, quote: quote)] = rate
      }
    }
    return rates
  }

  /// Whether an answer dated `answered` is the rate the bank will ever have for `asked`, judged on Frankfurt's `today`.
  static func isFinal(answeredFor answered: LocalDate, asked: LocalDate, today: LocalDate) -> Bool {
    if answered == asked { return true }
    guard answered < asked else { return false }
    if [.saturday, .sunday].contains(asked.weekday), answered == lastWeekday(before: asked) { return true }
    guard let settled = today.adding(days: -2) else { return false }
    return asked <= settled
  }

  static func publisherToday(at instant: Date) -> LocalDate {
    let clock = IssueClock(zoneIdentifier: publisherZone) ?? IssueClock(fixedOffsetMinutes: 60)
    let millis = Int64((instant.timeIntervalSince1970 * 1000).rounded(.down))
    return (try? clock?.localDate(at: millis)) ?? .earliest
  }

  private static func lastWeekday(before date: LocalDate) -> LocalDate? {
    var day = date.adding(days: -1)
    while let current = day, [.saturday, .sunday].contains(current.weekday) { day = current.adding(days: -1) }
    return day
  }

  private static func positive(_ rate: Decimal) -> DecimalText? {
    guard rate > 0 else { return nil }
    return DecimalText(rate.description)
  }

  private func fetch(base: CurrencyCode, quotes: Set<CurrencyCode>, on date: LocalDate) async throws(RatesClientError) -> [Row]? {
    let query = [
      URLQueryItem(name: "date", value: date.isoString), URLQueryItem(name: "base", value: base.code),
      URLQueryItem(name: "quotes", value: quotes.map(\.code).sorted().joined(separator: ",")),
    ]
    do throws(NetworkError) {
      return try await client.send(Endpoint<[Row]>(path: Self.path, queryItems: query, headers: Self.headers))
    } catch {
      switch error {
      case .unacceptableStatus(let status, _, _) where Self.unsupportedStatuses.contains(status): return nil
      case .unacceptableStatus(let status, _, _): throw .refused(status: status)
      case .decoding: throw .unreadable(error.code)
      case .encoding, .transport, .nonHTTPResponse, .cancelled, .underlying: throw .unavailable(error.code)
      }
    }
  }

  struct Row: Decodable, Sendable {
    let date: String
    let base: String
    let quote: String
    let rate: Decimal
  }
}
