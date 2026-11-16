import Foundation
import GRDB
import ShadowCore
import ShadowStore

@testable import NovelForgeCore

struct Claim: Hashable, CustomStringConvertible {
  let milestone: String
  let chapter: Int
  let basis: ClaimBasis
  let status: MilestoneClaimStatus
  let holder: Int?

  init(_ milestone: String, _ chapter: Int, _ status: MilestoneClaimStatus, holder: Int? = nil) {
    self.init(milestone, chapter, .plan, status, holder: holder)
  }

  init(_ milestone: String, _ chapter: Int, _ basis: ClaimBasis, _ status: MilestoneClaimStatus, holder: Int? = nil) {
    self.milestone = milestone
    self.chapter = chapter
    self.basis = basis
    self.status = status
    self.holder = holder
  }

  init(_ entry: MilestoneClaimEntry) {
    self.init(entry.milestone, entry.chapter, entry.basis, entry.status, holder: entry.holder)
  }

  static func == (left: Claim, right: Claim) -> Bool {
    Array(left.milestone.utf8) == Array(right.milestone.utf8) && left.chapter == right.chapter && left.basis == right.basis && left.status == right.status
      && left.holder == right.holder
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(Array(milestone.utf8))
    hasher.combine(chapter)
  }

  var description: String { "\(milestone)@\(chapter) \(basis) \(status) holder=\(holder.map(String.init) ?? "-")" }
}

struct MilestoneSnapshot: Hashable, CustomStringConvertible {
  let state: String
  let planned: Int?
  let reached: Int?

  init(_ state: String, planned: Int? = nil, reached: Int? = nil) {
    self.state = state
    self.planned = planned
    self.reached = reached
  }

  init(_ entry: MilestoneStateEntry) {
    self.init(entry.state.rawValue, planned: entry.plannedChapter, reached: entry.reachedChapter)
  }

  var description: String { "\(state) planned=\(planned.map(String.init) ?? "-") reached=\(reached.map(String.init) ?? "-")" }
}

struct Verdict: Hashable, CustomStringConvertible {
  let status: PlanRevealStatus
  let reason: String?

  init(_ status: PlanRevealStatus, _ reason: String? = nil) {
    self.status = status
    self.reason = reason
  }

  init(_ entry: PlanRevealEntry) {
    self.init(entry.status, entry.reason)
  }

  static func == (left: Verdict, right: Verdict) -> Bool {
    left.status == right.status && left.reason.map { Array($0.utf8) } == right.reason.map { Array($0.utf8) }
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(status)
  }

  var description: String { "\(status)\(reason.map { ": \($0)" } ?? "")" }
}

struct Learn: Sendable {
  let entity: String
  let fact: String

  init(_ entity: String, _ fact: String) {
    self.entity = entity
    self.fact = fact
  }
}

enum PlanWorldTerm: Sendable {
  case milestone(String)
  case volume(String)
  case chapter(Int)
  case ending

  var json: JSONValue {
    switch self {
    case .milestone(let key): .object(["milestone": .string(key)])
    case .volume(let key): .object(["volume": .string(key)])
    case .chapter(let number): .object(["chapter": .int(Int64(number))])
    case .ending: .object(["ending": .bool(true)])
    }
  }
}

func unlock(_ terms: PlanWorldTerm...) -> JSONValue {
  .object(["all": .array(terms.map(\.json))])
}

func contract(pov: [String] = ["mara"], learns: [Learn] = [], claims: [String] = [], ending: Bool = false) -> ChapterContract {
  ChapterContract(pov: pov, learns: learns.map { ContractLearn(KnowledgeReveal(entityKey: $0.entity, factKey: $0.fact)) }, claimedMilestones: claims, isEnding: ending)
}

func planContent(volume: String? = nil, _ contract: ChapterContract = contract()) -> ChapterPlanContent {
  ChapterPlanContent(body: "The plan.", volume: volume, contract: contract)
}

enum PlanWorldWrites {
  static func putPlan(novel: UUID, chapter: Int, _ content: ChapterPlanContent, in transaction: inout WriteTransaction) throws {
    let record = try ChapterPlanRecord(novel: novel, chapter: chapter, content: content)
    switch try ChapterPlanRecord.read(record.ref, in: transaction) {
    case .absent: _ = try record.create(in: &transaction)
    case .readable(let entry) where entry.isRemoved:
      _ = try record.restore(in: &transaction)
      _ = try ChapterPlanRecord.revise(record.ref, content, in: &transaction)
    default: _ = try ChapterPlanRecord.revise(record.ref, content, in: &transaction)
    }
  }

  static func finalize(novel: UUID, chapter: Int, volume: String? = nil, _ contract: ChapterContract = contract(), in transaction: inout WriteTransaction) throws {
    let canon = Canon(draftRevision: "v:draft", planRevision: "v:plan", body: "The tide turns.", volume: volume, contract: contract)
    _ = try FinalChapterRecord(novel: novel, chapter: chapter, canon: canon).finalize(in: &transaction)
  }

  static func secret(
    novel: UUID, _ key: String, revealChapter: Int? = nil, unlock: JSONValue? = nil, source: FactSource = .manual, in transaction: inout WriteTransaction
  ) throws {
    let record = SecretRecord(novel: novel, secret: key, text: "The ledger is forged.", revealChapter: revealChapter, unlock: unlock, source: .known(source))
    _ = try record.create(in: &transaction)
  }

  static func milestone(novel: UUID, _ key: String, in transaction: inout WriteTransaction) throws {
    _ = try MilestoneRecord(novel: novel, milestone: key, label: "Milestone \(key)").create(in: &transaction)
  }

  static func volume(novel: UUID, _ key: String, ordinal: Int, in transaction: inout WriteTransaction) throws {
    _ = try VolumeRecord(novel: novel, volume: key, ordinal: ordinal).create(in: &transaction)
  }
}

enum PlanWorldTables {
  static func verdicts(_ novel: UUID, in store: VaultStore) async throws -> [Int: Verdict] {
    let entries = try await Projection.fetch(PlanRevealDerivation.request(for: novel), in: store)
    return Dictionary(uniqueKeysWithValues: entries.map { ($0.chapter, Verdict($0)) })
  }

  static func rivalEndings(_ novel: UUID, in store: VaultStore) async throws -> [Int: Int] {
    let entries = try await Projection.fetch(PlanRevealDerivation.request(for: novel), in: store)
    return Dictionary(uniqueKeysWithValues: entries.compactMap { entry in entry.rivalEnding.map { (entry.chapter, $0) } })
  }

  static func claims(_ novel: UUID, in store: VaultStore) async throws -> Set<Claim> {
    Set(try await Projection.fetch(MilestoneClaimDerivation.request(for: novel), in: store).map(Claim.init))
  }

  static func milestones(_ novel: UUID, in store: VaultStore) async throws -> [String: MilestoneSnapshot] {
    let entries = try await Projection.fetch(MilestoneStateDerivation.request(for: novel), in: store)
    return Dictionary(uniqueKeysWithValues: entries.map { ($0.milestone, MilestoneSnapshot($0)) })
  }
}
