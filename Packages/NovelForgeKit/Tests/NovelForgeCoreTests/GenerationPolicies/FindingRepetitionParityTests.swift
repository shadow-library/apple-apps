import Testing

@testable import NovelForgeCore

struct FindingRepetitionParityTests {
  private struct Case: Decodable {
    let previous: [FindingFixture]
    let current: [FindingFixture]
    let same: Bool
  }

  @Test func shouldMatchTheReferenceSameFinding() throws {
    let cases: [Case] = try GenerationFixtures.load("same-finding")
    #expect(cases.count > 130)
    for (index, row) in cases.enumerated() {
      #expect(FindingRepetition.isRepeated(row.current.findings, previous: row.previous.findings) == row.same, "case \(index)")
    }
    #expect(cases.filter(\.same).count > 40 && cases.filter { !$0.same }.count > 40)
  }
}
