import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

// sha256 of the canonical JSON, computed outside Swift with `printf '%s' '<json>' | shasum -a 256`.
private let emptyArray = "4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945"
private let eliasCafeMaraHeir = "336de82d38c9ce8bc4bb3c688dc37c58aa94963ae723e7ec663794f0d46de906"
private let riseReve = "2e9e15db71a79234f54ffe30f2e0bc1636746cb07675e253135e2600d3c50e64"
private let surrogateFirst = "736d2c392530e424aef907ebafcd7fc9d494e5c8ebd0084afd90207b8e50fcce"
private let upstreamDocument = "5249cfedebb2a595fea17ee7236e605c84c2fd715d8da67a82ddd39977c01b20"
private let differencesDocument = "6cde580040bbccf95243c6ea9280ce8210d2a054a8d3fd5b4c297da86764d716"

private let decomposedCafe = "cafe\u{301}"
private let decomposedReve = "re\u{302}ve"

@Suite("Chapter fingerprints")
struct ChapterFingerprintTests {
  @Test func shouldPinTheTermsDigestOfAPlanAsTwoSha256DigestsOfCanonicalSets() {
    let planned = contract(pov: ["mara"], learns: [Learn("mara", "heir"), Learn("elias", decomposedCafe), Learn("mara", "heir")], claims: ["rise", decomposedReve, "rise"])
    #expect(ChapterFingerprint.planTerms(planned) == "\(eliasCafeMaraHeir):\(riseReve)")
    #expect(ChapterFingerprint.learns(planned) == eliasCafeMaraHeir)
    #expect(ChapterFingerprint.planTerms(nil) == "\(emptyArray):\(emptyArray)")
    #expect(ChapterFingerprint.planTerms(ChapterContract()) == ChapterFingerprint.planTerms(nil))
  }

  @Test func shouldCountLearnsOnlyUnderANamedPointOfView() {
    let unnamed = contract(pov: [""], learns: [Learn("mara", "heir")], claims: ["rise", "r\u{EA}ve"])
    #expect(ChapterFingerprint.planTerms(unnamed) == "\(emptyArray):\(riseReve)")
  }

  @Test func shouldSortByUTF16CodeUnitsAsJavaScriptDoes() {
    #expect(ChapterFingerprint.planTerms(contract(claims: ["\u{FFFD}", "\u{1F600}"])).hasSuffix(":\(surrogateFirst)"))
  }

  @Test func shouldIgnoreOrderAndSpellingOfTheSameTerms() {
    let first = contract(pov: ["mara"], learns: [Learn("elias", "caf\u{E9}"), Learn("mara", "heir")], claims: ["r\u{EA}ve", "rise"])
    let second = contract(pov: ["", "elias"], learns: [Learn("mara", "heir"), Learn("elias", decomposedCafe)], claims: ["rise", decomposedReve])
    #expect(ChapterFingerprint.planTerms(first) == ChapterFingerprint.planTerms(second))
    #expect(ChapterFingerprint.learnsPart(of: ChapterFingerprint.planTerms(first)).map(String.init) == ChapterFingerprint.learns(first))
    #expect(ChapterFingerprint.learnsPart(of: "no separator") == nil)
  }

  @Test func shouldDigestAPlanFromThePlanWorldAsFromItsContract() throws {
    let planned = contract(pov: ["mara"], learns: [Learn("elias", decomposedCafe)], claims: [decomposedReve, "rise", "rise"])
    let ref = try ChapterPlanRecord.ref(novel: SchemaFixture.novel, chapter: 1)
    let entry = try ChapterContractEntry.reading(.plan, ref, novel: SchemaFixture.novel, chapter: 1, volume: nil, contract: planned)
    let world = WorldChapter(ChapterContractReading(entry: entry, terms: try JSONDecoder().decode(ChapterTerms.self, from: entry.terms)))
    let pairs = world.learns.map { ($0.entity, $0.fact) }
    #expect(ChapterFingerprint.terms(pov: world.pov, learns: pairs, claims: world.claims) == ChapterFingerprint.planTerms(planned))
  }

  @Test func shouldPinTheRecordedUpstreamDocument() throws {
    let upstream = DraftUpstream(entries: [.canon(chapter: 2, digest: "abc"), .draft(chapter: 3, revision: nil, taught: "t")])
    #expect(ChapterFingerprint.digest(upstream.json) == upstreamDocument)
    #expect(DraftUpstream(json: upstream.json) == upstream)
    let differences: JSONValue = [["chapter": 1, "draft": "v:new"], ["chapter": 2, "taught": nil], ["unrecorded": true]]
    #expect(ChapterFingerprint.digest(differences) == differencesDocument)
  }

  @Test(arguments: [
    JSONValue.object([:]), ["chapters": "x"], ["chapters": [["chapter": 1]]], ["chapters": [["chapter": "1", "draft": nil]]],
    ["chapters": [["chapter": 1, "canon": "a", "draft": "b"]]], ["chapters": [["chapter": 1, "canon": "a", "taught": "t"]]], ["chapters": [["chapter": 1, "draft": 3]]],
    ["chapters": [["chapter": 1, "draft": nil, "taught": 3]]],
  ])
  func shouldRefuseAMalformedUpstream(_ json: JSONValue) {
    #expect(DraftUpstream(json: json) == nil)
  }

  @Test func shouldReadAnAbsentTaughtAsNothingTaughtAndIgnoreNewerMembers() {
    let json: JSONValue = ["chapters": [["chapter": 1, "draft": "v:a", "since": 4]], "version": 2]
    #expect(DraftUpstream(json: json) == DraftUpstream(entries: [.draft(chapter: 1, revision: "v:a", taught: nil)]))
  }

  @Test func shouldFitOnlyTheExactShapeRuleTwoRecords() {
    let draft = { (chapter: Int) in DraftUpstream.Entry.draft(chapter: chapter, revision: nil, taught: nil) }
    let canon = { (chapter: Int) in DraftUpstream.Entry.canon(chapter: chapter, digest: nil) }
    #expect(DraftUpstream(entries: []).fits(chapter: 1))
    #expect(DraftUpstream(entries: [draft(1), draft(2)]).fits(chapter: 3))
    #expect(DraftUpstream(entries: [canon(2), draft(3)]).fits(chapter: 4))
    #expect(DraftUpstream(entries: [canon(1)]).fits(chapter: 2))
    #expect(!DraftUpstream(entries: []).fits(chapter: 2))
    #expect(!DraftUpstream(entries: [draft(1)]).fits(chapter: 1))
    #expect(!DraftUpstream(entries: [draft(2)]).fits(chapter: 3))
    #expect(!DraftUpstream(entries: [draft(1), draft(3)]).fits(chapter: 4))
    #expect(!DraftUpstream(entries: [draft(1)]).fits(chapter: 3))
    #expect(!DraftUpstream(entries: [draft(2), draft(1)]).fits(chapter: 3))
    #expect(!DraftUpstream(entries: [draft(1), draft(1)]).fits(chapter: 2))
    #expect(!DraftUpstream(entries: [draft(1), canon(2)]).fits(chapter: 3))
    #expect(!DraftUpstream(entries: [draft(0), draft(1)]).fits(chapter: 2))
  }
}
