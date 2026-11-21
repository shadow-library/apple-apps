import ShadowCore
import ShadowStore

public enum JobRecordError: ShadowError {
  case jobNotFound(EntityRef)
  case jobUnreadable(EntityRef, String)
  case attemptExists(EntityRef)
  case attemptNotFound(EntityRef)
  case attemptUnreadable(EntityRef, String)
  case notWriter(EntityRef, owner: ReplicaID, writer: ReplicaID)
  case attemptSettled(EntityRef, AttemptOutcome)
  case attemptInterrupted(EntityRef)
  case store(StoreError)

  public var code: String {
    switch self {
    case .jobNotFound: "job_record.job_not_found"
    case .jobUnreadable: "job_record.job_unreadable"
    case .attemptExists: "job_record.attempt_exists"
    case .attemptNotFound: "job_record.attempt_not_found"
    case .attemptUnreadable: "job_record.attempt_unreadable"
    case .notWriter: "job_record.not_writer"
    case .attemptSettled: "job_record.attempt_settled"
    case .attemptInterrupted: "job_record.attempt_interrupted"
    case .store(let error): error.code
    }
  }

  public var errorDescription: String? {
    switch self {
    case .jobNotFound(let ref): "Job \(ref.key) is not in the store."
    case .jobUnreadable(let ref, let reason): "Job \(ref.key) cannot be read: \(reason)."
    case .attemptExists(let ref): "Attempt \(ref.key) was already started."
    case .attemptNotFound(let ref): "Attempt \(ref.key) is not in the store."
    case .attemptUnreadable(let ref, let reason): "Attempt \(ref.key) cannot be read: \(reason)."
    case .notWriter(let ref, let owner, let writer): "Attempt \(ref.key) is written only by replica \(owner), not \(writer)."
    case .attemptSettled(let ref, let outcome): "Attempt \(ref.key) already ended \(outcome.rawValue)."
    case .attemptInterrupted(let ref): "Attempt \(ref.key) was interrupted on this device and opens no more calls."
    case .store(let error): error.errorDescription
    }
  }
}

struct StoredShapeError: Error {
  let reason: String
}

struct StoredMembers {
  let members: [String: JSONValue]
  private let shape: String

  init(_ value: JSONValue, shape: String) throws(StoredShapeError) {
    guard let members = value.objectValue else { throw StoredShapeError(reason: "\(shape) is not an object") }
    self.members = members
    self.shape = shape
  }

  func string(_ name: String) throws(StoredShapeError) -> String {
    guard let value = members[name]?.stringValue else { throw StoredShapeError(reason: "\(shape).\(name) is not a string") }
    return value
  }

  func int(_ name: String) throws(StoredShapeError) -> Int64 {
    guard let value = members[name]?.intValue else { throw StoredShapeError(reason: "\(shape).\(name) is not an integer") }
    return value
  }

  func bool(_ name: String) throws(StoredShapeError) -> Bool {
    guard let value = members[name]?.boolValue else { throw StoredShapeError(reason: "\(shape).\(name) is not a boolean") }
    return value
  }

  func value<T>(_ name: String, _ decode: (String) -> T?) throws(StoredShapeError) -> T {
    guard let value = decode(try string(name)) else { throw StoredShapeError(reason: "\(shape).\(name) is not a known value") }
    return value
  }

  func json(_ name: String) -> JSONValue {
    members[name] ?? .null
  }
}
