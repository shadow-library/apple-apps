import CryptoKit
import Foundation
import ShadowSync

/// Maps an `ObjectKey` to one file name in the vault folder. OneDrive compares names without letter case and rejects some names, so a name holds
/// only lower-case letters, digits, `.`, `-`, `!` and `~`: `/` becomes `!`, an upper-case letter `X` becomes `~x`, `_` becomes `~1`, a trailing `.`
/// becomes `~0`, and a name OneDrive reserves gets the prefix `~2`. Only the canonical spelling of a key decodes, so no two names share a key.
/// A key whose name would exceed `maximumLength` is stored as `~3` and a digest of the key, with the key written ahead of the object's bytes.
enum OneDriveName {
  enum Decoded: Equatable {
    case key(ObjectKey)
    case overflow(String)
  }

  /// OneDrive limits a name to 255 characters and a whole path to 400; this leaves room for `Apps/<app>/<vault>/`.
  static let maximumLength = 180
  static let overflowMarker = "~3"
  private static let reservedMarker = "~2"
  private static let digestDomain = "com.shadow.library.shadowsynconedrive.long-key"
  private static let reservedNames: Set<String> = {
    let devices = ["con", "prn", "aux", "nul"] + (0...9).flatMap { ["com\($0)", "lpt\($0)"] }
    return Set(devices)
  }()
  private static let reservedWholeNames: Set<String> = ["desktop.ini", ".lock"]

  static func encode(_ key: ObjectKey) -> String {
    let name = plainName(key)
    guard name.utf8.count > maximumLength else { return name }
    return overflowName(key)
  }

  static func overflowName(_ key: ObjectKey) -> String {
    var hasher = SHA256()
    hasher.update(data: Data(digestDomain.utf8))
    hasher.update(data: Data([0]))
    hasher.update(data: Data(key.rawValue.utf8))
    return overflowMarker + hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  static func decode(_ name: String) -> Decoded? {
    if name.utf8.starts(with: overflowMarker.utf8) {
      let digest = name.utf8.dropFirst(overflowMarker.utf8.count)
      guard digest.count == 64, digest.allSatisfy(isLowerHex) else { return nil }
      return .overflow(name)
    }
    guard let key = parse(name), plainName(key) == name, name.utf8.count <= maximumLength else { return nil }
    return .key(key)
  }

  private static func plainName(_ key: ObjectKey) -> String {
    let bytes = Array(key.rawValue.utf8)
    let trailingDots = bytes.reversed().prefix { $0 == UInt8(ascii: ".") }.count
    var name = ""
    name.reserveCapacity(bytes.count)
    for (index, byte) in bytes.enumerated() {
      switch byte {
      case UInt8(ascii: "/"): name += "!"
      case UInt8(ascii: "_"): name += "~1"
      case UInt8(ascii: "A")...UInt8(ascii: "Z"): name += "~" + String(UnicodeScalar(byte + 32))
      case UInt8(ascii: ".") where index >= bytes.count - trailingDots: name += "~0"
      default: name += String(UnicodeScalar(byte))
      }
    }
    return isReserved(name) ? reservedMarker + name : name
  }

  private static func isReserved(_ name: String) -> Bool {
    let stem = String(name.prefix { $0 != "." })
    return reservedNames.contains(stem) || reservedWholeNames.contains(name)
  }

  private static func parse(_ name: String) -> ObjectKey? {
    var bytes = Array(name.utf8)[...]
    if bytes.starts(with: reservedMarker.utf8) { bytes = bytes.dropFirst(reservedMarker.utf8.count) }
    var raw = ""
    while let byte = bytes.popFirst() {
      switch byte {
      case UInt8(ascii: "!"):
        raw += "/"
      case UInt8(ascii: "~"):
        guard let escaped = bytes.popFirst() else { return nil }
        switch escaped {
        case UInt8(ascii: "0"): raw += "."
        case UInt8(ascii: "1"): raw += "_"
        case UInt8(ascii: "a")...UInt8(ascii: "z"): raw += String(UnicodeScalar(escaped - 32))
        default: return nil
        }
      case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "."), UInt8(ascii: "-"):
        raw += String(UnicodeScalar(byte))
      default:
        return nil
      }
    }
    return ObjectKey(raw)
  }

  private static func isLowerHex(_ byte: UInt8) -> Bool {
    (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
  }
}

/// The key of an overflow-named object, written ahead of its bytes: a magic line, the key's length as two big-endian bytes, then the key.
enum OneDriveKeyHeader {
  static let magic = Data("SKK1\n".utf8)
  static let maximumLength = magic.count + 2 + ObjectKey.maxUTF8Length

  static func encode(_ key: ObjectKey) -> Data {
    let bytes = Data(key.rawValue.utf8)
    return magic + Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)]) + bytes
  }

  /// Returns the key and the header's length, or nil when the bytes do not start with a header naming a key that hashes to `name`.
  static func decode(_ data: Data, name: String) -> (key: ObjectKey, length: Int)? {
    let bytes = Array(data.prefix(maximumLength))
    guard bytes.count >= magic.count + 2, bytes.starts(with: magic) else { return nil }
    let count = Int(bytes[magic.count]) << 8 | Int(bytes[magic.count + 1])
    let start = magic.count + 2
    guard bytes.count >= start + count, let raw = String(bytes: bytes[start..<(start + count)], encoding: .utf8), let key = ObjectKey(raw) else { return nil }
    guard OneDriveName.overflowName(key) == name else { return nil }
    return (key, start + count)
  }
}
