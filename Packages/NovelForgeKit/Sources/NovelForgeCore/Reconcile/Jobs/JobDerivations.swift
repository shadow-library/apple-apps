import Foundation
import ShadowAI
import ShadowCore
import ShadowJobs
import ShadowStore

public enum JobDerivations {
  public static let all: [any Derivation] = [
    ModelCallIndexDerivation(),
    JobAttemptDerivation(),
    JobCallDerivation(),
    JobEntryDerivation(),
    JobActivityDerivation(),
    JobCallCostDerivation(),
  ]
}

/// The phase 7 kinds of apps/novel-forge-server/src/database/schemas/jobs.ts:62.
public enum NovelJobKind: String, CaseIterable, Sendable {
  case generate
  case plan
  case review
  case finalizeReview = "finalize_review"
  case canonRefresh = "canon_refresh"

  /// A plan runs on the device that asked for it; every other kind waits for the vault's worker (phase 8 orchestrator decision 1).
  public var queuesForWorker: Bool {
    switch self {
    case .plan: false
    case .generate, .review, .finalizeReview, .canonRefresh: true
    }
  }
}

/// A novel's job is scoped by its lower-cased id and a chapter job targets `chapter:<n>`: one chapter per job (orchestrator decision 8), where the reference
/// spells each kind's target its own way (generation.service.ts:281, finalize-review-stage.ts:9, chapter-review.service.ts:149).
public enum NovelJobAddress {
  private static let chapterPrefix = "chapter:"

  public static func scope(of novel: UUID) -> String { novel.lowercasedString }

  public static func target(chapter: Int) -> String { chapterPrefix + String(chapter) }

  public static func novel(ofScope scope: String) -> UUID? {
    guard let novel = UUID(uuidString: scope), novel.lowercasedString == scope else { return nil }
    return novel
  }

  public static func chapter(ofTarget target: String) -> Int? {
    guard target.hasPrefix(chapterPrefix), let chapter = Int(target.dropFirst(chapterPrefix.count)), chapter >= 1, Self.target(chapter: chapter) == target else {
      return nil
    }
    return chapter
  }
}

extension DerivationInput {
  /// `.records` for the ShadowKit kinds a vault holds (jobs, the ledger), under the same rule: keys come from the ref alone.
  static func kit(_ kinds: [EntityKind], keys: @escaping @Sendable (EntityRef) -> [Key]) -> DerivationInput {
    let kinds = Set(kinds)
    return DerivationInput(upstream: nil) { changes in changes.touched.filter { kinds.contains($0.kind) }.flatMap(keys) }
  }
}

extension DerivationContext {
  func refs(ofKit kind: EntityKind) throws(StoreError) -> [EntityRef] {
    try records.states(ofKind: kind, scope: .vault).map(\.ref)
  }
}

enum JobColumns {
  static func key(_ text: String) throws(StoreError) -> EntityKey {
    guard let key = EntityKey(text) else { throw .corruptStore("a job row holds an invalid key") }
    return key
  }

  static func attempt(_ text: String) throws(StoreError) -> AttemptID {
    guard let uuid = UUID(uuidString: text), let id = try? AttemptID(uuid) else { throw .corruptStore("a job row holds an attempt id that is not a version 7 UUID") }
    return id
  }

  static func replica(_ text: String) throws(StoreError) -> ReplicaID {
    guard let replica = ReplicaID(text) else { throw .corruptStore("a job row holds an invalid replica id") }
    return replica
  }

  static func clock(_ text: String) throws(StoreError) -> HLCTimestamp {
    guard let clock = HLCTimestamp(text) else { throw .corruptStore("a job row holds an invalid clock") }
    return clock
  }

  static func value<Value: RawRepresentable>(_ text: String, _: Value.Type) throws(StoreError) -> Value where Value.RawValue == String {
    guard let value = Value(rawValue: text) else { throw .corruptStore("a job row holds an unknown \(Value.self) \(text)") }
    return value
  }

  static func jobRef(_ key: EntityKey) -> EntityRef { EntityRef(kind: JobSchema.jobKind, key: key) }

  static func callRef(_ call: UUID) -> EntityRef { EntityRef(kind: LedgerSchema.modelCallKind, key: EntityKey(uuid: call)) }

  static func uuid(of ref: EntityRef, _ kind: EntityKind) -> UUID? {
    guard ref.kind == kind, let id = UUID(uuidString: ref.key.rawValue), EntityKey(uuid: id) == ref.key else { return nil }
    return id
  }
}
