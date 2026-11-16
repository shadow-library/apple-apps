import Testing

@testable import ShadowStore

@Suite("StoreError")
struct StoreErrorTests {
  @Test("should expose a stable code for database failures")
  func shouldExposeStableCode() {
    #expect(StoreError.database("disk full").code == "store.database")
  }

  @Test("should include the underlying message in the description")
  func shouldIncludeMessageInDescription() {
    #expect(StoreError.database("disk full").errorDescription == "Database failure: disk full")
  }
}
