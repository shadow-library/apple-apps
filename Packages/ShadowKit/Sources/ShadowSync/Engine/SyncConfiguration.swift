import Foundation
import ShadowStore

public struct SyncConfiguration: Sendable, Equatable {
  public var maximumSegmentBytes: Int
  public var maximumSegmentLines: Int
  public var clockTolerance: Duration
  public var futureLimit: Duration

  public init(
    maximumSegmentBytes: Int = 512 * 1024,
    maximumSegmentLines: Int = 10_000,
    clockTolerance: Duration = .seconds(5 * 60),
    futureLimit: Duration = .seconds(24 * 60 * 60)
  ) {
    self.maximumSegmentBytes = maximumSegmentBytes
    self.maximumSegmentLines = maximumSegmentLines
    self.clockTolerance = clockTolerance
    self.futureLimit = futureLimit
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
