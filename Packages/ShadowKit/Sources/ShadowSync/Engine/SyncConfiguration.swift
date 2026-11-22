import Foundation
import ShadowStore

public struct SyncConfiguration: Sendable, Equatable {
  public static let defaultMaximumBlobBytes = 64 * 1024 * 1024

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
  /// Segments uploaded at least this long ago count towards compaction and may be deleted once a base covers them.
  public var compactionAge: Duration
  public var compactionBytes: Int
  public var compactionFiles: Int
  /// The least time between two bases of one replica: every other device downloads each base once.
  public var compactionInterval: Duration
  public var basePartBytes: Int
  /// Counted from the directory record that retired a replica: time for a returning owner to notice, and for readers to finish its stream directly.
  public var adoptionDelay: Duration
  /// How long a base's missing parts or a held file must stay unlisted before an adopter gives up waiting for them; timed on trusted time when the engine has a sample, otherwise on the device clock, which a forward jump cuts short.
  public var adoptionAbandonDelay: Duration
  /// The owner's opt-in that lets activity-class changes reach an `.iCloud` provider; health class never does (App Store guideline 5.1.3(ii)).
  public var activityOnICloud: Bool
  /// The largest blob put or fetched.
  public var maximumBlobBytes: Int
  /// Plaintext bytes in one stored part of a blob; a provider with a smaller object limit gets smaller parts.
  public var blobPartBytes: Int
  /// How long a blob this device put stays stored after nothing names it, and how long its local file outlives its removal.
  public var blobRetention: Duration

  public init(
    maximumSegmentBytes: Int = 512 * 1024,
    maximumSegmentLines: Int = 10_000,
    clockTolerance: Duration = .seconds(5 * 60),
    futureLimit: Duration = .seconds(24 * 60 * 60),
    uploadPassBytes: Int? = nil,
    unreadableFileAttempts: Int = 5,
    dependencyWaitCalls: Int = 3,
    compactionAge: Duration = .seconds(30 * 24 * 60 * 60),
    compactionBytes: Int = 8 * 1024 * 1024,
    compactionFiles: Int = 500,
    compactionInterval: Duration = .seconds(30 * 24 * 60 * 60),
    basePartBytes: Int = BaseCodec.defaultPartPayloadBytes,
    adoptionDelay: Duration = .seconds(30 * 24 * 60 * 60),
    adoptionAbandonDelay: Duration? = nil,
    activityOnICloud: Bool = false,
    maximumBlobBytes: Int = defaultMaximumBlobBytes,
    blobPartBytes: Int = 8 * 1024 * 1024,
    blobRetention: Duration = .seconds(30 * 24 * 60 * 60)
  ) {
    self.maximumSegmentBytes = maximumSegmentBytes
    self.maximumSegmentLines = maximumSegmentLines
    self.clockTolerance = clockTolerance
    self.futureLimit = futureLimit
    self.uploadPassBytes = uploadPassBytes ?? 8 * maximumSegmentBytes
    self.unreadableFileAttempts = unreadableFileAttempts
    self.dependencyWaitCalls = dependencyWaitCalls
    self.compactionAge = compactionAge
    self.compactionBytes = compactionBytes
    self.compactionFiles = compactionFiles
    self.compactionInterval = compactionInterval
    self.basePartBytes = basePartBytes
    self.adoptionDelay = adoptionDelay
    self.adoptionAbandonDelay = adoptionAbandonDelay ?? adoptionDelay
    self.activityOnICloud = activityOnICloud
    self.maximumBlobBytes = maximumBlobBytes
    self.blobPartBytes = blobPartBytes
    self.blobRetention = blobRetention
  }
}

public enum SyncUploadOutcome: Sendable, Equatable {
  case nothingToUpload
  case uploaded([StreamPoint])
  case postponed
  case awaitingKey(floor: KeyID?)
}

public enum SyncCompactionOutcome: Sendable, Equatable {
  case notNeeded
  case compacted(base: StreamPoint, deletedSegments: Int, deletedBases: Int)
  /// No new base this call, because none was needed or one cannot be made yet, but files the current base covers were deleted.
  case cleaned(deletedSegments: Int, deletedBases: Int)
  case postponed
}

public enum SyncDeviceClock: Sendable, Equatable {
  case unchecked
  case correct
  case wrong(skew: Duration)
}

extension StorageClassPolicy {
  func admits(_ syncClass: SyncClass, under configuration: SyncConfiguration) -> Bool {
    switch (self, syncClass) {
    case (.unrestricted, _), (.iCloud, .general): true
    case (.iCloud, .activity): configuration.activityOnICloud
    case (.iCloud, .health): false
    }
  }
}
