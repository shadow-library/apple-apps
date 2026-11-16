import Foundation
import Testing

@testable import NovelForgeCore

struct MechanicalCheckParityTests {
  @Test func shouldMatchTheReferenceFindings() throws {
    let rows = try ChecksFixtures.load("mechanical.json").map(\.items)
    #expect(rows.count > 250)
    var hard = 0
    var soft = 0
    for (index, row) in rows.enumerated() {
      let findings = MechanicalCheck.checkDraftMechanics(row[0].text, priorMarkdown: row[1].items.map(\.text), target: ChecksFixtures.target(row[2]))
      #expect(OrderedJSON.array(findings.map(\.json)) == row[3], "case \(index)")
      for (actual, expected) in zip(findings, row[3].items) { #expect(actual.text.jsEquals(expected["text"]?.text ?? ""), "text of case \(index)") }
      hard += findings.filter { $0.severity == .hard }.count
      soft += findings.filter { $0.severity == .soft }.count
    }
    #expect(hard > 80 && soft > 200)
  }

  @Test func shouldMatchTheReferenceSimileFrameOveruse() throws {
    let rows = try ChecksFixtures.load("similes.json")[1].items.map(\.items)
    #expect(rows.count > 30)
    var flagged = 0
    for (index, row) in rows.enumerated() {
      let overuse = MechanicalCheck.findSimileFrameOveruse(row[0].text)
      #expect(OrderedJSON.array(overuse.map(\.json)) == row[1], "case \(index)")
      flagged += overuse.count
    }
    #expect(flagged > 10)
  }

  @Test func shouldMatchTheReferenceBoundaryEcho() throws {
    let rows = try ChecksFixtures.load("similes.json")[2].items.map(\.items)
    var found = 0
    for (index, row) in rows.enumerated() {
      let echo = MechanicalCheck.findBoundaryEcho(row[0].text, row[1] == .null ? nil : row[1].text)
      #expect(OrderedJSON.optional(echo) == row[2], "case \(index)")
      if echo != nil { found += 1 }
    }
    #expect(found > 10 && found < rows.count)
  }

  @Test func shouldMatchTheReferenceDuplicatedParagraphs() throws {
    let rows = try ChecksFixtures.load("similes.json")[3].items.map(\.items)
    var found = 0
    for (index, row) in rows.enumerated() {
      let duplicated = row[1] == .null ? MechanicalCheck.findDuplicatedParagraphs(row[0].text) : MechanicalCheck.findDuplicatedParagraphs(row[0].text, minWords: row[1].int)
      #expect(OrderedJSON.strings(duplicated) == row[2], "case \(index)")
      found += duplicated.count
    }
    #expect(found > 20)
  }

  @Test func shouldMatchTheReferenceHardBounds() throws {
    let rows = try ChecksFixtures.load("similes.json")[4].items.map(\.items)
    for (index, row) in rows.enumerated() {
      let bounds = MechanicalCheck.resolveWordCountHardBounds(ResolvedWordTarget(json: row[0].objectValue == nil ? .null : row[0]))
      #expect(OrderedJSON.record([("min", .number(bounds.min)), ("max", .number(bounds.max))]) == row[1], "case \(index)")
    }
  }

  @Test func shouldMatchTheReferenceConstants() throws {
    let constants = try #require(ChecksFixtures.load("similes.json")[0].objectValue)
    #expect(MechanicalCheck.prefix == constants["mechanicalPrefix"]?.text)
    #expect(MechanicalCheck.wordCountHardSlack == constants["wordCountHardSlack"]?.numberValue)
    #expect(MechanicalCheck.wordCountHardMin == constants["wordCountHardMin"]?.numberValue)
    #expect(MechanicalCheck.wordCountHardMax == constants["wordCountHardMax"]?.numberValue)
    #expect(Double(MechanicalCheck.duplicateParagraphMinWords) == constants["duplicateParagraphMinWords"]?.numberValue)
    let frames = try #require(constants["simileFrames"]?.arrayValue)
    #expect(MechanicalCheck.simileFrames.count == frames.count)
    for (frame, expected) in zip(MechanicalCheck.simileFrames, frames) {
      #expect(frame.label == expected.items[0].text)
      #expect(frame.pattern.source == expected.items[1].text.replacingOccurrences(of: "\\u2019", with: "’"))
      #expect(frame.pattern.flags == expected.items[2].text)
    }
  }
}
