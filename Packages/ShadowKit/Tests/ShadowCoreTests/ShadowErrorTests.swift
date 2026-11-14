import Foundation
import ShadowCore
import Testing

private enum SampleError: ShadowError {
  case missing

  var code: String { "sample.missing" }
  var errorDescription: String? { "Nothing here." }
}

@Suite("ShadowError")
struct ShadowErrorTests {
  @Test("should describe itself with its code and message")
  func describesWithCode() {
    #expect(SampleError.missing.description == "sample.missing: Nothing here.")
    #expect(SampleError.missing.localizedDescription == "Nothing here.")
  }
}
