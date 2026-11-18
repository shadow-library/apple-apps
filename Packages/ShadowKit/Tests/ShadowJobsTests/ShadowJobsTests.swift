import ShadowJobs
import Testing

@Suite("ShadowJobs")
struct ShadowJobsTests {
  @Test("should identify the library under its reverse-DNS owner")
  func identifiesLibrary() {
    #expect(ShadowJobs.identifier == "com.shadow.library.shadowjobs")
  }
}
