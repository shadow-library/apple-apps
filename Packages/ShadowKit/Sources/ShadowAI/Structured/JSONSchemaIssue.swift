import Foundation
import ShadowCore

public struct JSONSchemaIssue: Sendable, Equatable {
  /// A JSONPath such as `$.chapters[2].title`; names that are not identifiers are quoted, as in `$["two words"]`.
  public let path: String
  public let message: String

  public init(path: String, message: String) {
    self.path = path
    self.message = message
  }
}

enum StructuredPathComponent: Sendable {
  case key(String)
  case index(Int)

  static func render(_ components: [StructuredPathComponent]) -> String {
    var path = "$"
    for component in components {
      switch component {
      case .index(let index):
        path += "[\(index)]"
      case .key(let key) where isIdentifier(key):
        path += ".\(key)"
      case .key(let key):
        path += "[\(String(decoding: CanonicalJSON.encode(.string(key)), as: UTF8.self))]"
      }
    }
    return path
  }

  private static func isIdentifier(_ key: String) -> Bool {
    guard let first = key.unicodeScalars.first, first == "_" || isASCIILetter(first) else { return false }
    return key.unicodeScalars.allSatisfy { $0 == "_" || isASCIILetter($0) || ("0"..."9").contains($0) }
  }

  private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
    ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
  }
}
