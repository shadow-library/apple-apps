import Foundation
import ShadowNetworking
import Testing

@Suite("NetworkError")
struct NetworkErrorTests {
  @Test(
    "should read retry-after given in whole seconds",
    arguments: [("30", Duration.seconds(30)), ("0", .seconds(0)), (" 5 ", .seconds(5))]
  )
  func readsRetryAfterSeconds(value: String, expected: Duration) {
    #expect(NetworkError.unacceptableStatus(code: 429, headers: ["retry-after": value], body: Data()).retryAfter == expected)
  }

  @Test(
    "should ignore retry-after values that are not whole seconds",
    arguments: ["Wed, 21 Oct 2015 07:28:00 GMT", "-1", "+1", "1.5", "", "99999999999999999999999"]
  )
  func ignoresOtherRetryAfterValues(value: String) {
    #expect(NetworkError.unacceptableStatus(code: 503, headers: ["retry-after": value], body: Data()).retryAfter == nil)
  }

  @Test("should have no retry-after without the header or a status")
  func hasNoRetryAfterOtherwise() {
    #expect(NetworkError.unacceptableStatus(code: 429, headers: [:], body: Data()).retryAfter == nil)
    #expect(NetworkError.transport(URLError(.timedOut)).retryAfter == nil)
  }
}
