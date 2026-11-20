import Foundation
import ShadowSync

struct GoogleDriveTuning: Sendable {
  static let chunkGranularity = 256 * 1024

  /// The engine holds whole objects in memory, so the cap is the largest object the codecs can seal: a segment payload, one codec byte, the vault file header and a tag per
  /// chunk, with room to spare. Drive itself takes far larger files.
  static let standardMaxObjectBytes = max(SegmentCodec.maximumPayloadBytes, BaseCodec.maximumPartPayloadBytes) + 8 * 1024 * 1024

  /// Google recommends a multipart upload for files of 5 MB or less and a resumable upload above.
  static let standardMultipartLimit = 5 * 1024 * 1024

  var maxObjectBytes = standardMaxObjectBytes
  var multipartLimit = standardMultipartLimit
  var chunkBytes = 32 * chunkGranularity
  var drivePageSize = 1000
  var listPageSize = 1000
  var catchUpPages = 50
  var enumerationPages = 10_000
  var resumeAttempts = 3
  var readAttempts = 4
  var redirectHops = 3
  /// Drive's search can miss a file for a while after it is created, so the enumeration after a rebuild is repeated once this long after it.
  var settleDelay: TimeInterval = 120
  var tokenSaveInterval: TimeInterval = 600
  var rebuildBackoff: TimeInterval = 3600
  var maxRebuildBackoff: TimeInterval = 86_400
  var now: @Sendable () -> Date = { Date() }
  var makeBoundary: @Sendable () -> String = { "shadow-\(UUID().uuidString.lowercased())" }

  func validated() -> Self {
    precondition(chunkBytes > 0 && chunkBytes.isMultiple(of: Self.chunkGranularity), "Drive upload chunks are positive multiples of 256 KiB")
    precondition(multipartLimit >= 0 && maxObjectBytes >= 0, "size limits are not negative")
    precondition((1...1000).contains(drivePageSize) && listPageSize > 0, "page sizes are positive and Drive pages hold at most 1000 items")
    precondition(
      catchUpPages > 0 && enumerationPages > 0 && resumeAttempts >= 0 && readAttempts > 0 && redirectHops >= 0 && settleDelay >= 0 && tokenSaveInterval >= 0 && rebuildBackoff > 0
        && maxRebuildBackoff >= rebuildBackoff, "bounds are positive")
    return self
  }
}
