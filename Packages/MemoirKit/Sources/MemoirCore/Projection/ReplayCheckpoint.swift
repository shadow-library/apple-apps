import CryptoKit
import Foundation
import ShadowCore
import ShadowStore

public enum ReplayCheckpointError: ShadowError, Hashable {
  case notAtBoundary
  case unencodable(String)
  case stale
  case digestMismatch
  case undecodable(String)
  case inconsistent

  public var code: String {
    switch self {
    case .notAtBoundary: "memoir_checkpoint.not_at_boundary"
    case .unencodable: "memoir_checkpoint.unencodable"
    case .stale: "memoir_checkpoint.stale"
    case .digestMismatch: "memoir_checkpoint.digest_mismatch"
    case .undecodable: "memoir_checkpoint.undecodable"
    case .inconsistent: "memoir_checkpoint.inconsistent"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .notAtBoundary: "Only a replay state that has taken in commands, has not halted and has an open day can be checkpointed."
    case .unencodable(let reason): "The replay state could not be encoded: \(reason)"
    case .stale: "The checkpoint was written by another version of the app, its schema or its rules."
    case .digestMismatch: "The checkpoint does not match its digest."
    case .undecodable(let reason): "The checkpoint could not be decoded: \(reason)"
    case .inconsistent: "The checkpoint's state does not match its position, day or ruleset."
    }
  }
}

extension ReplayState {
  /// The canonical JSON of the state: equal states give equal bytes.
  public func canonicalJSON() throws(ReplayCheckpointError) -> Data {
    try MemoirReconciler.canonicalJSON(self)
  }

  public init(canonicalJSON data: Data) throws(ReplayCheckpointError) {
    do {
      self = try JSONDecoder().decode(ReplayState.self, from: data)
    } catch {
      throw .undecodable(String(describing: error))
    }
  }
}

/// A replay state saved where a day is about to close: every command up to `position` taken in and nothing after it, so a command placed after it
/// resumes from here with `Replay.extend` and a command placed at or before it needs an earlier checkpoint. `stamp` names what wrote it (the projection's
/// fingerprint) and the digest binds the body to the row's own fields, so a row edited or written by another version is refused rather than resumed.
public struct ReplayCheckpoint: Sendable, Hashable {
  public static let formatVersion = 1
  static let digestDomain = "com.shadow.library.memoircore.replay-checkpoint"

  /// The open day the next command's walk closes.
  public let day: LocalDate
  public let position: ReplayPosition
  /// The highest ruleset version the state has seen, which the day closes under.
  public let rulesetVersion: Int
  public let stamp: String
  public let body: Data
  public let digest: String

  public init(_ state: ReplayState, stamp: String) throws(ReplayCheckpointError) {
    guard state.halt == nil, let position = state.position, let day = state.openDay, let rulesetVersion = state.highestRulesetVersion else { throw .notAtBoundary }
    let body = try state.canonicalJSON()
    self.init(day: day, position: position, rulesetVersion: rulesetVersion, stamp: stamp, body: body, digest: Self.digest(day, position, rulesetVersion, stamp, body))
  }

  public init(day: LocalDate, position: ReplayPosition, rulesetVersion: Int, stamp: String, body: Data, digest: String) {
    self.day = day
    self.position = position
    self.rulesetVersion = rulesetVersion
    self.stamp = stamp
    self.body = body
    self.digest = digest
  }

  /// The saved state, refused when it was written under another stamp, for a ruleset this build lacks, or does not match its digest or its row.
  public func state(expecting stamp: String) throws(ReplayCheckpointError) -> ReplayState {
    guard self.stamp == stamp, Ruleset.version(rulesetVersion) != nil else { throw .stale }
    guard Self.digest(day, position, rulesetVersion, stamp, body) == digest else { throw .digestMismatch }
    let state = try ReplayState(canonicalJSON: body)
    guard state.position == position, state.openDay == day, state.highestRulesetVersion == rulesetVersion, state.halt == nil else { throw .inconsistent }
    return state
  }

  static func digest(_ day: LocalDate, _ position: ReplayPosition, _ rulesetVersion: Int, _ stamp: String, _ body: Data) -> String {
    let header: JSONValue = [
      .string(digestDomain), .int(Int64(formatVersion)), .string(stamp), .string(day.isoString), .string(position.clock.description),
      .string(position.ref.kind.rawValue), .string(position.ref.key.rawValue), .int(Int64(rulesetVersion)),
    ]
    var hash = SHA256()
    hash.update(data: CanonicalJSON.encode(header))
    hash.update(data: Data([0x0A]))
    hash.update(data: body)
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
