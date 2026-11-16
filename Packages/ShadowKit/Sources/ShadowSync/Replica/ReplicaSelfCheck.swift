import Foundation
import ShadowCore

public struct ReplicaUploadHistory: Sendable, Equatable {
  public var segments: Set<StreamPoint>
  public var bases: Set<StreamPoint>

  public init(segments: Set<StreamPoint> = [], bases: Set<StreamPoint> = []) {
    self.segments = segments
    self.bases = bases
  }
}

public struct ReplicaSelfCheckInput: Sendable, Equatable {
  public var replica: ReplicaID
  public var marker: DeviceMarkerStatus
  public var isRetired: Bool
  public var listed: [ObjectKey]
  public var history: ReplicaUploadHistory

  public init(replica: ReplicaID, marker: DeviceMarkerStatus, isRetired: Bool, listed: [ObjectKey], history: ReplicaUploadHistory) {
    self.replica = replica
    self.marker = marker
    self.isRetired = isRetired
    self.listed = listed
    self.history = history
  }
}

public enum RemintReason: Sendable, Equatable {
  case markerMissing
  case markerNamesOther(ReplicaID)
  case retired
  case unknownSegment(StreamPoint)
  case unknownBase(StreamPoint)
  case unknownObject(ObjectKey)
  case clockCorrected
}

public enum ReplicaSelfCheckVerdict: Sendable, Equatable {
  case pass
  case postpone
  case remint(RemintReason)
}

public enum ReplicaSelfCheck {
  public static func evaluate(_ input: ReplicaSelfCheckInput) -> ReplicaSelfCheckVerdict {
    switch input.marker {
    case .unreadable: return .postpone
    case .missing: return .remint(.markerMissing)
    case .other(let replica): return .remint(.markerNamesOther(replica))
    case .matches: break
    }
    if input.isRetired { return .remint(.retired) }
    let failures = input.listed.compactMap { key in reason(for: key, input: input).map { (key: key, reason: $0) } }
    guard let first = failures.min(by: { $0.key < $1.key }) else { return .pass }
    return .remint(first.reason)
  }

  private static func reason(for key: ObjectKey, input: ReplicaSelfCheckInput) -> RemintReason? {
    switch VaultPath.classify(key) {
    case .manifest(let replica) where replica == input.replica:
      return nil
    case .segment(let replica, _, let last, let tag) where replica == input.replica:
      let point = StreamPoint(last: last, tag: tag)
      return input.history.segments.contains(point) ? nil : .unknownSegment(point)
    case .basePart(let replica, let upTo, let tag, _, _) where replica == input.replica:
      let point = StreamPoint(last: upTo, tag: tag)
      return input.history.bases.contains(point) ? nil : .unknownBase(point)
    default:
      return .unknownObject(key)
    }
  }
}
