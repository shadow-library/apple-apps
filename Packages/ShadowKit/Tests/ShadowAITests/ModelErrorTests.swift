import Foundation
import ShadowCore
import ShadowNetworking
import Testing

@testable import ShadowAI

@Suite("ModelError")
struct ModelErrorTests {
  private static let everyCase: [ModelError] = [
    .rateLimited(retryAfter: .seconds(30)), .rateLimited(retryAfter: nil), .overloaded(retryAfter: nil), .overloaded(retryAfter: .seconds(8)), .server(status: 500),
    .transport(.timedOut), .transport(.notConnectedToInternet),
    .transport(.badURL), .midStream(code: "overloaded_error", message: "Overloaded"), .invalidRequest("bad"), .authentication, .forbidden("no"), .insufficientCredits,
    .dataPolicy("policy"), .noEligibleModel, .malformedResponse("garbled"), .notRecorded, .cancelled,
  ]

  private static func status(_ code: Int, headers: [String: String] = [:]) -> NetworkError {
    .unacceptableStatus(code: code, headers: headers, body: Data("{\"error\":\"x\"}".utf8))
  }

  @Test("should give every case a code and a plain description")
  func describesEveryCase() {
    for error in Self.everyCase {
      #expect(error.code.hasPrefix("model."))
      #expect(error.errorDescription?.isEmpty == false)
      #expect(error.description.hasPrefix(error.code))
    }
    let distinctCases = Self.everyCase.reduce(into: [String: ModelError]()) { $0[$1.code] = $0[$1.code] ?? $1 }
    #expect(distinctCases.count == 14)
  }

  @Test(
    "should map network errors by status class",
    arguments: [
      (status(401), ModelError.authentication),
      (status(402), .insufficientCredits),
      (status(403), .forbidden("The provider responded with status 403.")),
      (status(404), .invalidRequest("The provider responded with status 404.")),
      (status(408), .transport(.timedOut)),
      (status(413), .invalidRequest("The provider responded with status 413.")),
      (status(429), .rateLimited(retryAfter: nil)),
      (status(429, headers: ["retry-after": "17"]), .rateLimited(retryAfter: .seconds(17))),
      (status(500), .server(status: 500)),
      (status(502), .server(status: 502)),
      (status(503), .overloaded(retryAfter: nil)),
      (status(503, headers: ["retry-after": "5"]), .overloaded(retryAfter: .seconds(5))),
      (status(529), .overloaded(retryAfter: nil)),
      (status(529, headers: ["retry-after": "12"]), .overloaded(retryAfter: .seconds(12))),
      (status(302), .malformedResponse("The provider responded with unexpected status 302.")),
      (.transport(URLError(.networkConnectionLost)), .transport(.networkConnectionLost)),
      (.transport(URLError(.cancelled)), .cancelled),
      (.cancelled, .cancelled),
      (.underlying(CancellationError()), .cancelled),
      (.encoding("bad body"), .invalidRequest("bad body")),
      (.decoding("bad json"), .malformedResponse("bad json")),
      (.nonHTTPResponse, .malformedResponse("The provider's response is not HTTP.")),
    ]
  )
  func mapsNetworkErrors(network: NetworkError, expected: ModelError) {
    #expect(ModelError(network) == expected)
  }

  @Test(
    "should convert foreign errors",
    arguments: [
      (ModelError.overloaded(retryAfter: nil) as any Error, ModelError.overloaded(retryAfter: nil)),
      (NetworkError.unacceptableStatus(code: 401, headers: [:], body: Data()), .authentication),
      (URLError(.timedOut), .transport(.timedOut)),
      (URLError(.cancelled), .cancelled),
      (CancellationError(), .cancelled),
    ]
  )
  func convertsForeignErrors(error: any Error, expected: ModelError) {
    #expect(ModelError(converting: error) == expected)
  }

  @Test(
    "should expose the provider's retry-after for rate limits and overload only",
    arguments: [
      (ModelError.rateLimited(retryAfter: .seconds(3)), Duration?.some(.seconds(3))),
      (.overloaded(retryAfter: .seconds(7)), .seconds(7)),
      (.overloaded(retryAfter: nil), nil),
      (.server(status: 503), nil),
      (.transport(.timedOut), nil),
    ]
  )
  func exposesRetryAfter(error: ModelError, expected: Duration?) {
    #expect(error.retryAfter == expected)
  }

  @Test("should treat an unknown error as an unreadable reply")
  func convertsUnknownErrors() {
    struct Unknown: Error {}
    guard case .malformedResponse = ModelError(converting: Unknown()) else {
      Issue.record("expected malformedResponse")
      return
    }
  }

  @Test(
    "should retry only transient failures",
    arguments: [
      (ModelError.rateLimited(retryAfter: nil), true),
      (.rateLimited(retryAfter: .seconds(3)), true),
      (.overloaded(retryAfter: nil), true),
      (.overloaded(retryAfter: .seconds(4)), true),
      (.server(status: 500), true),
      (.server(status: 502), true),
      (.server(status: 503), true),
      (.server(status: 504), true),
      (.server(status: 501), false),
      (.server(status: 505), false),
      (.server(status: 418), false),
      (.transport(.timedOut), true),
      (.transport(.networkConnectionLost), true),
      (.transport(.notConnectedToInternet), true),
      (.transport(.cannotFindHost), true),
      (.transport(.cannotConnectToHost), true),
      (.transport(.dnsLookupFailed), true),
      (.transport(.badURL), false),
      (.transport(.secureConnectionFailed), false),
      (.transport(.serverCertificateUntrusted), false),
      (.midStream(code: "x", message: "y"), false),
      (.invalidRequest("x"), false),
      (.authentication, false),
      (.forbidden("x"), false),
      (.insufficientCredits, false),
      (.dataPolicy("x"), false),
      (.noEligibleModel, false),
      (.malformedResponse("x"), false),
      (.notRecorded, false),
      (.cancelled, false),
    ]
  )
  func classifiesRetryable(error: ModelError, expected: Bool) {
    #expect(error.isRetryable == expected)
  }
}
