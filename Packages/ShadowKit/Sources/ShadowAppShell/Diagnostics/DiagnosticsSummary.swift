import Foundation

/// `summary.json` in a diagnostics archive: versions, flags, states, counts and error codes. It holds no record, key, token, location, device or file
/// name; free text reaches it only through the app's own summary, and the scrub runs over the encoded file all the same.
nonisolated struct DiagnosticsSummary: Encodable, Sendable {
  static let format = "com.shadow.library.shadowappshell.diagnostics"
  static let currentVersion = 1

  struct App: Encodable, Sendable {
    let id: String
    let name: String
    let version: String
    let build: String?
  }

  struct System: Encodable, Sendable {
    let os: String
    let osVersion: String
    let device: String
    let architecture: String
    let iOSAppOnMac: Bool
    let locale: String
    let utcOffsetSeconds: Int
  }

  struct Sync: Encodable, Sendable {
    let status: String
    let canMoveVault: Bool
    let runtimes: [Runtime]
  }

  struct Runtime: Encodable, Sendable {
    let store: String
    let status: String
    let attention: String?
    let stops: String?
    let failureCode: String?
    let replicasMissingKeys: Int?
    let clockSkewSeconds: Int?
    let phase: String?
    let provider: String?
    let storageClasses: String?
    let runs: Int
    let failedRuns: Int
    let consecutiveFailures: Int
    let unsentWrites: Int
    let lastSucceeded: Date?
    let lastFailed: Date?
    let lastFailureCode: String?
  }

  struct AI: Encodable, Sendable {
    let provider: String
    let isDemo: Bool
    let keys: [String: String]
    let consents: [Consent]?
    let consentsError: String?
  }

  struct Consent: Encodable, Sendable {
    let disclosure: String
    let dataClass: String
    let grantedTo: [String]
  }

  struct Storage: Encodable, Sendable {
    let vaultsBytes: Int?
    let registryVersions: [String: Int]
  }

  struct Log: Encodable, Sendable {
    let since: Date
    let entries: Int
    let dropped: Int
    let error: String?
  }

  let format = Self.format
  let version = Self.currentVersion
  let generatedAt: Date
  let isDemo: Bool
  let app: App
  let system: System
  let capabilities: [String: Bool]
  let sync: Sync?
  let ai: AI?
  let storage: Storage
  let details: [String: DiagnosticsValue]
  var log: Log?

  func encoded() throws(DiagnosticsError) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    do {
      return String(decoding: try encoder.encode(self), as: UTF8.self)
    } catch {
      throw .encoding
    }
  }
}
