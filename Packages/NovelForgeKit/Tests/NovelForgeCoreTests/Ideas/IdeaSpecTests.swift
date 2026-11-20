import Foundation
import ShadowText
import Testing

@testable import NovelForgeCore

struct IdeaSpecTests {
  private struct Catalog: Decodable {
    let regexes: [Entry]
  }

  private struct Entry: Decodable {
    let location: String
    let source: String?
    let flags: String?
  }

  private func id(_ json: String) throws -> String {
    let identity = try #require(IdeaIdentity.shared)
    return identity.ideaId(of: try #require(try parseOps("[\(json)]").first))
  }

  private func entity(_ notes: String) throws -> String {
    let encoded = String(decoding: try JSONSerialization.data(withJSONObject: [notes]), as: UTF8.self)
    return #"{"op":"entity.upsert","entityKey":"mara","type":"character","notes":\#(encoded.dropFirst().dropLast())}"#
  }

  @Test func shouldPortEveryReferenceRegexVerbatim() throws {
    let catalog = try ReferenceFixture.decode(Catalog.self, from: "text/reference-regexes.json")
    let detector = try #require(NegationEchoDetector.shared)
    let echo = catalog.regexes.filter { $0.location.hasPrefix("apps/novel-forge-server/src/modules/refinement/negation-echo.ts:") }
    let ported = [detector.clauseBreak, detector.word, detector.possessive, detector.curlyApostrophe, detector.capitalLetter, detector.bullet, detector.statementRequest]
    #expect(ported.count == echo.count)
    for (regex, entry) in zip(ported, echo) {
      #expect(regex.source == entry.source, "\(entry.location)")
      #expect(regex.flags == entry.flags, "\(entry.location)")
    }
    let label = try #require(catalog.regexes.first { $0.location.hasPrefix("apps/novel-forge-server/src/modules/refinement/idea-id.ts:") })
    #expect(ProseRegex.whitespaceRunGlobal.source == label.source)
    #expect(ProseRegex.whitespaceRunGlobal.flags == label.flags)
  }

  @Test func shouldGiveTheSameIdeaTheSameIdWhateverTheKeyOrderOrMetadata() throws {
    let plain = try id(#"{"op":"entity.upsert","entityKey":"mara","type":"character","notes":"x","body":"y"}"#)
    #expect(try id(#"{"body":"y","notes":"x","type":"character","entityKey":"mara","op":"entity.upsert"}"#) == plain)
    #expect(try id(#"{"op":"entity.upsert","entityKey":"mara","type":"character","notes":"x","body":"y","quote":"q","rationale":"r","ideaId":"old"}"#) == plain)
    #expect(try id(#"{"op":"entity.upsert","entityKey":"mara","type":"character","notes":"x","body":"z"}"#) != plain)
    #expect(plain.count == 24 && plain.allSatisfy { $0.isHexDigit && !$0.isUppercase })
  }

  @Test func shouldGiveTextVariantsTheSameId() throws {
    let base = try id(try entity("The tower falls at dawn"))
    for variant in [
      "the tower falls at dawn", "THE TOWER FALLS AT DAWN", "  The tower falls at dawn\n", "The\ttower  falls\u{00A0}at\u{3000}dawn", "The\u{2028}tower\r\nfalls\u{FEFF}at dawn",
      "ＴＨＥ tower falls at dawn",
    ] {
      #expect(try id(try entity(variant)) == base, "\(variant.debugDescription)")
    }
    #expect(try id(try entity("café")) == id(try entity("cafe\u{0301}")))
    #expect(try id(try entity("ΟΔΟΣ")) == id(try entity("οδος")))
    #expect(try id(try entity("ΟΔΟΣ")) != id(try entity("οδοσ")))
    #expect(try id(try entity("İ")) == id(try entity("i\u{0307}")))
    #expect(try id(try entity("ﬁre")) == id(try entity("fire")))
    #expect(try id(try entity("a\u{200B}b")) != id(try entity("ab")))
    #expect(try id(try entity("a\u{0085}b")) != id(try entity("a b")))
    #expect(try id(try entity("The tower falls at dusk")) != base)
  }

  @Test func shouldOrderNestedKeysAndKeepArrayOrder() throws {
    let page = { (frontmatter: String) in try id(#"{"op":"bible_document.upsert","section":"world","slug":"harbour","frontmatter":\#(frontmatter)}"#) }
    #expect(try page(#"{"b":1,"a":{"d":1,"c":2},"10":"x","2":"y"}"#) == page(#"{"2":"y","10":"x","a":{"c":2,"d":1},"b":1}"#))
    #expect(try page(#"{"a":["x","y"]}"#) != page(#"{"a":["y","x"]}"#))
    #expect(try page(#"{"é":1}"#) == page(#"{"é":1}"#))
    #expect(try page(#"{"é":1}"#) != page(#"{"é":1}"#))
  }

  @Test func shouldDistinguishANullPatchFromAnAbsentField() throws {
    #expect(try id(#"{"op":"fact.upsert","factKey":"f","revealChapter":null}"#) != id(#"{"op":"fact.upsert","factKey":"f"}"#))
    #expect(try id(#"{"op":"brief.update","chapter":2,"startedEmpty":true}"#) == id(#"{"op":"brief.update","chapter":2}"#))
  }

  @Test func shouldStampIdempotentlyAndLeaveActionsUnstamped() throws {
    let identity = try #require(IdeaIdentity.shared)
    let ops = try parseOps(
      #"[{"op":"entity.upsert","entityKey":"mara","type":"character","notes":"x","ideaId":"stale"},{"op":"action.plan_chapter","chapter":3,"ideaId":"stale"}]"#)
    let stamped = identity.stampIdeaIds(ops)
    #expect(stamped[0].metadata.ideaId == identity.ideaId(of: ops[0]))
    #expect(stamped[1].metadata.ideaId == nil)
    #expect(identity.stampIdeaIds(stamped) == stamped)
  }

  @Test func shouldClipLabelsToTwoHundredFortyCodeUnitsWithoutAHalfPair() throws {
    let long = try #require(try parseOps(#"[{"op":"entity.upsert","entityKey":"mara","type":"character","notes":"\#(String(repeating: "x", count: 238))😀tail"}]"#).first)
    let label = try #require(ideaLabel(long))
    #expect(label.jsEquals("mara (character): " + String(repeating: "x", count: 238) + "…"))
    let flat = try #require(try parseOps(#"[{"op":"entity.upsert","entityKey":"mara","type":"character","notes":"a \t  \n b"}]"#).first)
    #expect(ideaLabel(flat) == "mara (character): a b")
  }

  @Test func shouldKeepPlannerOnlyPagesAndSecretsOutOfLabels() throws {
    let ops = try parseOps(
      #"[{"op":"bible_document.upsert","section":"project","slug":"timeline","body":"the ending"},{"op":"fact.upsert","factKey":"f1","body":"the truth"},{"op":"premise.update","ending":"x","endingQuestion":"y"}]"#
    )
    #expect(ops.compactMap(ideaLabel) == ["Page project/timeline", "Secret f1", "Story"])
  }

  @Test func shouldFindNoEchoBetweenAnEmptyBeforeOrAfter() throws {
    let detector = try #require(NegationEchoDetector.shared)
    #expect(detector.findNegationEchoes(before: "dragon", after: "").isEmpty)
    #expect(detector.findNegationEchoes(before: "", after: "no dragon").isEmpty)
  }

  @Test func shouldTreatHedgesAsOrdinaryTerms() throws {
    let detector = try #require(NegationEchoDetector.shared)
    let echoes = detector.findNegationEchoes(before: "maybe the tower falls", after: "no maybe, perhaps not")
    #expect(echoes.map(\.terms) == [["maybe"]])
  }

  @Test func shouldKeepTheOriginalTokenAndLowercaseByFinalSigma() throws {
    let detector = try #require(NegationEchoDetector.shared)
    #expect(detector.findNegationEchoes(before: "ΟΔΟΣ here", after: "no ΟΔΟΣ").map(\.terms) == [["οδος"]])
    #expect(detector.findNegationEchoes(before: "οδος", after: "no ΟΔΟΣ").map(\.terms) == [["οδος"]])
    #expect(detector.findNegationEchoes(before: "İstanbul", after: "no İstanbul").map(\.terms) == [["i\u{0307}stanbul"]])
  }

  @Test func shouldNotCountCJKTermsUnderFourCodeUnits() throws {
    let detector = try #require(NegationEchoDetector.shared)
    #expect(detector.findNegationEchoes(before: "王国王", after: "no 王国王").isEmpty)
    #expect(detector.findNegationEchoes(before: "王国王国", after: "no 王国王国").map(\.terms) == [["王国王国"]])
    #expect(detector.findNegationEchoes(before: "𠀀𠀀", after: "no 𠀀𠀀").map(\.terms) == [["𠀀𠀀"]])
  }

  @Test func shouldSplitClausesOnTheECMAScriptWhitespaceOnlyWhereTheReferenceDoes() throws {
    let detector = try #require(NegationEchoDetector.shared)
    for space in ["\t", "\u{000B}", "\u{000C}", "\u{00A0}", "\u{FEFF}", "\u{2028}", "\u{2029}", "\u{3000}"] {
      let found = detector.findNegationEchoes(before: "dragon", after: "  no dragon\(space)")
      #expect(found.map(\.excerpt) == ["no dragon"], "\(space.debugDescription)")
    }
    for kept in ["\u{0085}", "\u{200B}", "\u{180E}"] {
      let found = detector.findNegationEchoes(before: "dragon", after: "no dragon\(kept)")
      #expect(found.map(\.excerpt.jsLength) == [10], "\(kept.debugDescription)")
    }
  }

  @Test func shouldDropTheHalfPairWhereTheReferenceSlicesAnAstralCharacter() throws {
    let detector = try #require(NegationEchoDetector.shared)
    let prefix = "no dragon " + String(repeating: "x", count: 148)
    let after = prefix + "😀y"
    #expect(after.jsLength == 161)
    let excerpt = try #require(detector.findNegationEchoes(before: "dragon", after: after).first?.excerpt)
    #expect(excerpt.jsEquals(prefix + "…"))
  }

  @Test func shouldReturnRequestedNegationsInOrderOnce() throws {
    let detector = try #require(NegationEchoDetector.shared)
    #expect(detector.requestedNegations("say no dragon, no sword. no dragon") == ["dragon", "sword"])
    #expect(detector.requestedNegations("no dragon").isEmpty)
  }
}

struct IdeaRejectionSpecTests {
  private let context = RejectionContext(
    activeVolumeKey: "v1", states: [JSString("premise"): ArtifactState(exists: true, revision: 2, contentHash: "h")])

  @Test func shouldHoldANeverRejectionWhateverTheContext() {
    let entry = IdeaRejectionEntry(ideaId: "a", rejectionScope: .never, rejectionAnchor: nil)
    #expect(rejectionInScope(entry, context))
    #expect(rejectionInScope(entry, RejectionContext(activeVolumeKey: nil)))
    #expect(!rejectionInScope(IdeaRejectionEntry(ideaId: nil, rejectionScope: .never, rejectionAnchor: nil), context))
    #expect(!rejectionInScope(IdeaRejectionEntry(ideaId: "a", rejectionScope: nil, rejectionAnchor: nil), context))
  }

  @Test func shouldHoldANotNowRejectionWhileTheVolumeStaysActive() {
    func entry(_ key: String?) -> IdeaRejectionEntry { IdeaRejectionEntry(ideaId: "a", rejectionScope: .notNow, rejectionAnchor: .volume(key)) }
    #expect(rejectionInScope(entry("v1"), context))
    #expect(!rejectionInScope(entry("v2"), context))
    #expect(!rejectionInScope(entry(nil), context))
    #expect(rejectionInScope(entry(nil), RejectionContext(activeVolumeKey: nil)))
    #expect(!rejectionInScope(IdeaRejectionEntry(ideaId: "a", rejectionScope: .notNow, rejectionAnchor: nil), context))
    #expect(!rejectionInScope(IdeaRejectionEntry(ideaId: "a", rejectionScope: .notNow, rejectionAnchor: .states([])), context))
  }

  @Test func shouldHoldANotThisVersionRejectionWhileEveryAnchoredRecordIsUnchanged() {
    func entry(_ states: [(ref: String, state: ArtifactState)]) -> IdeaRejectionEntry {
      IdeaRejectionEntry(ideaId: "a", rejectionScope: .notThisVersion, rejectionAnchor: .states(states))
    }
    let same = ArtifactState(exists: true, revision: 2, contentHash: "h")
    #expect(rejectionInScope(entry([("premise", same)]), context))
    #expect(!rejectionInScope(entry([("premise", ArtifactState(exists: true, revision: 3, contentHash: "h"))]), context))
    #expect(!rejectionInScope(entry([("premise", ArtifactState(exists: true, revision: 2, contentHash: "other"))]), context))
    #expect(!rejectionInScope(entry([("premise", ArtifactState(exists: false, revision: 2, contentHash: "h"))]), context))
    #expect(rejectionInScope(entry([("entity:mara", .missing)]), context))
    #expect(!rejectionInScope(entry([("entity:mara", same)]), context))
    #expect(!rejectionInScope(entry([("premise", same), ("entity:mara", same)]), context))
    #expect(!rejectionInScope(entry([]), context))
    #expect(!rejectionInScope(IdeaRejectionEntry(ideaId: "a", rejectionScope: .notThisVersion, rejectionAnchor: .volume("v1")), context))
  }

  @Test func shouldAnchorEachScopeToWhatItWasRecordedAgainst() {
    #expect(rejectionAnchor(.never, context, refs: ["premise"]) == nil)
    #expect(rejectionAnchor(.notNow, context, refs: ["premise"]) == .volume("v1"))
    #expect(rejectionAnchor(.notNow, RejectionContext(activeVolumeKey: nil), refs: []) == .volume(nil))
    let anchor = rejectionAnchor(.notThisVersion, context, refs: ["premise", "entity:mara", "premise"])
    #expect(anchor?.json.jsonText == #"{"states":{"premise":{"exists":true,"revision":2,"contentHash":"h"},"entity:mara":{"exists":false,"revision":null,"contentHash":null}}}"#)
    #expect(rejectionAnchor(.notThisVersion, context, refs: []) == .states([]))
  }

  @Test func shouldReadTheAnchorsTheReferenceStores() throws {
    for json in [#"{"volumeKey":null}"#, #"{"volumeKey":"v1"}"#, #"{"states":{}}"#, #"{"states":{"a":{"exists":true,"revision":1,"contentHash":"h"}}}"#] {
      let anchor = try #require(RejectionAnchor(json: try OrderedJSON(parsing: json)))
      #expect(anchor.json.jsonText == json)
    }
    for json in [
      "null", #""text""#, "{}", #"{"volumeKey":5}"#, #"{"volumeKey":"v","states":{}}"#, #"{"states":[]}"#, #"{"states":{"a":{"exists":true}}}"#,
      #"{"states":{"a":{"exists":true,"revision":1.5,"contentHash":null}}}"#, #"{"states":{"a":{"exists":"yes","revision":null,"contentHash":null}}}"#,
    ] {
      #expect(RejectionAnchor(json: try OrderedJSON(parsing: json)) == nil, "\(json)")
    }
  }

  @Test func shouldLeaveInheritedNamesOutOfTheStatesTheReferenceTakesFromTheirPrototype() {
    let anchor = rejectionAnchor(.notThisVersion, RejectionContext(activeVolumeKey: nil), refs: ["constructor", "__proto__"])
    #expect(
      anchor?.json.jsonText == #"{"states":{"constructor":{"exists":false,"revision":null,"contentHash":null},"__proto__":{"exists":false,"revision":null,"contentHash":null}}}"#)
  }

  @Test func shouldPickTheActiveVolumeWithTheLowestOrdinal() {
    let volumes = [
      RejectionVolume(volumeKey: "c", ordinal: 3, state: .active), RejectionVolume(volumeKey: "a", ordinal: 1, state: .goalMet),
      RejectionVolume(volumeKey: "b", ordinal: 2, state: .active),
      RejectionVolume(volumeKey: "d", ordinal: 2, state: .active),
    ]
    #expect(activeVolumeKey(in: volumes) == "b")
    #expect(activeVolumeKey(in: [RejectionVolume(volumeKey: "x", ordinal: 1, state: .notStarted)]) == nil)
    #expect(activeVolumeKey(in: []) == nil)
    #expect(activeVolumeKey(in: [RejectionVolume(volumeKey: "x", ordinal: Int.max, state: .active)]) == "x")
  }

  @Test func shouldLoadOnlyTheStatesTheEntriesAndRefsName() {
    let entries = [
      IdeaRejectionEntry(ideaId: "a", rejectionScope: .notThisVersion, rejectionAnchor: .states([("premise", .missing), ("entity:mara", .missing)])),
      IdeaRejectionEntry(ideaId: "b", rejectionScope: .never, rejectionAnchor: .states([("fact:f1", .missing)])),
    ]
    #expect(rejectionStateRefs(for: entries, refs: ["premise", "volume:v1"]) == ["premise", "entity:mara", "volume:v1"])
    let state = ArtifactState(exists: true, revision: 1, contentHash: "h")
    let loaded = rejectionContext(for: entries, volumes: [], artifactStates: [JSString("premise"): state, JSString("fact:f1"): state])
    #expect(loaded.states == [JSString("premise"): state, JSString("entity:mara"): .missing])
    #expect(loaded.activeVolumeKey == nil)
  }

  @Test func shouldKeepEntriesThatAreNotRejections() {
    let kept = IdeaRejectionEntry(ideaId: "", rejectionScope: .notNow, rejectionAnchor: .volume("v9"))
    let plain = IdeaRejectionEntry(ideaId: "a", rejectionScope: nil, rejectionAnchor: nil)
    let lapsed = IdeaRejectionEntry(ideaId: "b", rejectionScope: .notNow, rejectionAnchor: .volume("v9"))
    let live = IdeaRejectionEntry(ideaId: "c", rejectionScope: .never, rejectionAnchor: nil)
    let volumes = [RejectionVolume(volumeKey: "v1", ordinal: 1, state: .active)]
    let result = withoutLapsedRejections([kept, plain, lapsed, live], rejection: { $0 }, volumes: volumes, artifactStates: [:])
    #expect(result == [kept, plain, live])
    #expect(withoutLapsedRejections([kept, plain], rejection: { $0 }, volumes: volumes, artifactStates: [:]) == [kept, plain])
  }

  @Test func shouldReturnNoActiveRejectionWithoutIdeaIdsOrMatches() {
    let entry = IdeaRejectionEntry(ideaId: "a", rejectionScope: .never, rejectionAnchor: nil)
    #expect(activeRejectedIdeas([], entries: [entry], volumes: [], artifactStates: [:]).isEmpty)
    #expect(activeRejectedIdeas(["b"], entries: [entry], volumes: [], artifactStates: [:]).isEmpty)
    #expect(activeRejectedIdeas(["a", "a"], entries: [entry], volumes: [], artifactStates: [:]) == [JSString("a")])
  }
}

struct IdeaFailClosedTests {
  private func split() throws -> (ChangeSetSplit, WritePolicyState) {
    let ops = try parseOps(#"[{"op":"entity.upsert","entityKey":"ee","type":"character"}]"#)
    let input = WritePolicyInput(ops: ops, authorMessage: "", mode: .auto, ideas: .card, hold: .none, state: WritePolicyState())
    return (WritePolicy.split(input), input.state)
  }

  @Test func shouldKeepTheSplitAndListNothingWhenTheIdentityIsUnavailable() throws {
    let (split, state) = try split()
    let identity = try #require(IdeaIdentity.shared)
    let everything = Set(split.ops.map { JSString(identity.ideaId(of: $0)) })
    #expect(IdeaIdentity.filterableIdeaIds(split, with: nil).isEmpty)
    #expect(IdeaIdentity.filterableIdeaIds(split, with: identity).count == 1)
    let unavailable = IdeaIdentity.dropRejectedIdeas(split, rejected: everything, current: state, with: nil)
    #expect(unavailable.split == split && unavailable.dropped.isEmpty)
    #expect(IdeaIdentity.dropRejectedIdeas(split, rejected: everything, current: state, with: identity).dropped.count == 1)
  }

  @Test func shouldReportAnUnavailableDetectorInsteadOfNoEchoes() throws {
    #expect(NegationEchoDetector.scan(before: "dragon", after: "no dragon", with: nil) == .unavailable)
    #expect(NegationEchoDetector.scanRequests("say no dragon", with: nil) == .unavailable)
    #expect(NegationEchoDetector.scan(before: "dragon", after: "no dragon") == .echoes([NegationEcho(terms: ["dragon"], excerpt: "no dragon")]))
    #expect(NegationEchoDetector.scanRequests("say no dragon") == .terms(["dragon"]))
  }

  @Test func shouldIgnoreSupersededRejections() throws {
    let identity = try #require(IdeaIdentity.shared)
    let (split, state) = try split()
    let id = identity.ideaId(of: split.ops[0])
    let superseded = IdeaRejectionEntry(ideaId: id, rejectionScope: .never, rejectionAnchor: nil, superseded: true)
    let live = IdeaRejectionEntry(ideaId: id, rejectionScope: .never, rejectionAnchor: nil)
    #expect(!rejectionInScope(superseded, RejectionContext(activeVolumeKey: nil)))
    let rejected = activeRejectedIdeas([id], entries: [superseded], volumes: [], artifactStates: [:])
    #expect(rejected.isEmpty)
    #expect(identity.dropRejectedIdeas(split, rejected: rejected, current: state).dropped.isEmpty)
    #expect(activeRejectedIdeas([id], entries: [superseded, live], volumes: [], artifactStates: [:]) == [JSString(id)])
    #expect(withoutLapsedRejections([superseded, live], rejection: { $0 }, volumes: [], artifactStates: [:]) == [live])
    let anchored = IdeaRejectionEntry(ideaId: id, rejectionScope: .notThisVersion, rejectionAnchor: .states([("premise", .missing)]), superseded: true)
    #expect(rejectionStateRefs(for: [anchored]).isEmpty)
  }
}
