import Foundation

import ShadowCore

public enum VaultCodecError: ShadowError, Equatable {
  case file(VaultFileError)
  case malformed(String)
  case unsupportedFormat(Int64)
  case unsupportedCodec(UInt8)
  case pathMismatch
  case tagMismatch
  case payloadTooLarge
  case lineTooLarge(index: Int)
  case tooManyParts
  case invalidPartPayloadBytes(Int)
  case incomplete(missing: [Int])
  case inconsistentParts(String)

  public var code: String {
    switch self {
    case .file(let error): error.code
    case .malformed: "vault-codec.malformed"
    case .unsupportedFormat: "vault-codec.unsupported-format"
    case .unsupportedCodec: "vault-codec.unsupported-codec"
    case .pathMismatch: "vault-codec.path-mismatch"
    case .tagMismatch: "vault-codec.tag-mismatch"
    case .payloadTooLarge: "vault-codec.payload-too-large"
    case .lineTooLarge: "vault-codec.line-too-large"
    case .tooManyParts: "vault-codec.too-many-parts"
    case .invalidPartPayloadBytes: "vault-codec.invalid-part-payload-bytes"
    case .incomplete: "vault-codec.incomplete"
    case .inconsistentParts: "vault-codec.inconsistent-parts"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .file(let error): error.errorDescription
    case .malformed(let reason): "The file content is malformed: \(reason)."
    case .unsupportedFormat(let format): "Container format \(format) is not supported."
    case .unsupportedCodec(let codec): "Payload codec \(codec) is not supported."
    case .pathMismatch: "The file's content does not match its name."
    case .tagMismatch: "The file's content tag does not match its name."
    case .payloadTooLarge: "The payload exceeds the size limit."
    case .lineTooLarge(let index): "Line \(index) does not fit in one part."
    case .tooManyParts: "The base needs more than \(VaultPath.maximumParts) parts."
    case .invalidPartPayloadBytes(let bytes): "A part payload limit of \(bytes) bytes is outside 1...\(BaseCodec.maximumPartPayloadBytes)."
    case .incomplete(let missing): "The base is missing parts \(missing.map(String.init).joined(separator: ", "))."
    case .inconsistentParts(let reason): "The base parts do not belong together: \(reason)."
    }
  }
}
