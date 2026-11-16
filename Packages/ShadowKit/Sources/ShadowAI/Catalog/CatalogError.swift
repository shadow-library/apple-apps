import Foundation
import ShadowCore

public enum CatalogError: ShadowError, Equatable {
  case unsupportedFormat(found: Int, supported: Int)
  case malformed(String)

  public var code: String {
    switch self {
    case .unsupportedFormat: "catalog.unsupported_format"
    case .malformed: "catalog.malformed"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .unsupportedFormat(let found, let supported): "The model catalog uses format \(found), but this version of the app reads format \(supported) and below."
    case .malformed(let detail): "The model catalog could not be read: \(detail)"
    }
  }
}
