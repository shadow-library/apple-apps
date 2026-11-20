import CryptoKit
import Foundation
import MemoirCore
import ShadowCore
import Testing

@Suite("Ruleset", TestTimeLimit.quick)
struct RulesetTests {
  private struct Pinned: Decodable {
    let sha256: String
    let canonical: JSONValue
  }

  private static func canonical(_ ruleset: Ruleset) throws -> Data {
    CanonicalJSON.encode(try CanonicalJSON.decode(JSONEncoder().encode(ruleset), mode: .lenient))
  }

  @Test("should keep ruleset v1 byte for byte as the reference's RULESET_V1 in exact units, pinned by its canonical hash")
  func pinsVersionOne() throws {
    let pinned = try JSONDecoder().decode(Pinned.self, from: RuleVectors.data("rules/ruleset-v1.json"))
    let native = try Self.canonical(.v1)
    let digest = SHA256.hash(data: native).map { String(format: "%02x", $0) }.joined()
    #expect(digest == pinned.sha256, "Ruleset.v1 changed; publish a new ruleset version instead of editing a frozen one.")
    #expect(native == CanonicalJSON.encode(pinned.canonical))
  }

  @Test("should resolve only published versions")
  func resolvesVersions() {
    #expect(Ruleset.version(1) == .v1)
    #expect(Ruleset.current == .v1)
    #expect(Ruleset.version(0) == nil)
    #expect(Ruleset.version(2) == nil)
  }

  @Test("should hold the level table from level 1 to the maximum")
  func levelTable() {
    #expect(Ruleset.v1.level.xpToAdvance.count == Ruleset.v1.level.maxLevel - 1)
    #expect(Ruleset.v1.level.xpToAdvance(fromLevel: 1) == 100)
    #expect(Ruleset.v1.level.xpToAdvance(fromLevel: 100) == 100_000)
    #expect(Ruleset.v1.level.xpToAdvance(fromLevel: 999) == 0)
  }
}

@Suite("Rule divergences", TestTimeLimit.quick)
struct RuleDivergenceTests {
  private static let checked: Set<String> = [
    "reward.json/computeReward", "momentum.json/computeMomentum", "capacity.json/computeCapacity", "comeback.json/comebackBonus",
    "comeback.json/comebackNetXp", "properties.json/comebackNetNegative", "properties.json/comebackBonusCoins", "level.json/xpToAdvance",
    "level.json/xpThresholdForLevel", "level.json/levelFor", "crown.json/crownShare", "crown.json/endowCrown", "momentum.json/medianOf",
    "capacity.json/capacityWarningFor",
  ]

  @Test("should list each divergence once, on a rule the vector suites check, with a reference that really differs from the exact model")
  func listsRealDivergences() {
    let list = RuleVectors.divergences
    #expect(list.count == list.cases.count)
    #expect(Set(list.cases.map { "\($0.file)/\($0.function)/\($0.id)" }).count == list.cases.count)
    for divergence in list.cases {
      #expect(Self.checked.contains("\(divergence.file)/\(divergence.function)"), "\(divergence.file)/\(divergence.function) has no vector suite")
      #expect(!divergence.fields.isEmpty && divergence.reference != divergence.exact)
    }
  }

  @Test("should diverge from the reference's bucket only where its float lands below the cold ratio")
  func bucketDivergences() {
    let buckets = RuleVectors.divergences.cases.filter { $0.fields.contains("bucket") }
    #expect(buckets.count == 2)
    for divergence in buckets {
      #expect((try? divergence.reference["bucket"]) == .string("cold"))
      #expect((try? divergence.exact["bucket"]) == .string("steady"))
    }
  }
}
