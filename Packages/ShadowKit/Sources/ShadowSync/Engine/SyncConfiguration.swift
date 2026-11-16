import Foundation
import ShadowStore

public struct SyncConfiguration: Sendable, Equatable {
  public var maximumSegmentBytes: Int
  public var maximumSegmentLines: Int
  public var clockTolerance: Duration
  public var futureLimit: Duration
  /// Bytes of pending change lines one upload pass reads and seals before its first put; a single larger change still forms a pass of its own.
  public var uploadPassBytes: Int
  /// Calls in which a file fails authentication or is malformed before it is rejected; a rejected file is fetched again only when its listed size changes.
  public var unreadableFileAttempts: Int
  /// Calls a segment waits for a dependency before it is applied anyway: a dependency may name a replica whose files were removed after another replica adopted it, and the join makes applying it safe.
  public var dependencyWaitCalls: Int

  public init(
    maximumSegmentBytes: Int = 512 * 1024,
    maximumSegmentLines: Int = 10_000,
    clockTolerance: Duration = .seconds(5 * 60),
    futureLimit: Duration = .seconds(24 * 60 * 60),
    uploadPassBytes: Int? = nil,
    unreadableFileAttempts: Int = 5,
    dependencyWaitCalls: Int = 3
  ) {
    self.maximumSegmentBytes = maximumSegmentBytes
    self.maximumSegmentLines = maximumSegmentLines
    self.clockTolerance = clockTolerance
    self.futureLimit = futureLimit
    self.uploadPassBytes = uploadPassBytes ?? 8 * maximumSegmentBytes
    self.unreadableFileAttempts = unreadableFileAttempts
    self.dependencyWaitCalls = dependencyWaitCalls
  }
}

public enum SyncUploadOutcome: Sendable, Equatable {
  case nothingToUpload
  case uploaded([StreamPoint])
  case postponed
  case awaitingKey(floor: KeyID?)
}

public enum SyncDeviceClock: Sendable, Equatable {
  case unchecked
  case correct
  case wrong(skew: Duration)
}

extension StorageClassPolicy {
  func admits(_ syncClass: SyncClass) -> Bool {
    switch self {
    case .unrestricted: true
    case .iCloud: syncClass == .general
    }
  }
}
