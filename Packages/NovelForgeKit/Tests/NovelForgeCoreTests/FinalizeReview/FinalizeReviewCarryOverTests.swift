import ShadowCore
import Testing

@testable import NovelForgeCore

/// Replays the reference's reads and answers natively: answers keyed by revision and item key with a proposal digest, carried at read time. The reference forgets
/// an answer once a read of the same revision proposes something else for a keep or edit, or leaves the item out; natively the answer stands. Items whose
/// answers may part from then on are marked, as are routine keeps given while marked and skips inherited from a marked item.
private struct CarryReplay {
  let base: OrderedJSON
  var chain: [RevisionReview] = []
  var lapsed = Set<JSString>()
  var held = Set<JSString>()
  var inherited = Set<JSString>()
  var marked = Set<JSString>()
  var reads: [String: Int] = [:]

  var resolved: [FinalizeReviewItem] { resolveReviewChain(chain) }

  private func answer(_ key: JSString) -> FinalizeAnswer? {
    chain.last?.answers.last { JSString($0.itemKey) == key && !$0.autoKept }
  }

  private mutating func record(_ answer: FinalizeAnswer) {
    guard var latest = chain.popLast() else { return }
    latest.answers.removeAll { $0.itemKey.jsEquals(answer.itemKey) }
    latest.answers.append(answer)
    chain.append(latest)
  }

  mutating func apply(_ step: OrderedJSON) throws {
    switch try step.frText("op") {
    case "read":
      let revision = String(try step.frInt("revision"))
      let built = buildReviewItems(
        try fixtureMaterial(base, extraction: try step.frField("extraction"), isolated: try step.frFlag("isolated"), autoKeep: try fixtureCategories(step["autoKeep"])))
      if chain.last?.revision.jsEquals(revision) == true {
        chain[chain.count - 1].items = built
      } else {
        inherited = marked
        lapsed = []
        held = []
        chain.append(RevisionReview(revision: revision, items: built, answers: []))
      }
      reads[revision, default: 0] += 1
      marked = Set(built.map { JSString($0.itemKey) }.filter { lapsed.contains($0) || held.contains($0) || (answer($0) == nil && inherited.contains($0)) })
      let present = Set(built.map { JSString($0.itemKey) })
      for answer in chain.last?.answers ?? [] where !answer.autoKept && !present.contains(JSString(answer.itemKey)) { lapsed.insert(JSString(answer.itemKey)) }
      for item in built {
        guard let answer = answer(JSString(item.itemKey)), answer.decision != .skipped, answer.proposalDigest != item.proposed.digest else { continue }
        lapsed.insert(JSString(item.itemKey))
      }
    case "decide":
      let key = try step.frText("itemKey")
      let item = try (chain.last?.items.first { $0.itemKey.jsEquals(key) }).orThrow("item \(key)")
      let edited = try step.frField("edited")
      record(
        FinalizeAnswer(
          answering: item, decision: try FinalizeDecision(rawValue: try step.frText("decision")).orThrow("decision"), edited: edited.frIsNull ? nil : try fixtureProposal(edited),
          reason: step.frOptionalText("reason")))
      for set in [\CarryReplay.lapsed, \.held, \.marked] { self[keyPath: set].remove(JSString(key)) }
    case "keepRoutine":
      for item in resolved where item.triage == .routine && item.decision == nil { record(FinalizeAnswer(answering: item, decision: .kept)) }
      held.formUnion(marked)
    default:
      throw FixtureShapeError(description: "op \(step.jsonText)")
    }
  }
}

private struct ReplayTally {
  var compared = 0
  var marked = 0
  var mismatches: [String] = []
}

private func replay(_ steps: [OrderedJSON], base: OrderedJSON, label: String) throws -> (CarryReplay, ReplayTally) {
  var replay = CarryReplay(base: base)
  var tally = ReplayTally()
  for (index, step) in steps.enumerated() {
    try replay.apply(step)
    let expected = try step.frField("after").frList
    let resolved = replay.resolved
    #expect(resolved.map(\.itemKey) == expected.compactMap { $0["itemKey"]?.stringValue }, "\(label) step \(index)")
    for (item, reference) in zip(resolved, expected) {
      if replay.marked.contains(JSString(item.itemKey)) {
        tally.marked += 1
        continue
      }
      tally.compared += 1
      if reviewCanonical(item.answerJSON) != reviewCanonical(reference) { tally.mismatches.append("\(label) step \(index) \(item.itemKey)") }
    }
  }
  return (replay, tally)
}

struct FinalizeReviewCarryOverTests {
  private static let fixture = Result { try FinalizeReviewFixture.load("carry.json") }

  private func named(_ name: String) throws -> [OrderedJSON] {
    try (try Self.fixture.get().frField("named").frList.first { $0["name"]?.stringValue == name }).orThrow(name).frField("steps").frList
  }

  private func base() throws -> OrderedJSON { try Self.fixture.get().frField("base") }

  @Test(arguments: [
    "should never ask a skipped item again, even when the revision is read again",
    "should carry a skip into the next revision's review even when the re-read words the update differently",
    "should carry a keep only onto the change the author saw",
  ])
  func shouldCarryAnswersAsTheReferenceService(_ name: String) throws {
    let (_, tally) = try replay(try named(name), base: try base(), label: name)
    #expect(tally.mismatches.isEmpty, "\(tally.mismatches)")
    #expect(tally.marked == 0)
  }

  @Test func shouldCarryEveryGeneratedSequenceAsTheReferenceOutsideTheMarkedItems() throws {
    let sequences = try Self.fixture.get().frField("generated").frList
    #expect(sequences.count == 50)
    var total = ReplayTally()
    for (index, sequence) in sequences.enumerated() {
      let (replayed, tally) = try replay(try sequence.frField("steps").frList, base: try base(), label: "sequence \(index)")
      if replayed.reads.values.allSatisfy({ $0 <= 2 }) { #expect(tally.marked == 0, "sequence \(index) reads each revision at most twice") }
      total.compared += tally.compared
      total.marked += tally.marked
      total.mismatches += tally.mismatches
    }
    #expect(total.mismatches.isEmpty, "\(total.mismatches)")
    #expect(total.compared > 20 * total.marked)
    #expect(total.marked > 0)
  }

  @Test func shouldCarryAKeepAgainWhenALaterReadProposesWhatTheAuthorKept() throws {
    let steps = try named("divergence: a keep given on a proposal comes back when a later read proposes it again")
    let (replayed, tally) = try replay(steps, base: try base(), label: "proposal back")
    #expect(tally.mismatches.isEmpty)
    let state = try #require(replayed.resolved.first { $0.itemKey == "character_state:mira" })
    #expect(state.decision == .kept)
    let reference = try #require(steps.last?.frField("after").frList.first { $0["itemKey"]?.stringValue == "character_state:mira" })
    #expect(reference["decision"]?.frIsNull == true)
  }

  @Test func shouldLeaveAnEarlierSkipOverruledOnceTheAuthorKeptTheItemAtThisRevision() throws {
    let steps = try named("divergence: an earlier revision skip stays overruled by a keep that stopped carrying")
    let (replayed, tally) = try replay(steps, base: try base(), label: "skip overruled")
    #expect(tally.mismatches.isEmpty)
    let state = try #require(replayed.resolved.first { $0.itemKey == "character_state:mira" })
    #expect(state.decision == nil)
    let reference = try #require(steps.last?.frField("after").frList.first { $0["itemKey"]?.stringValue == "character_state:mira" })
    #expect(reference["decision"]?.stringValue == "skipped")
  }

  @Test func shouldKeepASkipThroughAReadThatLeavesTheItemOut() throws {
    let steps = try named("divergence: a skip outlives a read that leaves the item out")
    let (replayed, tally) = try replay(steps, base: try base(), label: "item left out")
    #expect(tally.mismatches.isEmpty)
    let thread = try #require(replayed.resolved.first { $0.itemKey == "promise:thread:lamp_debt" })
    #expect(thread.decision == .skipped)
    let reference = try #require(steps.last?.frField("after").frList.first { $0["itemKey"]?.stringValue == "promise:thread:lamp_debt" })
    #expect(reference["decision"]?.frIsNull == true)
  }

  @Test func shouldCarryASkipAcrossRevisionsButNeverASummarySkip() {
    let summary = FinalizeReviewItem(
      itemKey: "summary", category: .summary, triage: .consequential, basis: .inferred, subjectKey: "summary", claim: "c", evidence: nil, proposed: .summary(text: "Mira climbs."),
      flag: nil, dependents: nil, decision: nil, edited: nil, reason: nil, autoKept: false)
    let appearance = FinalizeReviewItem(
      itemKey: "appearance:mira", category: .appearance, triage: .routine, basis: .observed, subjectKey: "mira", claim: "c", evidence: nil,
      proposed: .appearance(entityKey: "mira"),
      flag: nil, dependents: nil, decision: nil, edited: nil, reason: nil, autoKept: false)
    let skips = [FinalizeAnswer(answering: summary, decision: .skipped, reason: "no"), FinalizeAnswer(answering: appearance, decision: .skipped, reason: "no")]
    let chain = [
      RevisionReview(revision: "a", items: [summary, appearance], answers: skips), RevisionReview(revision: "b", items: [summary, appearance], answers: []),
    ]
    #expect(resolveReviewChain(chain).map(\.decision) == [nil, .skipped])
    #expect(resolveReviewChain(Array(chain.prefix(1))).map(\.decision) == [.skipped, .skipped])
  }

  @Test func shouldIgnoreAnAutomaticKeepWhenItCarriesAnswers() {
    let state = FinalizeReviewItem(
      itemKey: "character_state:mira", category: .characterState, triage: .routine, basis: .observed, subjectKey: "mira", claim: "c", evidence: nil,
      proposed: .characterState(.init(entityKey: "mira", location: "the tower", evidence: "x")), flag: nil, dependents: nil, decision: nil, edited: nil, reason: nil,
      autoKept: false)
    var auto = FinalizeAnswer(answering: state, decision: .kept)
    auto.autoKept = true
    #expect(carryAnswers(onto: [state], answers: [auto], earlier: []).map(\.decision) == [nil])
  }
}
