import Foundation
import ShadowSync

public struct OneDriveProviderOptions: Sendable {
  /// Upload session fragments must be a multiple of 320 KiB and below 60 MiB.
  public static let fragmentUnit = 327_680
  public static let maximumFragmentBytes = 60 * 1_048_576
  public static let maximumSimpleUploadBytes = 4 * 1_048_576

  public var pageSize: Int
  /// A sealed segment is its payload (at most `SegmentCodec.maximumPayloadBytes`) plus vault file framing and tags of about a kilobyte;
  /// the headroom lets every segment the codec accepts fit, so an incompressible one never fails as too large.
  public static let defaultMaxObjectBytes = SegmentCodec.maximumPayloadBytes + 8 * 1_048_576

  public var maxObjectBytes: Int
  public var simpleUploadLimit: Int
  public var uploadFragmentBytes: Int
  public var uploadResumes: Int
  public var maxDeltaPagesPerCatchUp: Int

  public init(
    pageSize: Int = 1000, maxObjectBytes: Int = defaultMaxObjectBytes, simpleUploadLimit: Int = maximumSimpleUploadBytes, uploadFragmentBytes: Int = 32 * fragmentUnit,
    uploadResumes: Int = 3, maxDeltaPagesPerCatchUp: Int = 500
  ) {
    self.pageSize = pageSize
    self.maxObjectBytes = maxObjectBytes
    self.simpleUploadLimit = simpleUploadLimit
    self.uploadFragmentBytes = uploadFragmentBytes
    self.uploadResumes = uploadResumes
    self.maxDeltaPagesPerCatchUp = maxDeltaPagesPerCatchUp
  }

  func validated() throws(StorageError) -> Self {
    guard pageSize > 0 else { throw .underlying("page size must be positive") }
    guard maxObjectBytes > 0 else { throw .underlying("the object limit must be positive") }
    guard (0...Self.maximumSimpleUploadBytes).contains(simpleUploadLimit) else { throw .underlying("simple uploads take at most 4 MiB") }
    guard uploadFragmentBytes > 0, uploadFragmentBytes % Self.fragmentUnit == 0, uploadFragmentBytes < Self.maximumFragmentBytes else {
      throw .underlying("an upload fragment is a multiple of 320 KiB below 60 MiB")
    }
    guard uploadResumes >= 0, maxDeltaPagesPerCatchUp > 0 else { throw .underlying("resume and page bounds must not be negative") }
    return self
  }
}
