import Foundation
import ShadowCore

enum JSRegexError: ShadowError, Equatable {
  case invalidFlags(String)
  case unsupportedFlag(Character)
  case syntax(String, offset: Int)
  case unsupported(String, offset: Int)

  var code: String {
    switch self {
    case .invalidFlags: "js-regex.invalid-flags"
    case .unsupportedFlag: "js-regex.unsupported-flag"
    case .syntax: "js-regex.syntax"
    case .unsupported: "js-regex.unsupported"
    }
  }

  var errorDescription: String? {
    switch self {
    case .invalidFlags(let flags): "\"\(flags)\" is not a valid set of regular expression flags."
    case .unsupportedFlag(let flag): "The regular expression flag \"\(flag)\" is not supported."
    case .syntax(let reason, let offset): "The regular expression is invalid at \(offset): \(reason)."
    case .unsupported(let construct, let offset): "The regular expression uses \(construct) at \(offset), which is not supported."
    }
  }
}
