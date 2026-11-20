import Foundation

/// A name every cloud drive accepts as a folder, so a vault keeps its name when it changes provider.
public struct VaultFolderName: Hashable, Sendable, CustomStringConvertible {
  public static let maxUTF8Length = 64
  private static let reservedNames: Set<String> = {
    let devices = ["con", "prn", "aux", "nul"] + (0...9).flatMap { ["com\($0)", "lpt\($0)"] }
    return Set(devices + ["desktop.ini"])
  }()

  public let rawValue: String

  public init?(_ rawValue: String) {
    guard Self.isValid(rawValue) else { return nil }
    self.rawValue = rawValue
  }

  public var description: String { rawValue }

  private static func isValid(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard (1...maxUTF8Length).contains(bytes.count), bytes.allSatisfy(isAllowed) else { return false }
    guard let first = bytes.first, let last = bytes.last, isAlphanumeric(first), last != UInt8(ascii: " "), last != UInt8(ascii: ".") else { return false }
    let lowered = value.lowercased()
    let stem = String(lowered.prefix { $0 != "." }).trimmingCharacters(in: .whitespaces)
    return !reservedNames.contains(stem) && !reservedNames.contains(lowered) && !lowered.contains("_vti_")
  }

  private static func isAlphanumeric(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"): true
    default: false
    }
  }

  private static func isAllowed(_ byte: UInt8) -> Bool {
    isAlphanumeric(byte) || byte == UInt8(ascii: " ") || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: ".")
  }
}
