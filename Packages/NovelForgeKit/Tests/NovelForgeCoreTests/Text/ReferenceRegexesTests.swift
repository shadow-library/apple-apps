import Foundation
import Testing

struct ReferenceRegexesTests {
  private struct Collected: Decodable {
    let files: [String]
    let count: Int
    let regexes: [Entry]
  }

  private struct Entry: Decodable {
    let location: String
    let kind: String
    let source: String?
    let flags: String?
  }

  @Test func shouldHoldTheReferenceRegexesWithRepositoryRelativeLocations() throws {
    let collected = try ReferenceFixture.decode(Collected.self, from: "text/reference-regexes.json")
    let raw = String(decoding: try ReferenceFixture.data("text/reference-regexes.json"), as: UTF8.self)
    #expect(collected.files.count == 28)
    #expect(collected.regexes.count == 127)
    #expect(collected.count == collected.regexes.count)
    #expect(Set(collected.regexes.map { $0.location.prefix { $0 != ":" } }).count == 13)
    for path in collected.files + collected.regexes.map(\.location) {
      #expect(!path.hasPrefix("/") && !path.hasPrefix("~"), "\(path) is absolute")
    }
    for marker in ["/Users/", "/home/", "/private/", "/var/folders/", "file://"] {
      #expect(!raw.contains(marker), "the fixture names a machine path")
    }
  }
}
