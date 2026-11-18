import Foundation
import ShadowCore
import ShadowStore

public enum JobKeyError: ShadowError, Equatable {
  case emptyComponent(String)
  case runOutOfRange(Int)
  case attemptNotVersionSeven(UUID)
  case malformedKey(String)
  case keyMismatch(EntityRef)

  public var code: String {
    switch self {
    case .emptyComponent: "job_key.empty_component"
    case .runOutOfRange: "job_key.run_out_of_range"
    case .attemptNotVersionSeven: "job_key.attempt_not_version_seven"
    case .malformedKey: "job_key.malformed_key"
    case .keyMismatch: "job_key.key_mismatch"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .emptyComponent(let name): "A job's \(name) may not be empty."
    case .runOutOfRange(let run): "\(run) is not a run number; runs start at 1."
    case .attemptNotVersionSeven(let id): "\(id.lowercasedString) is not a version 7 UUID."
    case .malformedKey(let reason): "The stored job request is malformed: \(reason)."
    case .keyMismatch(let ref): "The stored job request does not hash to \(ref.kind)/\(ref.key)."
    }
  }
}

/// The id hashes, under `domain`, scope, kind, target and input fingerprint (each NFC), then the decimal run, in that order for ever.
public struct JobKey: Hashable, Sendable {
  public static let domain = ShadowJobs.identifier + ".job"

  public let scope: String
  public let kind: String
  public let target: String
  public let fingerprint: String
  public let run: Int

  public init(scope: String, kind: String, target: String, fingerprint: String, run: Int) throws(JobKeyError) {
    let nfc = { (text: String) in text.precomposedStringWithCanonicalMapping }
    for (name, text) in [("scope", scope), ("kind", kind), ("target", target), ("fingerprint", fingerprint)] where text.isEmpty { throw .emptyComponent(name) }
    guard run >= 1 else { throw .runOutOfRange(run) }
    self.scope = nfc(scope)
    self.kind = nfc(kind)
    self.target = nfc(target)
    self.fingerprint = nfc(fingerprint)
    self.run = run
  }

  public init(request: JSONValue, of ref: EntityRef) throws(JobKeyError) {
    guard let members = request.objectValue else { throw .malformedKey("it is not an object") }
    let text = { (member: JobRequestMember) throws(JobKeyError) -> String in
      guard let value = members[member.rawValue]?.stringValue else { throw .malformedKey("\(member.rawValue) is not a string") }
      return value
    }
    guard let number = members[JobRequestMember.run.rawValue]?.intValue, let run = Int(exactly: number) else { throw .malformedKey("run is not an integer") }
    try self.init(scope: try text(.scope), kind: try text(.kind), target: try text(.target), fingerprint: try text(.fingerprint), run: run)
    guard self.ref == ref else { throw .keyMismatch(ref) }
  }

  public var ref: EntityRef {
    EntityRef(kind: JobSchema.jobKind, key: .natural(scope: Self.domain, kind: JobSchema.jobKind, components: [scope, kind, target, fingerprint, String(run)]))
  }

  public var requestMembers: [String: JSONValue] {
    [
      JobRequestMember.scope.rawValue: .string(scope), JobRequestMember.kind.rawValue: .string(kind), JobRequestMember.target.rawValue: .string(target),
      JobRequestMember.fingerprint.rawValue: .string(fingerprint), JobRequestMember.run.rawValue: .int(Int64(run)),
    ]
  }
}

public struct AttemptID: Hashable, Sendable {
  public let uuid: UUID

  public init(_ uuid: UUID) throws(JobKeyError) {
    guard uuid.v7Timestamp != nil else { throw .attemptNotVersionSeven(uuid) }
    self.uuid = uuid
  }

  public var ref: EntityRef { EntityRef(kind: JobSchema.attemptKind, key: EntityKey(uuid: uuid)) }
}
