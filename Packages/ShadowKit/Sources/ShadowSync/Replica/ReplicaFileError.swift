import Foundation
import ShadowCore

public enum ReplicaFileError: ShadowError, Equatable {
  case file(VaultFileError)
  case malformed(String)
  case unsupportedFormat(Int64)
  case pathMismatch
  case tooLarge
  case keychain(String)
  case markerNotRepairable

  public var code: String {
    switch self {
    case .file(let error): error.code
    case .malformed: "replica-file.malformed"
    case .unsupportedFormat: "replica-file.unsupported-format"
    case .pathMismatch: "replica-file.path-mismatch"
    case .tooLarge: "replica-file.too-large"
    case .keychain: "replica-file.keychain"
    case .markerNotRepairable: "replica-file.marker-not-repairable"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .file(let error): error.errorDescription
    case .malformed(let reason): "The file content is malformed: \(reason)."
    case .unsupportedFormat(let format): "File format \(format) is not supported."
    case .pathMismatch: "The file's content does not match its name."
    case .tooLarge: "The file exceeds the size limit."
    case .keychain(let reason): "The device marker could not be read or written (\(reason))."
    case .markerNotRepairable: "The device marker holds no unreadable value to repair."
    }
  }
}

enum ReplicaJSON {
  static func object(_ data: Data) throws(ReplicaFileError) -> [String: JSONValue] {
    let value: JSONValue
    do {
      value = try CanonicalJSON.decode(data, mode: .lenient)
    } catch {
      throw .malformed("not JSON")
    }
    guard case .object(let members) = value else { throw .malformed("not an object") }
    return members
  }

  static func requireFormat(_ members: [String: JSONValue], current: Int64) throws(ReplicaFileError) {
    guard case .int(let format)? = members["format"] else { throw .malformed("format is not an integer") }
    guard format >= 1 else { throw .malformed("format is below 1") }
    guard format <= current else { throw .unsupportedFormat(format) }
  }

  static func string(_ members: [String: JSONValue], _ name: String, maximumBytes: Int = .max) throws(ReplicaFileError) -> String {
    guard case .string(let text)? = members[name], text.utf8.count <= maximumBytes else { throw .malformed("\(name) is not a string within its limit") }
    return text
  }

  static func int(_ members: [String: JSONValue], _ name: String, in range: ClosedRange<Int64> = 0...Int64.max) throws(ReplicaFileError) -> Int64 {
    guard case .int(let value)? = members[name], range.contains(value) else { throw .malformed("\(name) is not an integer in range") }
    return value
  }

  static func replica(_ text: String, name: String) throws(ReplicaFileError) -> ReplicaID {
    guard let replica = ReplicaID(text) else { throw .malformed("\(name) is not a replica id") }
    return replica
  }
}
