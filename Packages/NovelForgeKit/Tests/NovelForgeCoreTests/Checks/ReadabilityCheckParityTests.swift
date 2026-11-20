import ShadowText
import Testing

@testable import NovelForgeCore

struct ReadabilityCheckParityTests {
  @Test func shouldMatchTheReferenceEvidence() throws {
    let rows = try ChecksFixtures.load("readability.json").map(\.items)
    #expect(rows.count > 30)
    var measured = 0
    var limited = 0
    for (index, row) in rows.enumerated() {
      let evidence = ReadabilityCheck.assessReadability(row[0].text)
      #expect(evidence?.json == (row[1] == .null ? nil : row[1]), "evidence of case \(index)")
      #expect(evidence.map(ReadabilityCheck.renderReadabilityEvidence).map(OrderedJSON.string) ?? .null == row[2], "render of case \(index)")
      #expect(OrderedJSON.optional(ReadabilityCheck.readabilityNote(evidence)) == row[3], "note of case \(index)")
      if evidence != nil { measured += 1 }
      if row[3] != .null { limited += 1 }
    }
    #expect(measured > 15 && limited > 10 && measured < rows.count)
  }

  @Test func shouldMatchTheReferenceConstants() throws {
    let constants = try #require(ChecksFixtures.load("similes.json")[0].objectValue)
    #expect(ReadabilityCheck.prefix == constants["readabilityPrefix"]?.text)
    #expect(Double(ReadabilityCheck.minWords) == constants["readabilityMinWords"]?.numberValue)
    #expect(ReadabilityCheck.averageSentenceWordsMax == constants["averageSentenceWordsMax"]?.numberValue)
    #expect(ReadabilityCheck.longSentenceShareMax == constants["longSentenceShareMax"]?.numberValue)
    #expect(ReadabilityCheck.averageParagraphWordsMax == constants["averageParagraphWordsMax"]?.numberValue)
    #expect(ReadabilityCheck.readingGradeMax == constants["readingGradeMax"]?.numberValue)
    #expect(ReadabilityCheck.ornateHitsPer1000WordsMax == constants["ornateHitsPer1000WordsMax"]?.numberValue)
    #expect(Double(ReadabilityCheck.ornateHitsMin) == constants["ornateHitsMin"]?.numberValue)
  }

  @Test func shouldReturnNoNoteWithoutEvidence() {
    #expect(ReadabilityCheck.readabilityNote(nil) == nil)
    #expect(ReadabilityCheck.assessReadability("") == nil)
  }
}
