import CryptoKit
import Foundation
import ShadowSync

/// The wire layout of one object. Frozen once the schema is deployed to production: renaming a field or changing the name rule orphans every vault.
public enum CloudKitRecordLayout {
  public static let recordType = "VaultObject"
  public static let pathField = "path"
  public static let sizeField = "size"
  public static let bytesField = "bytes"
  public static let partsField = "parts"
  public static let namePrefix = "o-"

  public static let inlineLimit = 512 * 1024
  public static let partBytes = 16 * 1024 * 1024
  public static let maxObjectBytes = 72 * 1024 * 1024

  public static let nameDomain = "com.shadow.library.shadowsynccloudkit.record-name"

  public static func recordName(of key: ObjectKey) -> CloudKitRecordName {
    var hasher = SHA256()
    hasher.update(data: Data(nameDomain.utf8))
    hasher.update(data: Data([0]))
    hasher.update(data: Data(key.rawValue.utf8))
    return CloudKitRecordName(namePrefix + hasher.finalize().map { String(format: "%02x", $0) }.joined())
  }

  static func payload(of data: Data, inlineLimit: Int, partBytes: Int) -> CloudKitPayload {
    guard data.count > inlineLimit else { return .inline(data) }
    let parts = stride(from: 0, to: data.count, by: partBytes).map { start in
      Data(data[data.startIndex.advanced(by: start)..<data.startIndex.advanced(by: min(start + partBytes, data.count))])
    }
    return .parts(parts)
  }

  static func data(of record: CloudKitObjectRecord, key: ObjectKey) throws(StorageError) -> Data {
    guard record.path == key.rawValue else { throw .keyConflict(key) }
    let data: Data
    switch record.payload {
    case .inline(let bytes): data = bytes
    case .parts(let parts): data = parts.reduce(into: Data(capacity: min(max(record.size, 0), maxObjectBytes))) { $0.append($1) }
    }
    guard data.count == record.size else { throw .underlying("The iCloud record for \(key) holds \(data.count) of \(record.size) bytes.") }
    return data
  }
}
