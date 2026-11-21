import Foundation
import ShadowCore

/// The one device of the vault that reads Apple Health.
public struct HealthReaderDesignation: Sendable, Hashable, StoredValue {
  public let device: UUID
  public let name: String
  public let claimedAtMillis: Int64

  public init(device: UUID, name: String, claimedAtMillis: Int64) {
    self.device = device
    self.name = name
    self.claimedAtMillis = claimedAtMillis
  }

  public init?(stored: JSONValue) {
    guard
      let designation = MemberReader<HealthReaderMember>.nested(
        stored,
        { reader throws(MemoirUnreadable) in
          HealthReaderDesignation(device: try reader.required(.device), name: try reader.required(.name), claimedAtMillis: try reader.required(.claimedAtMillis))
        })
    else { return nil }
    self = designation
  }

  public var stored: JSONValue {
    var members = RecordMembers<HealthReaderMember>()
    members.put(.device, device)
    members.put(.name, name)
    members.put(.claimedAtMillis, claimedAtMillis)
    return members.json
  }
}

/// General class, so every device of the vault learns which device reads Health and whether Activity may sync through iCloud. Each member is written
/// only by the write that changes it and is absent until then, so a claim and a toggle made on two devices at once both survive.
public struct HealthSettingsRecord: NaturalKeyRecord {
  public static let kind = MemoirKind.healthSettings

  public var reader: HealthReaderDesignation?
  public var activityOnICloud: Bool?

  public init(reader: HealthReaderDesignation? = nil, activityOnICloud: Bool? = nil) {
    self.reader = reader
    self.activityOnICloud = activityOnICloud
  }

  public init(key: MemoirKey, reading reader: MemberReader<HealthSettingsField>) throws(MemoirUnreadable) {
    guard case .healthSettings = key else { throw .identity(key.ref) }
    self.init(reader: try reader.optional(.reader), activityOnICloud: try reader.optional(.activityOnICloud))
  }

  public var key: MemoirKey { .healthSettings }

  public var isActivityOnICloud: Bool { activityOnICloud ?? false }

  public var members: RecordMembers<HealthSettingsField> {
    var members = RecordMembers<HealthSettingsField>()
    members.put(.reader, reader)
    members.put(.activityOnICloud, activityOnICloud)
    return members
  }
}
