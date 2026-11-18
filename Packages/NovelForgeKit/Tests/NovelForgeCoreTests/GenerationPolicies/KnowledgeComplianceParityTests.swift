import Testing

@testable import NovelForgeCore

struct KnowledgeComplianceParityTests {
  private struct Merged: Decodable {
    let knowledgeCompliant: Bool
    let findings: [FindingFixture]
    let writerFindings: [FindingFixture]
  }

  private struct Case: Decodable {
    let compliance: ComplianceFixture?
    let prescan: [LeakFixture]
    let forbidden: [FactFixture]?
    let result: Merged
  }

  @Test func shouldMatchTheReferenceKnowledgeMerge() throws {
    let cases: [Case] = try GenerationFixtures.load("knowledge")
    #expect(cases.count >= 14)
    for (index, row) in cases.enumerated() {
      let merged = KnowledgeCompliance.merge(row.compliance?.compliance, prescan: row.prescan.map(\.leak), forbidden: row.forbidden?.map(\.fact) ?? [])
      #expect(merged.knowledgeCompliant == row.result.knowledgeCompliant, "case \(index)")
      #expect(merged.findings == row.result.findings.findings, "findings of case \(index)")
      #expect(merged.writerFindings == row.result.writerFindings.findings, "writer findings of case \(index)")
    }
    #expect(cases.filter { !$0.result.knowledgeCompliant }.count > 8)
  }
}
