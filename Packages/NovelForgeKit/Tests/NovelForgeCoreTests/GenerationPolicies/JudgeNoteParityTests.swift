import Testing

@testable import NovelForgeCore

struct JudgeNoteParityTests {
  private struct Case: Decodable {
    let findings: [FindingFixture]
    let readabilityNote: String?
    let note: String?
  }

  @Test func shouldMatchTheReferenceJudgeNote() throws {
    let cases: [Case] = try GenerationFixtures.load("judge-notes")
    #expect(cases.count == 8)
    for (index, row) in cases.enumerated() {
      #expect(JudgeNote.render(findings: row.findings.findings, readabilityNote: row.readabilityNote) == row.note, "case \(index)")
    }
    #expect(cases.contains { $0.note == nil } && cases.contains { $0.note != nil })
  }
}
