import Foundation
import ShadowNetworking
import Testing

@Suite("HTTP header helpers")
struct HTTPHeaderHelperTests {
  private static func response(_ headers: [String: String]) throws -> HTTPURLResponse {
    let url = try #require(URL(string: "https://api.example.com"))
    return try #require(HTTPURLResponse(url: url, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: headers))
  }

  @Test(
    "should read retry-after from lowercased headers",
    arguments: [
      (["retry-after": "30"], Duration.seconds(30)), (["retry-after": "0"], .seconds(0)), (["retry-after": " 5 "], .seconds(5)),
      (["retry-after": "9223372036854775807"], .seconds(Int.max)),
    ]
  )
  func readsRetryAfter(headers: [String: String], expected: Duration) {
    #expect(NetworkError.retryAfter(in: headers) == expected)
  }

  @Test(
    "should ignore a retry-after that is absent or not whole seconds",
    arguments: [
      [:], ["retry-after": ""], ["retry-after": "-1"], ["retry-after": "+1"], ["retry-after": "1.5"], ["retry-after": "Wed, 21 Oct 2015 07:28:00 GMT"],
      ["retry-after": "99999999999999999999"], ["Retry-After": "30"], ["x-retry-after": "30"],
    ] as [[String: String]]
  )
  func ignoresOtherHeaders(headers: [String: String]) {
    #expect(NetworkError.retryAfter(in: headers) == nil)
  }

  @Test("should read the same retry-after through the error and the helper")
  func agreesWithError() {
    let headers = ["retry-after": "12"]

    #expect(NetworkError.unacceptableStatus(code: 429, headers: headers, body: Data()).retryAfter == NetworkError.retryAfter(in: headers))
  }

  @Test("should lowercase every header name and keep its value")
  func lowercasesNames() throws {
    let fields = try Self.response(["Retry-After": "7", "Content-Type": "text/event-stream", "X-REQUEST-ID": "req_1"]).lowercasedHeaderFields

    #expect(fields == ["retry-after": "7", "content-type": "text/event-stream", "x-request-id": "req_1"])
  }

  @Test("should return no fields for a response without headers")
  func returnsNothingWithoutHeaders() throws {
    #expect(try Self.response([:]).lowercasedHeaderFields.isEmpty)
  }

  @Test("should feed the lowercased fields to the retry-after helper")
  func composes() throws {
    #expect(NetworkError.retryAfter(in: try Self.response(["Retry-After": "3"]).lowercasedHeaderFields) == .seconds(3))
  }
}
