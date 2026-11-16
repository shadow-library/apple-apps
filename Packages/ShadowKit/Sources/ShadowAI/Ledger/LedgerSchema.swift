import ShadowStore

public enum LedgerSchema {
  public static let modelCallKind = makeKind("ai_model_call")
  public static let consentKind = makeKind("ai_consent")

  public static let entities: [EntitySchema] = [
    EntitySchema(
      kind: modelCallKind,
      shape: .record(fields: [
        LedgerField.call: .firstWriterWins,
        LedgerField.requestID: .firstWriterWins,
        LedgerField.generationID: .firstWriterWins,
        LedgerField.outcome: .monotone(order: LedgerOutcome.order),
        LedgerField.usage: .register,
        LedgerField.costReported: .firstWriterWins,
        LedgerField.costComputed: .register,
      ]),
      syncClass: .general
    ),
    EntitySchema(
      kind: consentKind,
      shape: .record(fields: [
        LedgerField.consentState: .register,
        LedgerField.decided: .register,
        LedgerField.summary: .register,
      ]),
      syncClass: .general
    ),
  ]

  private static func makeKind(_ name: String) -> EntityKind {
    guard let kind = EntityKind(name) else { preconditionFailure("\(name) is a valid entity kind") }
    return kind
  }
}

enum LedgerField {
  static let call = "call"
  static let outcome = "outcome"
  static let requestID = "request_id"
  static let generationID = "generation_id"
  static let usage = "usage"
  static let costReported = "cost_reported"
  static let costComputed = "cost_computed"
  static let consentState = "state"
  static let decided = "decided"
  static let summary = "summary"
}

enum LedgerCallKey {
  static let provider = "provider"
  static let model = "model"
  static let task = "task"
  static let pace = "pace"
  static let started = "started"
  static let parent = "parent"
}

enum LedgerUsageKey {
  static let input = "input"
  static let output = "output"
  static let cacheRead = "cache_read"
  static let cacheWriteShort = "cache_write_short"
  static let cacheWriteLong = "cache_write_long"
}

enum LedgerProvider {
  static let consentScope = "shadow.ai.consent"

  /// Providers are identified by a bare ASCII host: lower case, trailing dots removed; ports, credentials, paths, spaces and non-ASCII are refused.
  static func normalised(_ host: String) throws(StoreError) -> String {
    let bytes = host.utf8
    let isBare = bytes.allSatisfy { (0x21...0x7E).contains($0) && ![UInt8(ascii: ":"), UInt8(ascii: "@"), UInt8(ascii: "/")].contains($0) }
    let trimmed = String(host.lowercased().reversed().drop { $0 == "." }.reversed())
    guard isBare, !trimmed.isEmpty else { throw .invalidChange("\"\(host)\" is not a bare ASCII provider host") }
    return trimmed
  }
}
