import Foundation
import Testing

@testable import NovelForgeCore

struct BibleDocsParityTests {
  private struct Address: Decodable {
    let section: String
    let slug: String
  }

  private struct AccessCase: Decodable {
    let address: BibleDocAddress
    let access: BibleDocAccess

    init(from decoder: any Decoder) throws {
      var container = try decoder.unkeyedContainer()
      address = BibleDocAddress(section: try container.decode(String.self), slug: try container.decode(String.self))
      access = BibleDocAccess(writerExcluded: try container.decode(Bool.self), plannerOnly: try container.decode(Bool.self))
    }
  }

  private struct Fixture: Decodable {
    let organisedTimeline: Address
    let openQuestions: Address
    let access: [AccessCase]
  }

  @Test func shouldHoldTheReferenceReservedAddresses() throws {
    let fixture = try ReferenceFixture.decode(Fixture.self, from: "write-policy/bible-docs.json")
    #expect(BibleDocAddress.organisedTimeline == BibleDocAddress(section: fixture.organisedTimeline.section, slug: fixture.organisedTimeline.slug))
    #expect(BibleDocAddress.openQuestions == BibleDocAddress(section: fixture.openQuestions.section, slug: fixture.openQuestions.slug))
  }

  @Test func shouldReportPageAccessAsTheReference() throws {
    let fixture = try ReferenceFixture.decode(Fixture.self, from: "write-policy/bible-docs.json")
    #expect(fixture.access.count > 100)
    #expect(fixture.access.contains { $0.access.plannerOnly } && fixture.access.contains { $0.access.writerExcluded && !$0.access.plannerOnly })
    for item in fixture.access {
      #expect(bibleDocAccess(item.address) == item.access, "\(item.address)")
      #expect(isWriterExcludedBibleDoc(item.address) == item.access.writerExcluded, "\(item.address)")
      #expect(isPlannerOnlyBibleDoc(item.address) == item.access.plannerOnly, "\(item.address)")
    }
  }

  @Test func shouldReadOnlyTheReservedPagesAsWriterExcluded() {
    let excluded = [("project", "timeline"), ("project", "open-questions"), ("story_state", "volume-plan"), ("story_state", "volumes"), ("plot", "escalation-map")]
    for (section, slug) in excluded { #expect(isWriterExcludedBibleDoc(BibleDocAddress(section: section, slug: slug)), "\(section)/\(slug)") }
    #expect(!isWriterExcludedBibleDoc(BibleDocAddress(section: "project", slug: "Timeline")))
    #expect(isPlannerOnlyBibleDoc(.organisedTimeline) && isPlannerOnlyBibleDoc(.openQuestions))
    #expect(!isPlannerOnlyBibleDoc(BibleDocAddress(section: "plot", slug: "escalation-map")))
  }

  @Test func shouldCompareAddressesByCodeUnits() {
    let composed = BibleDocAddress(section: "project", slug: "\u{e9}")
    let decomposed = BibleDocAddress(section: "project", slug: "e\u{301}")
    #expect(composed != decomposed)
    #expect(Set([composed, decomposed, BibleDocAddress(section: "project", slug: "\u{e9}")]).count == 2)
    #expect(composed.hashValue == BibleDocAddress(section: "project", slug: "\u{e9}").hashValue)
  }
}
