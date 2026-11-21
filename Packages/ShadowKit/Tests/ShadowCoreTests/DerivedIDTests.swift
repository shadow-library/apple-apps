import Foundation
import Testing

@testable import ShadowCore

@Suite("derivedID", TestTimeLimit.quick)
struct DerivedIDTests {
  @Test func shouldKeepEveryIdItHasEverDerived() {
    #expect(derivedID("com.shadow.library.novelforgekit.plan-card", "job-1").uuidString == "8E887007-3EED-8278-9049-E76C2510A9B1")
  }

  @Test func shouldSetTheVersion8AndVariantBits() {
    let text = derivedID("com.shadow.library.test.bits", "name").lowercasedString
    #expect(Array(text)[14] == "8")
    #expect(["8", "9", "a", "b"].contains(Array(text)[19]))
  }

  @Test func shouldSeparateDomainsAndNames() {
    let ids: Set<UUID> = [derivedID("com.shadow.library.a.x", "1"), derivedID("com.shadow.library.a.y", "1"), derivedID("com.shadow.library.a.x", "2")]
    #expect(ids.count == 3)
  }
}
