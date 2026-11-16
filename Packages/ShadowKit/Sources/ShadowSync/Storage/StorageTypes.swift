import Foundation

public struct StorageObject: Sendable, Hashable {
  public let key: ObjectKey
  public let size: Int

  public init(key: ObjectKey, size: Int) {
    self.key = key
    self.size = size
  }
}

public struct ListCursor: Sendable, Hashable, Codable {
  public let token: String

  public init(token: String) {
    self.token = token
  }
}

public struct ListPage: Sendable {
  public let objects: [StorageObject]
  public let next: ListCursor?

  public init(objects: [StorageObject], next: ListCursor?) {
    self.objects = objects
    self.next = next
  }
}

public enum PutCondition: Sendable {
  case overwrite
  case ifAbsent
}

public struct PutReceipt: Sendable {
  public let serverTime: Date?

  public init(serverTime: Date?) {
    self.serverTime = serverTime
  }
}

public enum StorageClassPolicy: Sendable {
  case iCloud
  case unrestricted
}

public struct StorageCapabilities: Sendable {
  public let pushesChangeNotices: Bool
  public let supportsPutIfAbsent: Bool
  public let hasChangeFeed: Bool
  public let reportsServerTime: Bool
  public let maxObjectBytes: Int
  public let classPolicy: StorageClassPolicy

  public init(
    pushesChangeNotices: Bool,
    supportsPutIfAbsent: Bool,
    hasChangeFeed: Bool,
    reportsServerTime: Bool,
    maxObjectBytes: Int,
    classPolicy: StorageClassPolicy
  ) {
    self.pushesChangeNotices = pushesChangeNotices
    self.supportsPutIfAbsent = supportsPutIfAbsent
    self.hasChangeFeed = hasChangeFeed
    self.reportsServerTime = reportsServerTime
    self.maxObjectBytes = maxObjectBytes
    self.classPolicy = classPolicy
  }
}
