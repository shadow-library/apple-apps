import Foundation
import ShadowCore
import Testing

@testable import NovelForgeCore

@Suite("Pinned disclosure sources")
struct PinnedDisclosureSourcesTests {
  private static func fact(_ key: String, unlock: FactUnlock) -> DisclosureFact {
    DisclosureFact(
      factKey: key, text: "Mara is the \(key).", constraintNote: "Only hint.", writerNote: "Keep it close.", terms: ["crown"], allowedClues: ["a ring"],
      subjects: ["mara"], source: .generated, disclosedInChapter: 4, revealChapter: 6, unlock: unlock)
  }

  static func sources() throws -> WriterDisclosureSources {
    let condition = try #require(UnlockCondition(validating: OrderedJSON(["all": [["chapter": 3]]])))
    return WriterDisclosureSources(
      chapter: 2, lockedFacts: [fact("heir", unlock: .condition(condition)), fact("twin", unlock: .unreadable)], ending: "She takes the crown.",
      endingQuestion: "Will she rule?", laterVolumes: [LaterVolume(volumeKey: "two", title: "Crown", objective: "Rule.", body: "The court turns.")],
      plannerPages: [DisclosurePage(address: BibleDocAddress(section: "project", slug: "ending"), body: "The ending.")],
      volumeOrdinals: [JSString("one"): 1, JSString("two"): 2], currentVolumeOrdinal: 1)
  }

  @Test func shouldRebuildEverySourceFieldAfterAJSONRoundTrip() throws {
    let sources = try Self.sources()
    let bytes = try JSONEncoder().encode(PinnedDisclosureSources(sources))
    #expect(try JSONDecoder().decode(PinnedDisclosureSources.self, from: bytes).sources == sources)
  }

  /// A field added to the sources and left out of the pinned mirror would round-trip as its default; the fixture must set every one.
  @Test func shouldSetEveryFieldOfTheSourcesInTheFixture() throws {
    var empty: [String] = []
    Self.collectUnset(try Self.sources(), path: "sources", into: &empty)
    #expect(empty.isEmpty, "unset in the fixture: \(empty)")
  }

  private static func collectUnset(_ value: Any, path: String, into unset: inout [String]) {
    let mirror = Mirror(reflecting: value)
    switch mirror.displayStyle {
    case .optional:
      guard let wrapped = mirror.children.first else { return unset.append(path) }
      collectUnset(wrapped.value, path: path, into: &unset)
    case .collection, .dictionary, .set:
      if mirror.children.isEmpty { unset.append(path) }
      for (index, child) in mirror.children.enumerated() { collectUnset(child.value, path: "\(path)[\(index)]", into: &unset) }
    case .struct, .tuple:
      for (index, child) in mirror.children.enumerated() { collectUnset(child.value, path: "\(path).\(child.label ?? String(index))", into: &unset) }
    default:
      return
    }
  }
}
