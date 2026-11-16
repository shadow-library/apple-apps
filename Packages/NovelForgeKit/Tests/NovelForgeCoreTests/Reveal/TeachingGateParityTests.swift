import Foundation
import Testing

@testable import NovelForgeCore

private struct TeachingCase: Decodable {
  let chapter: Int
  let briefs: [TeachingBrief]
  let drafts: [TeachingDraft]
  let chapters: [TeachingChapter]
  let teacher: Int?
  let refused: Bool

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    chapter = try container.decode(Int.self)
    briefs = try container.decode([BriefRow].self).map(\.brief)
    drafts = try container.decode([DraftRow].self).map(\.draft)
    chapters = try container.decode([ChapterRow].self).map(\.chapter)
    teacher = try container.decodeOptional(Int.self)
    refused = try container.decode(Bool.self)
  }
}

private struct BriefRow: Decodable {
  let brief: TeachingBrief

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    brief = TeachingBrief(chapter: try container.decode(Int.self), knowledgeContract: try container.decode(FixtureJSON.self).value)
  }
}

private struct DraftRow: Decodable {
  let draft: TeachingDraft

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    let chapter = try container.decode(Int.self)
    let status = try container.decode(String.self)
    let reviewStatus = try container.decode(String.self)
    guard let parsedStatus = DraftStatus(rawValue: status), let parsedReview = DraftReviewStatus(rawValue: reviewStatus) else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "unknown draft status")
    }
    draft = TeachingDraft(chapter: chapter, status: parsedStatus, reviewStatus: parsedReview)
  }
}

private struct ChapterRow: Decodable {
  let chapter: TeachingChapter

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    let number = try container.decode(Int.self)
    let status = try container.decode(String.self)
    guard let parsed = ChapterStatus(rawValue: status) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "unknown chapter status") }
    chapter = TeachingChapter(number: number, status: parsed)
  }
}

private struct BatchCase: Decodable {
  let chapters: [Int]
  let plans: [Int: OrderedJSON]
  let result: [Int]

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    chapters = try container.decode([Int].self)
    struct PlanRow: Decodable {
      let chapter: Int
      let contract: OrderedJSON

      init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        chapter = try container.decode(Int.self)
        contract = try container.decode(FixtureJSON.self).value
      }
    }
    plans = Dictionary(uniqueKeysWithValues: try container.decode([PlanRow].self).map { ($0.chapter, $0.contract) })
    result = try container.decode([Int].self)
  }
}

private struct TeachingFixture: Decodable {
  let teaching: [TeachingCase]
  let refusals: [String: String]
  let batches: [BatchCase]
}

struct TeachingGateParityTests {
  private static func load() throws -> TeachingFixture {
    try ReferenceFixture.decode(TeachingFixture.self, from: "reveal/teaching.json")
  }

  @Test func shouldCarryAtLeastThreeHundredCasesPerFunction() throws {
    let fixture = try Self.load()
    #expect(fixture.teaching.count >= 300)
    #expect(fixture.batches.count >= 300)
    #expect(fixture.teaching.contains { $0.refused } && fixture.teaching.contains { !$0.refused })
    #expect(fixture.batches.contains { $0.result.count < $0.chapters.count })
  }

  @Test func shouldNameTheLowestUnsettledTeacherAsTheReferenceDoes() throws {
    let bad = try Self.load().teaching.enumerated().filter { _, reference in
      unsettledTeacher(briefs: reference.briefs, drafts: reference.drafts, chapters: reference.chapters, before: reference.chapter) != reference.teacher
    }.map(\.offset)
    #expect(bad.isEmpty, "teachers differ for cases \(bad.prefix(10)) of \(bad.count)")
  }

  @Test func shouldRefuseWithTheReferenceMessageExactlyWhenATeacherIsUnsettled() throws {
    let fixture = try Self.load()
    let bad = fixture.teaching.enumerated().filter { _, reference in
      do throws(TeachingGateError) {
        try assertTeacherSettled(briefs: reference.briefs, drafts: reference.drafts, chapters: reference.chapters, before: reference.chapter)
        return reference.refused
      } catch {
        guard reference.refused, let teacher = reference.teacher, let expected = fixture.refusals["\(reference.chapter)/\(teacher)"] else { return true }
        return !(error.errorDescription ?? "").jsEquals(expected) || error.code != "DRF_016"
      }
    }.map(\.offset)
    #expect(bad.isEmpty, "refusals differ for cases \(bad.prefix(10)) of \(bad.count)")
  }

  @Test func shouldEndABatchAtTheFirstChapterWhosePlanTeachesAsTheReferenceDoes() throws {
    let bad = try Self.load().batches.enumerated().filter { untilFirstTeacher($1.chapters, plans: $1.plans) != $1.result }.map(\.offset)
    #expect(bad.isEmpty, "batches differ for cases \(bad.prefix(10)) of \(bad.count)")
  }
}
