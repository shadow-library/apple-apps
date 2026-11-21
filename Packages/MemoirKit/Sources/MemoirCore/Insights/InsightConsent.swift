import ShadowAI
import ShadowStore

/// The reference's consent classes (ai-consent.service.ts:16): journal entries, reflections and reason notes, and health-class data. Activity-class metrics
/// ride the health class, as the reference flags steps and the other Health metrics `is_health` (metric.repository.ts:30-36).
public enum InsightDataClass: String, CaseIterable, Sendable {
  case journalReflectionReason = "journal_reflection_reason"
  case health
}

/// Consent is held per provider host, as every ShadowAI consent is: what the owner allowed to reach one provider never reaches another.
public enum InsightConsent {
  /// Asked before the first insight to a provider; covers the owner's quests, logs, finance, meals and general metrics.
  public static let call = AIConsentRequirement(dataClass: "memoir.insight", disclosure: "memoir-insight/v1")

  public static func requirement(for dataClass: InsightDataClass) -> AIConsentRequirement {
    switch dataClass {
    case .journalReflectionReason: AIConsentRequirement(dataClass: "memoir.journal_reflection_reason", disclosure: "memoir-journal-reflection-reason/v1")
    case .health: AIConsentRequirement(dataClass: "memoir.health", disclosure: "memoir-health/v1")
    }
  }

  /// Granting again after a withdrawal is the same write; a withdrawal excludes the class from later reads only (ai.dto.ts:61-65).
  public static func decide(
    _ state: AIConsentState, _ dataClass: InsightDataClass, provider host: String, atMillis: Int64, in transaction: inout WriteTransaction
  ) throws(StoreError) {
    let requirement = requirement(for: dataClass)
    try AIConsent.decide(state, provider: host, dataClass: requirement.dataClass, summary: requirement.disclosure, atMillis: atMillis, in: &transaction)
  }

  /// A class never decided reads as not granted.
  public static func snapshot(provider host: String, in transaction: ReadTransaction) throws(StoreError) -> InsightConsentSnapshot {
    func granted(_ dataClass: InsightDataClass) throws(StoreError) -> Bool {
      let requirement = requirement(for: dataClass)
      return try AIConsent.isGranted(provider: host, dataClass: requirement.dataClass, currentSummary: requirement.disclosure, in: transaction)
    }
    return InsightConsentSnapshot(journal: try granted(.journalReflectionReason), health: try granted(.health))
  }
}

public struct InsightConsentSnapshot: Sendable, Hashable {
  public var journal: Bool
  public var health: Bool

  public init(journal: Bool, health: Bool) {
    self.journal = journal
    self.health = health
  }

  public static let none = InsightConsentSnapshot(journal: false, health: false)

  /// Whether what `assembled` sent is still allowed: a class granted since is not a reason to assemble again, one withdrawn is.
  func covers(_ assembled: InsightConsentSnapshot) -> Bool {
    (journal || !assembled.journal) && (health || !assembled.health)
  }
}
