import ShadowCore
import ShadowStore

public enum AIConsentState: String, Sendable, Codable {
  case granted
  case revoked
}

public struct AIConsentRecord: Sendable, Equatable {
  public let provider: String
  public let dataClass: String
  public let state: AIConsentState
  public let decidedMillis: Int64
  public let summary: String

  public init(provider: String, dataClass: String, state: AIConsentState, decidedMillis: Int64, summary: String) {
    self.provider = provider
    self.dataClass = dataClass
    self.state = state
    self.decidedMillis = decidedMillis
    self.summary = summary
  }
}

public enum AIConsent {
  public static func decide(
    _ state: AIConsentState, provider: String, dataClass: String, summary: String, atMillis: Int64, in transaction: inout WriteTransaction
  ) throws(StoreError) {
    let fields: [String: JSONValue] = [
      LedgerField.consentState: .string(state.rawValue),
      LedgerField.decided: .int(atMillis),
      LedgerField.summary: .string(summary),
    ]
    _ = try transaction.set(try ref(provider: provider, dataClass: dataClass), fields)
  }

  public static func record(provider: String, dataClass: String, in transaction: ReadTransaction) throws(StoreError) -> AIConsentRecord? {
    let host = try LedgerProvider.normalised(provider)
    guard
      case .record(let record)? = try transaction.state(of: ref(provider: provider, dataClass: dataClass)),
      let state = record[field: LedgerField.consentState]?.value.stringValue.flatMap(AIConsentState.init(rawValue:)),
      let decided = record[field: LedgerField.decided]?.value.intValue,
      let summary = record[field: LedgerField.summary]?.value.stringValue
    else { return nil }
    return AIConsentRecord(provider: host, dataClass: dataClass, state: state, decidedMillis: decided, summary: summary)
  }

  public static func isGranted(provider: String, dataClass: String, currentSummary: String, in transaction: ReadTransaction) throws(StoreError) -> Bool {
    guard let record = try record(provider: provider, dataClass: dataClass, in: transaction) else { return false }
    return record.state == .granted && record.summary == currentSummary
  }

  private static func ref(provider: String, dataClass: String) throws(StoreError) -> EntityRef {
    guard !dataClass.isEmpty else { throw .invalidChange("a consent needs a data class") }
    let host = try LedgerProvider.normalised(provider)
    return EntityRef(kind: LedgerSchema.consentKind, key: .natural(scope: LedgerProvider.consentScope, kind: LedgerSchema.consentKind, components: [host, dataClass]))
  }
}
