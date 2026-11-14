import Testing

@testable import Catalog

@Suite("SpacingToken")
struct SpacingTokenTests {
  @Test("should list spacing tokens in strictly increasing order")
  func increasesMonotonically() {
    let values = SpacingToken.allCases.map(\.value)
    #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 })
  }
}
