import Foundation
import ShadowTestSupport

/// Answers in the shape `api.frankfurter.dev/v2/providers/ecb/rates` gives, written for these tests: an array of rows, each with the date the rate is
/// for, the base, the quote and the rate as a JSON number.
enum FrankfurterFixtures {
  static let friday = """
    [{"date":"2026-11-20","base":"NOK","quote":"EUR","rate":0.093301},{"date":"2026-11-20","base":"NOK","quote":"USD","rate":0.10254}]
    """
  static let longRate = """
    [{"date":"2026-11-18","base":"JPY","quote":"EUR","rate":0.00573561234567891}]
    """
  static let yenFriday = """
    [{"date":"2026-11-20","base":"JPY","quote":"EUR","rate":0.0057356}]
    """
  static let empty = "[]"
  static let notQuoted = """
    {"status":422,"message":"ECB doesn't quote AED; try base=EUR"}
    """
  static let overloaded = """
    {"status":503,"message":"try again later"}
    """
  static let notAnArray = """
    {"rates":{"EUR":0.093301}}
    """

  /// Frankfurt at 17:00 on Monday 2026-11-23, after that day's publication.
  static let mondayEvening = Date(timeIntervalSince1970: 1_795_449_600)

  /// Answers each request by its base currency, and records every request.
  static func transport(_ answers: [String: (status: Int, json: String)]) -> StubHTTPTransport {
    StubHTTPTransport { request in
      let base = URLComponents(url: request.url ?? URL(fileURLWithPath: "/"), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "base" }?.value ?? ""
      let answer = answers[base] ?? (404, #"{"message":"not found"}"#)
      return try StubHTTPTransport.response(to: request, statusCode: answer.status, data: Data(answer.json.utf8))
    }
  }

  static func query(_ request: URLRequest) -> [String: String] {
    let items = URLComponents(url: request.url ?? URL(fileURLWithPath: "/"), resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
  }
}
