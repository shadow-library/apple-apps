import Foundation
import Testing

@testable import ShadowAI

@Suite("CatalogRefresh")
struct CatalogRefreshTests {
  static let now = Date(timeIntervalSince1970: 1_800_000_000)
  static let week: TimeInterval = 7 * 86_400

  @Test(arguments: [
    (nil as TimeInterval?, false, true),
    (nil as TimeInterval?, true, true),
    (0.0, false, false),
    (3_600.0, false, false),
    (week - 1, false, false),
    (week, false, true),
    (week + 1, false, true),
    (30 * 86_400.0, false, true),
    (0.0, true, true),
    (60.0, true, true),
    (-60.0, false, true),
  ])
  func shouldDecideWhetherARefreshIsDue(age: TimeInterval?, keyJustValidated: Bool, expected: Bool) {
    let last = age.map { Self.now.addingTimeInterval(-$0) }
    #expect(CatalogRefresh.isDue(lastRefresh: last, now: Self.now, keyJustValidated: keyJustValidated) == expected)
  }
}
