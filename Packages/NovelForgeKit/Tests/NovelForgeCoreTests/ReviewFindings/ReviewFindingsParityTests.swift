import Foundation
import ShadowCore
import ShadowText
import Testing

@testable import NovelForgeCore

struct ReviewFindingsParityTests {
  private let fixture: ReviewFindingsFixture

  init() throws {
    fixture = try ReviewFindingsFixture.load()
  }

  private func expectOutcome(_ actual: ReviewOutcome, _ expected: OrderedJSON, _ label: String) throws {
    let (shape, metrics) = try expectedOutcome(expected)
    #expect(outcomeJSON(actual) == shape, "outcome of \(label)")
    #expect(actual.metrics == metrics, "metrics of \(label)")
  }

  @Test func shouldHashTheReviewedBodyAsTheReferenceDoes() throws {
    let rows = try fixture.rows("hash")
    #expect(rows.count > 10)
    for (index, row) in rows.enumerated() { #expect(hashReviewedBody(try fixture.body(row[0])) == row[1].text, "hash of case \(index)") }
  }

  @Test func shouldJudgeStalenessByRevisionAndBodyHash() throws {
    let rows = try fixture.rows("stale")
    var stale = 0
    for (index, row) in rows.enumerated() {
      let current = row[1].isNull ? nil : try reviewedText(row[1])
      let result = ReviewFindings.isStale(try reviewedText(row[0]), current: current)
      #expect(result == row[2].flag, "staleness of case \(index)")
      if result { stale += 1 }
    }
    #expect(stale > 10 && stale < rows.count)
  }

  @Test func shouldFingerprintFindingsAsTheReferenceDoes() throws {
    let rows = try fixture.rows("fingerprint")
    #expect(rows.count > 300)
    for (index, row) in rows.enumerated() {
      let kind = try ChapterReviewKind(rawValue: row[0].text).orFail("kind")
      let category = try ReviewFindingCategory(rawValue: row[1].text).orFail("category")
      #expect(ReviewFindings.fingerprint(kind: kind, category: category, text: row[2].text) == row[3].text, "fingerprint of case \(index)")
    }
  }

  @Test func shouldKeepOnlyEvidenceThatIsInTheProse() throws {
    let rows = try fixture.rows("evidence")
    var kept = 0
    for (index, row) in rows.enumerated() {
      let result = ReviewFindings.verifiedEvidence(body: try fixture.body(row[0]), candidates: row[1].items.map(\.optionalText))
      #expect(OrderedJSON.optional(result) == row[2], "evidence of case \(index)")
      if result != nil { kept += 1 }
    }
    #expect(kept > 20 && kept < rows.count - 20)
  }

  @Test func shouldSettleFindingsWithIdsEvidenceAndFingerprints() throws {
    let rows = try fixture.rows("settle")
    var settled = 0
    for (index, row) in rows.enumerated() {
      let kind = try ChapterReviewKind(rawValue: row[0].text).orFail("kind")
      let result = ReviewFindings.settle(kind: kind, body: try fixture.body(row[1]), drafts: try reviewDrafts(row[2]))
      #expect(OrderedJSON.array(result.map(findingJSON)) == row[3], "settled findings of case \(index)")
      settled += result.count
    }
    #expect(settled > 40)
  }

  @Test func shouldReadDispositionFromSeveritiesAndFailure() throws {
    let rows = try fixture.rows("disposition")
    var seen = Set<String>()
    for row in rows {
      let findings = row[0].texts().map { ReviewFinding(id: "f", severity: StoredEnum(rawValue: $0), category: .known(.continuity), text: "", fingerprint: "") }
      let result = ReviewFindings.disposition(of: findings, failed: row[1].flag)
      #expect(result.rawValue == row[2].text, "disposition of \(row[0].jsonText)")
      seen.insert(result.rawValue)
    }
    #expect(seen == Set(ChapterReviewDisposition.allCases.map(\.rawValue)))
  }

  @Test func shouldCloseFindingsByRemedyExceptFixingMyself() throws {
    let rows = try fixture.rows("open")
    var closed = 0
    for (index, row) in rows.enumerated() {
      let findings = row[0].texts().map { ReviewFinding(id: $0, severity: .known(.blocking), category: .known(.continuity), text: "", fingerprint: "") }
      let remedies = try row[1].items.map { try remedyRecord(finding: $0.field("findingId").text, action: $0.field("action").text) }
      let open = ReviewFindings.open(findings, remedies: remedies).map(\.id)
      #expect(open == row[2].texts(), "open findings of case \(index)")
      closed += findings.count - open.count
    }
    #expect(closed > 40)
  }

  @Test func shouldGateOnOpenBlockingFindingsOfTheCurrentJudgeReview() throws {
    let rows = try fixture.rows("gate")
    var stale = 0
    var held = 0
    for (index, row) in rows.enumerated() {
      let latest = try row[0].isNull ? nil : latestJudge(row[0])
      let draftRow = row[1]
      let draft = ReviewedText(draftRevision: String(try draftRow.field("revision").index()), body: try fixture.body(draftRow.field("body")))
      let open = ReviewFindings.openBlocking(latest: latest, draft: draft)
      #expect(open.map(\.id) == row[2].texts(), "open blocking of case \(index)")
      let overrides = ReviewFindings.approvalOverrides(latest: latest, draft: draft)
      let expected = try row[3].items.map {
        ApprovalOverride(
          findingId: try $0.field("findingId").text, fingerprint: try $0.field("fingerprint").text, action: .overridden, reason: try $0.field("reason").text)
      }
      #expect(overrides == expected, "overrides of case \(index)")
      if open.isEmpty { stale += 1 } else { held += 1 }
    }
    #expect(stale > 20 && held > 15)
  }

  @Test func shouldBuildJudgeOutcomes() throws {
    let rows = try fixture.rows("judge")
    var dispositions = Set<String>()
    for (index, row) in rows.enumerated() {
      let input = row[1]
      let evidence = JudgeEvidence(
        output: input["output"].flatMap { $0.isNull ? nil : $0 }.map(judgeOutput), hasBrief: try input.field("hasBrief").flag,
        hasEndingContract: try input.field("hasEndingContract").flag, lockedFromReader: try reviewFacts(input["lockedFromReader"]),
        hiddenFromCast: try reviewFacts(input["hiddenFromCast"]),
        leaks: try input.field("leaks").items.map {
          KnowledgeLeakIssue(factKey: try $0.field("factKey").text, term: try $0.field("term").text, excerpt: try $0.field("excerpt").text)
        })
      let result = ReviewFindings.judgeOutcome(body: try fixture.body(row[0]), evidence: evidence)
      try expectOutcome(result, row[2], "judge case \(index)")
      dispositions.insert(result.disposition.rawValue)
    }
    #expect(dispositions == Set(ChapterReviewDisposition.allCases.map(\.rawValue)))
  }

  @Test func shouldBuildGraphJudgeOutcomes() throws {
    let rows = try fixture.rows("graph")
    var categories = Set<String>()
    for (index, row) in rows.enumerated() {
      let findings = try row[1].field("findings").items.map {
        CheckFinding(severity: try $0.field("severity").text == "hard" ? .hard : .soft, text: try $0.field("text").text)
      }
      let result = ReviewFindings.graphJudgeOutcome(body: try fixture.body(row[0]), verdict: row[1]["verdict"]?.optionalText, findings: findings)
      try expectOutcome(result, row[2], "graph case \(index)")
      for finding in result.findings { categories.insert(finding.category.rawValue) }
    }
    #expect(categories.isSuperset(of: ["continuity", "brief", "ending", "knowledge", "readability", "mechanics"]))
  }

  @Test func shouldBuildEditorialOutcomes() throws {
    let rows = try fixture.rows("editorial")
    var dispositions = Set<String>()
    var slips = 0
    for (index, row) in rows.enumerated() {
      let result = ReviewFindings.editorialOutcome(body: try fixture.body(row[0]), output: try reviewOutput(row[1]), hasBrief: row[2].flag)
      try expectOutcome(result, row[3], "editorial case \(index)")
      dispositions.insert(result.disposition.rawValue)
      slips += result.findings.filter { $0.category == .known(.proofreading) }.count
    }
    #expect(dispositions.isSuperset(of: ["clear", "issues", "blocking"]) && slips > 50)
  }

  @Test func shouldBuildMechanicsOutcomes() throws {
    let rows = try fixture.rows("mechanics")
    var withFindings = 0
    for (index, row) in rows.enumerated() {
      let target: ResolvedWordTarget =
        row[2].isNull ? .resolve() : .resolve(WordTargetSource(wordTargetMin: try row[2].field("min").numberValue, wordTargetMax: try row[2].field("max").numberValue))
      let result = ReviewFindings.mechanicsOutcome(body: try fixture.body(row[0]), priorBodies: try row[1].items.map(fixture.body), target: target)
      try expectOutcome(result, row[3], "mechanics case \(index)")
      if !result.findings.isEmpty { withFindings += 1 }
    }
    #expect(withFindings > 15 && withFindings < rows.count)
  }

  @Test func shouldBuildReadabilityOutcomes() throws {
    let rows = try fixture.rows("readability")
    var dispositions = Set<String>()
    for (index, row) in rows.enumerated() {
      let result = ReviewFindings.readabilityOutcome(body: try fixture.body(row[0]))
      try expectOutcome(result, row[1], "readability case \(index)")
      dispositions.insert(result.disposition.rawValue)
    }
    #expect(dispositions.isSuperset(of: ["clear", "issues"]))
  }

  @Test func shouldRenderTheJudgeTask() throws {
    let rows = try fixture.rows("tasks")
    var withBrief = 0
    for (index, row) in rows.enumerated() {
      let json = row[0]
      let task = JudgeTask(
        body: try fixture.body(json.field("body")), chapterBrief: json["chapterBrief"]?.optionalText, endingContract: try json.field("endingContract").text,
        lockedFromReader: try reviewFacts(json["lockedFromReader"]), hiddenFromCast: try reviewFacts(json["hiddenFromCast"]),
        readabilityEvidence: json["readabilityEvidence"]?.optionalText, settled: try settledFindings(json.field("settled")))
      #expect(ReviewPrompts.renderJudgeTask(task) == row[1].text, "task of case \(index)")
      if row[1].text.jsIncludes("## BRIEF") { withBrief += 1 }
    }
    #expect(withBrief > 10 && withBrief < rows.count - 10)
  }

  @Test func shouldRenderSettledFindings() throws {
    for row in try fixture.rows("settled") {
      #expect(ReviewPrompts.renderSettledFindings(try settledFindings(row[0])) == row[1].text)
    }
  }
}

private func remedyRecord(finding: String, action: String) -> ReviewRemedyRecord {
  ReviewRemedyRecord(novel: reviewNovel, review: reviewID, finding: finding, remedy: ReviewRemedy(action: StoredEnum(rawValue: action), fingerprint: "fp"))
}

private let reviewNovel = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
private let reviewID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!

private func latestJudge(_ json: OrderedJSON) throws -> LatestJudgeReview {
  LatestJudgeReview(
    reviewed: try reviewedText(json),
    findings: try json.field("findings").items.map {
      ReviewFinding(
        id: try $0.field("id").text, severity: StoredEnum(rawValue: try $0.field("severity").text), category: .known(.continuity), text: "",
        fingerprint: try $0.field("fingerprint").text)
    },
    remedies: try json.field("remedies").items.map { try remedyRecord(finding: $0.field("findingId").text, action: $0.field("action").text) })
}

private func judgeOutput(_ json: OrderedJSON) -> JudgeOutput {
  JudgeOutput(
    verdict: json["verdict"]?.text ?? "",
    findings: (json["findings"]?.items ?? []).map { JudgeOutputFinding(severity: $0["severity"]?.text == "hard" ? .hard : .soft, text: $0["text"]?.text ?? "") },
    endingCompliance: reviewCompliance(json["endingCompliance"]), knowledgeCompliance: reviewCompliance(json["knowledgeCompliance"]),
    briefCompliance: reviewCompliance(json["briefCompliance"]), readabilityCompliance: reviewCompliance(json["readabilityCompliance"]))
}

private func reviewOutput(_ json: OrderedJSON) throws -> ReviewOutput {
  ReviewOutput(
    disposition: try ReviewOutputDisposition(rawValue: json.field("disposition").text).orFail("disposition"), note: json["note"]?.optionalText,
    findings: try json["findings"].map { list in
      try list.items.map {
        EditorialFinding(
          severity: try EditorialSeverity(rawValue: $0.field("severity").text).orFail("severity"), text: try $0.field("text").text, evidence: $0["evidence"]?.optionalText)
      }
    },
    proofreading: try json["proofreading"].map { list in
      try list.items.map {
        ProofreadSlip(
          kind: try ProofreadKind(rawValue: $0.field("kind").text).orFail("kind"), quote: try $0.field("quote").text, fix: try $0.field("fix").text,
          reason: $0["reason"]?.optionalText)
      }
    })
}

private func settledFindings(_ json: OrderedJSON) throws -> [SettledFinding] {
  try json.items.map {
    SettledFinding(
      fingerprint: try $0.field("fingerprint").text, action: StoredEnum(rawValue: try $0.field("action").text), reason: $0["reason"]?.optionalText, text: try $0.field("text").text)
  }
}
