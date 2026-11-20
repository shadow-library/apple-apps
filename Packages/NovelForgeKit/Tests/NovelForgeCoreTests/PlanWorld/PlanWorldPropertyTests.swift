import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import ShadowText
import Synchronization
import Testing

@testable import NovelForgeCore

private let milestoneKeys = ["rise", "fall", "r\u{E9}ve"]
private let claimSpellings = milestoneKeys + ["re\u{301}ve", "ghost"]
private let factKeys = ["ledger", "heir", "caf\u{E9}"]
private let learnSpellings = factKeys + ["cafe\u{301}", "ghost"]
private let volumeSpellings: [String?] = [nil, "one", "two", "ghost"]
private let sources: [FactSource] = [.brief, .manual, .import, .seed, .generated]

private func nfc(_ text: String) -> String { text.precomposedStringWithCanonicalMapping }

private func unique(_ keys: [String]) -> [String] {
  var seen = Set<[UInt8]>()
  return keys.filter { seen.insert(Array($0.utf8)).inserted }
}

enum PlanWorldOperations {
  static func contract(_ generator: inout SeededGenerator) -> ChapterContract {
    let learns = (0..<generator.int(in: 0...2)).map { _ in Learn(generator.pick(from: ["mara", "elias"]), generator.pick(from: learnSpellings)) }
    let claims = claimSpellings.filter { _ in generator.chance(0.35) }
    return NovelForgeCoreTests.contract(pov: generator.chance(0.85) ? ["mara"] : [""], learns: learns, claims: claims, ending: generator.chance(0.15))
  }

  static func term(_ generator: inout SeededGenerator) -> PlanWorldTerm {
    switch generator.int(in: 0...3) {
    case 0: .milestone(generator.pick(from: claimSpellings))
    case 1: .volume(generator.pick(from: ["one", "two", "ghost"]))
    case 2: .chapter(generator.int(in: 1...5))
    default: .ending
    }
  }

  static func unlockValue(_ generator: inout SeededGenerator) -> JSONValue? {
    switch generator.int(in: 0...5) {
    case 0, 1: nil
    case 2: .object(["all": .string("later")])
    default: .object(["all": .array((0..<generator.int(in: 1...2)).map { _ in term(&generator).json })])
    }
  }

  static func revealChapter(_ generator: inout SeededGenerator) -> Int? {
    generator.chance(0.5) ? nil : generator.int(in: 1...5)
  }

  static func planRef(_ generator: inout SeededGenerator, _ universe: ProjectionUniverse) -> EntityRef {
    (try? ChapterPlanRecord.ref(novel: universe.novel(&generator), chapter: universe.chapter(&generator))) ?? NovelForgeKey.novel(universe.novels[0])
  }

  static func secret(_ generator: inout SeededGenerator, _ universe: ProjectionUniverse) -> SecretRecord {
    SecretRecord(
      novel: universe.novel(&generator), secret: generator.pick(from: factKeys), text: universe.text(&generator), revealChapter: revealChapter(&generator),
      unlock: unlockValue(&generator), source: .known(generator.pick(from: sources)))
  }

  static func milestone(_ generator: inout SeededGenerator, _ universe: ProjectionUniverse) -> MilestoneRecord {
    MilestoneRecord(novel: universe.novel(&generator), milestone: generator.pick(from: milestoneKeys), label: universe.text(&generator))
  }

  static let plans: [ProjectionOperation] = [
    ProjectionOperation(name: "revise a plan", weight: 8) { generator, universe in
      let (novel, chapter, volume, contract) = (universe.novel(&generator), universe.chapter(&generator), generator.pick(from: volumeSpellings), contract(&generator))
      return { transaction in try PlanWorldWrites.putPlan(novel: novel, chapter: chapter, planContent(volume: volume, contract), in: &transaction) }
    },
    ProjectionOperation(name: "mark two plans as the ending", weight: 1) { generator, universe in
      let novel = universe.novel(&generator)
      let chapters = generator.shuffled(Array(universe.chapters)).prefix(2)
      let contracts = chapters.map { _ in contract(&generator) }
      return { transaction in
        for (chapter, planned) in zip(chapters, contracts) {
          let ending = ChapterContract(pov: planned.pov, learns: planned.learns, claimedMilestones: planned.claimedMilestones, isEnding: true)
          try PlanWorldWrites.putPlan(novel: novel, chapter: chapter, planContent(ending), in: &transaction)
        }
      }
    },
    ProjectionOperation(name: "remove a plan", weight: 1) { generator, universe in
      let ref = planRef(&generator, universe)
      return { transaction in _ = try ChapterPlanRecord.remove(ref, in: &transaction) }
    },
    ProjectionOperation(name: "restore a plan", weight: 1) { generator, universe in
      let (novel, chapter) = (universe.novel(&generator), universe.chapter(&generator))
      return { transaction in
        let record = try ChapterPlanRecord(novel: novel, chapter: chapter, content: planContent())
        guard case .readable(let entry) = try ChapterPlanRecord.read(record.ref, in: transaction), entry.isRemoved else { return }
        _ = try record.restore(in: &transaction)
      }
    },
    ProjectionOperation(name: "write an unreadable plan head", weight: 1) { generator, universe in
      let ref = planRef(&generator, universe)
      return { transaction in _ = try transaction.revise(ref, body: .object(["body": .int(1)])) }
    },
    ProjectionOperation(name: "purge a plan", weight: 1) { generator, universe in
      let (ref, purges) = (planRef(&generator, universe), generator.chance(0.4))
      return { transaction in if purges { _ = try transaction.purge(ref) } }
    },
  ]

  /// Without a readable plan the chapter is finalized with `unplanned`, as a hand-written chapter would be.
  static func finalizeAsPlanned(novel: UUID, chapter: Int, unplanned: ChapterContract, in transaction: inout WriteTransaction) throws {
    let head = try ChapterPlanRecord.read(try ChapterPlanRecord.ref(novel: novel, chapter: chapter), in: transaction).entry?.record.content
    try PlanWorldWrites.finalize(novel: novel, chapter: chapter, volume: head?.volume, head?.contract ?? unplanned, in: &transaction)
  }

  static let finals: [ProjectionOperation] = [
    ProjectionOperation(name: "finalize as planned", weight: 1) { generator, universe in
      let (novel, chapter, unplanned) = (universe.novel(&generator), universe.chapter(&generator), contract(&generator))
      return { transaction in try finalizeAsPlanned(novel: novel, chapter: chapter, unplanned: unplanned, in: &transaction) }
    },
    ProjectionOperation(name: "finalize the next chapter as planned", weight: 2) { generator, universe in
      let (novel, unplanned) = (universe.novel(&generator), contract(&generator))
      return { transaction in
        for chapter in universe.chapters where try FinalChapterRecord.read(try FinalChapterRecord.ref(novel: novel, chapter: chapter), in: transaction) == .absent {
          return try finalizeAsPlanned(novel: novel, chapter: chapter, unplanned: unplanned, in: &transaction)
        }
      }
    },
    ProjectionOperation(name: "finalize with another contract", weight: 1) { generator, universe in
      let (novel, chapter, volume, contract) = (universe.novel(&generator), universe.chapter(&generator), generator.pick(from: volumeSpellings), contract(&generator))
      return { transaction in try PlanWorldWrites.finalize(novel: novel, chapter: chapter, volume: volume, contract, in: &transaction) }
    },
    ProjectionOperation(name: "write an unreadable canon", weight: 1) { generator, universe in
      let (novel, chapter) = (universe.novel(&generator), universe.chapter(&generator))
      return { transaction in
        let key = try NovelForgeKey.finalChapterKey(novel: novel, chapter: chapter)
        _ = try transaction.set(key.ref, ["natural_key": key.stored, "canon": .string("newer")])
      }
    },
  ]

  static let milestones: [ProjectionOperation] = [
    ProjectionOperation(name: "create a milestone", weight: 3) { generator, universe in
      let record = milestone(&generator, universe)
      return { transaction in _ = try record.create(in: &transaction) }
    },
    ProjectionOperation(name: "remove a milestone", weight: 2) { generator, universe in
      let ref = milestone(&generator, universe).ref
      return { transaction in _ = try MilestoneRecord.remove(ref, in: &transaction) }
    },
    ProjectionOperation(name: "restore a milestone", weight: 1) { generator, universe in
      let record = milestone(&generator, universe)
      return { transaction in _ = try record.restore(in: &transaction) }
    },
    ProjectionOperation(name: "write an unreadable milestone", weight: 1) { generator, universe in
      let ref = milestone(&generator, universe).ref
      return { transaction in _ = try transaction.set(ref, ["label": .int(1)]) }
    },
    ProjectionOperation(name: "purge a milestone", weight: 1) { generator, universe in
      let (ref, purges) = (milestone(&generator, universe).ref, generator.chance(0.4))
      return { transaction in if purges { _ = try transaction.purge(ref) } }
    },
  ]

  static let secrets: [ProjectionOperation] = [
    ProjectionOperation(name: "create a secret", weight: 3) { generator, universe in
      let record = secret(&generator, universe)
      return { transaction in _ = try record.create(in: &transaction) }
    },
    ProjectionOperation(name: "edit a secret's unlock", weight: 3) { generator, universe in
      let ref = secret(&generator, universe).ref
      var edit = SecretEdit()
      edit.unlock = .set(unlockValue(&generator))
      let changes = edit
      return { transaction in _ = try SecretRecord.edit(ref, changes.fields, in: &transaction) }
    },
    ProjectionOperation(name: "edit a secret's reveal chapter and source", weight: 2) { generator, universe in
      let ref = secret(&generator, universe).ref
      var edit = SecretEdit()
      edit.revealChapter = .set(revealChapter(&generator))
      edit.source = .set(.known(generator.pick(from: sources)))
      let changes = edit
      return { transaction in _ = try SecretRecord.edit(ref, changes.fields, in: &transaction) }
    },
    ProjectionOperation(name: "remove a secret", weight: 1) { generator, universe in
      let ref = secret(&generator, universe).ref
      return { transaction in _ = try SecretRecord.remove(ref, in: &transaction) }
    },
    ProjectionOperation(name: "restore a secret", weight: 1) { generator, universe in
      let record = secret(&generator, universe)
      return { transaction in _ = try record.restore(in: &transaction) }
    },
    ProjectionOperation(name: "write an unreadable secret", weight: 2) { generator, universe in
      let record = secret(&generator, universe)
      return { transaction in
        if case .absent = try SecretRecord.read(record.ref, in: transaction) { _ = try record.create(in: &transaction) }
        _ = try transaction.set(record.ref, ["text": .int(1)])
      }
    },
  ]

  static let seed = ProjectionOperation(name: "seed a novel's milestones and secrets", weight: 2) { generator, universe in
    let novel = universe.novel(&generator)
    let records: [any NovelForgeRecord] =
      milestoneKeys.map { MilestoneRecord(novel: novel, milestone: $0, label: $0) }
      + factKeys.map { key in
        SecretRecord(
          novel: novel, secret: key, text: key, revealChapter: revealChapter(&generator), unlock: unlockValue(&generator), source: .known(generator.pick(from: sources)))
      }
    return { transaction in for record in records { _ = try record.create(in: &transaction) } }
  }

  static let all = [seed] + plans + finals + milestones + secrets + ProjectionOperations.volumes
}

private struct Judged: Equatable, CustomStringConvertible {
  let status: PlanRevealStatus
  let violations: [PlanRevealViolation]
  let rivalEnding: Int?

  var description: String { "\(status) \(violations.map { "\($0.fact): \($0.missing)" }) rival=\(rivalEnding.map(String.init) ?? "-")" }
}

private struct Chapter {
  let chapter: Int
  let basis: ClaimBasis
  let volume: String?
  let contract: ChapterContract

  var claims: [String] { unique(contract.claimedMilestones.map(nfc)) }
}

private enum Head {
  case readable(ChapterPlanContent)
  case unreadable
}

private struct Expected {
  var claims = Set<Claim>()
  var milestones = [String: MilestoneSnapshot]()
  var verdicts = [Int: Judged]()
}

final class Coverage: Sendable {
  let seen = Mutex(Set<String>())
}

/// A record whose natural key never arrived cannot be placed in a novel, so it counts for none.
private func attributed(_ ref: EntityRef, in transaction: ReadTransaction) throws -> Bool {
  guard let state = try transaction.state(of: ref, scope: .vault) else { return false }
  return (try? NovelForgeKey(reading: state, of: ref)) != nil
}

// An independent reading of one novel, chapter by chapter and key by key, without the record index.
private func expected(for novel: UUID, in transaction: ReadTransaction, universe: ProjectionUniverse) throws -> Expected {
  var heads = [Int: Head]()
  var finals = [Int: FinalChapterRecord?]()
  for chapter in universe.chapters {
    switch try ChapterPlanRecord.read(try ChapterPlanRecord.ref(novel: novel, chapter: chapter), in: transaction) {
    case .readable(let entry) where !entry.isRemoved: heads[chapter] = .readable(entry.record.content)
    case .unreadable: heads[chapter] = .unreadable
    default: break
    }
    switch try FinalChapterRecord.read(try FinalChapterRecord.ref(novel: novel, chapter: chapter), in: transaction) {
    case .readable(let entry): finals[chapter] = .some(entry.record)
    case .unreadable: finals[chapter] = .some(nil)
    case .absent: break
    }
  }
  let existing = Set(
    try milestoneKeys.filter { key in
      switch try MilestoneRecord.read(novel: novel, milestone: key, in: transaction) {
      case .readable(let entry): !entry.isRemoved
      case .unreadable: try attributed(MilestoneRecord.ref(novel: novel, milestone: key), in: transaction)
      case .absent: false
      }
    })
  var ordinals = [JSString: Int]()
  for volume in universe.volumes {
    guard case .readable(let entry) = try VolumeRecord.read(novel: novel, volume: volume, in: transaction), !entry.isRemoved else { continue }
    ordinals[JSString(volume)] = entry.record.ordinal
  }

  let frontier = finals.keys.max() ?? 0
  let chapters: [Chapter] = universe.chapters.compactMap { chapter in
    if let final = finals[chapter] { return final.map { Chapter(chapter: chapter, basis: .canon, volume: $0.canon.volume, contract: $0.canon.contract) } }
    guard case .readable(let content)? = heads[chapter] else { return nil }
    return Chapter(chapter: chapter, basis: .plan, volume: content.volume, contract: content.contract)
  }

  var result = Expected()
  for key in milestoneKeys where existing.contains(key) {
    let canon = chapters.filter { $0.basis == .canon && $0.claims.contains(key) }.map(\.chapter)
    let planned = chapters.filter { $0.basis == .plan && $0.claims.contains(key) }.map(\.chapter)
    result.milestones[key] =
      if let first = canon.min() { MilestoneSnapshot("reached", planned: first, reached: first) } else if let first = planned.min() {
        MilestoneSnapshot("planned", planned: first)
      } else { MilestoneSnapshot("open") }
  }
  for chapter in chapters {
    for key in chapter.claims {
      guard existing.contains(key) else {
        result.claims.insert(Claim(key, chapter.chapter, chapter.basis, .unknown))
        continue
      }
      let canon = chapters.filter { $0.basis == .canon && $0.claims.contains(key) }.map(\.chapter)
      let holder = canon.min() ?? chapters.filter { $0.claims.contains(key) }.map(\.chapter).min() ?? chapter.chapter
      result.claims.insert(Claim(key, chapter.chapter, chapter.basis, holder == chapter.chapter ? .holds : .duplicate, holder: holder))
    }
  }

  // Two endings resolve to the latest, so an ending-gated reveal never unlocks before either one.
  let endingChapter = chapters.filter(\.contract.isEnding).map(\.chapter).max()
  for (chapter, head) in heads {
    let rival = chapters.first { $0.chapter == chapter }.flatMap { $0.contract.isEnding && chapter != endingChapter ? endingChapter : nil }
    guard chapter > frontier else {
      result.verdicts[chapter] = Judged(status: .settled, violations: [], rivalEnding: rival)
      continue
    }
    guard case .readable(let content) = head else {
      result.verdicts[chapter] = Judged(status: .unreadable, violations: [], rivalEnding: rival)
      continue
    }
    var reachedKeys = Set<JSString>()
    for earlier in chapters where earlier.chapter <= chapter { reachedKeys.formUnion(earlier.claims.map { JSString($0) }) }
    let context = UnlockContext(
      chapter: chapter, endingChapter: endingChapter, volumeKey: content.volume.map(nfc), volumeOrdinals: ordinals, reachedMilestones: reachedKeys)
    let learned = content.contract.pov.contains { !$0.isEmpty } ? unique(content.contract.learns.map { nfc($0.reveal.factKey) }) : []
    var violations = [PlanRevealViolation]()
    for fact in learned {
      let missing: [String]
      switch try SecretRecord.read(novel: novel, secret: fact, in: transaction) {
      case .unreadable: missing = try attributed(SecretRecord.ref(novel: novel, secret: fact), in: transaction) ? ["a readable secret"] : []
      case .readable(let entry) where !entry.isRemoved:
        let secret = entry.record
        let source = secret.source.known ?? .manual
        switch secret.unlock {
        case nil, .null?:
          missing = revealRequirements(RevealFact(factKey: fact, revealChapter: secret.revealChapter, unlock: nil, source: source), context)
        case let value?:
          if let condition = UnlockCondition(validating: OrderedJSON(value)) {
            missing = revealRequirements(RevealFact(factKey: fact, revealChapter: secret.revealChapter, unlock: condition, source: source), context)
          } else {
            missing = ["a readable unlock condition"]
          }
        }
      default: missing = []
      }
      if !missing.isEmpty { violations.append(PlanRevealViolation(fact: fact, missing: missing)) }
    }
    result.verdicts[chapter] = Judged(status: violations.isEmpty ? .holds : .violated, violations: violations, rivalEnding: rival)
  }
  return result
}

private func oracle(_ coverage: Coverage) -> @Sendable (NovelForgeReconciler, VaultStore, ProjectionUniverse) async throws -> Void {
  { _, store, universe in try await check(store, universe, coverage) }
}

private func check(_ store: VaultStore, _ universe: ProjectionUniverse, _ coverage: Coverage) async throws {
  for novel in universe.novels {
    let expected = try await store.read { transaction in try expected(for: novel, in: transaction, universe: universe) }
    let entries = try await Projection.fetch(PlanRevealDerivation.request(for: novel), in: store)
    let verdicts = Dictionary(uniqueKeysWithValues: entries.map { ($0.chapter, Judged(status: $0.status, violations: $0.violations, rivalEnding: $0.rivalEnding)) })
    guard verdicts == expected.verdicts else { throw ProjectionPropertyFailure.oracle("plan reveals of \(novel): \(verdicts) differ from \(expected.verdicts)") }
    let claims = try await PlanWorldTables.claims(novel, in: store)
    guard claims == expected.claims else { throw ProjectionPropertyFailure.oracle("milestone claims of \(novel): \(claims) differ from \(expected.claims)") }
    let milestones = try await PlanWorldTables.milestones(novel, in: store)
    guard milestones == expected.milestones else { throw ProjectionPropertyFailure.oracle("milestone states of \(novel): \(milestones) differ from \(expected.milestones)") }

    var facts = Set(verdicts.values.map { "plan \($0.status.rawValue)" })
    facts.formUnion(claims.map { "claim \($0.status.rawValue) by \($0.basis.rawValue)" })
    facts.formUnion(milestones.values.map { "milestone \($0.state)" })
    if verdicts.values.contains(where: { $0.violations.contains { $0.missing.contains("a readable unlock condition") } }) { facts.insert("unreadable unlock") }
    if verdicts.values.contains(where: { $0.violations.contains { $0.missing.contains("a readable secret") } }) { facts.insert("unreadable secret") }
    if verdicts.values.contains(where: { $0.violations.contains { $0.missing.contains { $0.hasPrefix("volume") } } }) { facts.insert("volume term missing") }
    if verdicts.values.contains(where: { $0.rivalEnding != nil }) { facts.insert("rival ending") }
    coverage.seen.withLock { $0.formUnion(facts) }
  }
}

private let areaDerivations = ProjectionDerivations.all + PlanWorldDerivations.all

@Suite("Plan world projection property", TestTimeLimit.property)
struct PlanWorldPropertyTests {
  @Test(arguments: [CausalReplicaOrder.causal, .writerOrderOnly])
  func shouldMatchARebuildAtEveryStepAndAgreeWithTheOracleOnEveryReplica(order: CausalReplicaOrder) async throws {
    let property = ProjectionProperty(
      derivations: areaDerivations, operations: ProjectionOperations.novels + PlanWorldOperations.all, iterations: 7, steps: 40, settled: oracle(Coverage()))
    try await property.check(order: order, seed: order == .causal ? 0xD20A : 0xD20B)
  }

  @Test
  func shouldReachEveryInterestingState() async throws {
    let coverage = Coverage()
    let finalizing = [PlanWorldOperations.seed, PlanWorldOperations.seed] + PlanWorldOperations.plans + PlanWorldOperations.finals + PlanWorldOperations.finals
    try await withThrowingTaskGroup { group in
      for (operations, seed) in [(PlanWorldOperations.all, UInt64(0xD20C)), (finalizing, 0xD20D)] {
        let property = ProjectionProperty(
          derivations: areaDerivations, operations: operations, iterations: 16, steps: 40, gated: true, checksEveryStep: false, settled: oracle(coverage))
        group.addTask { try await property.check(order: .causal, seed: seed) }
      }
      try await group.waitForAll()
    }
    let expected: Set<String> = [
      "plan holds", "plan violated", "plan settled", "plan unreadable", "claim holds by plan", "claim holds by canon", "claim duplicate by plan",
      "claim duplicate by canon", "claim unknown by plan", "claim unknown by canon", "milestone open", "milestone planned", "milestone reached", "unreadable unlock",
      "unreadable secret", "volume term missing", "rival ending",
    ]
    #expect(expected.subtracting(coverage.seen.withLock { $0 }) == [])
  }

  @Test
  func shouldBeInTheStandardCatalogue() {
    for derivation in PlanWorldDerivations.all { #expect(NovelForgeDerivations.standard.contains { type(of: $0) == type(of: derivation) }) }
  }
}
