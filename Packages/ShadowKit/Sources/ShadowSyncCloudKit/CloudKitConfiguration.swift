import ShadowCore

public struct CloudKitConfiguration: Sendable, Equatable {
  public static let defaultZoneName = "vault-default"
  public static let containerPrefix = "iCloud."

  public let containerIdentifier: String
  public let zoneName: String

  public init(containerIdentifier: String, zoneName: String = defaultZoneName) throws(CloudKitConfigurationError) {
    guard containerIdentifier.hasPrefix(Self.containerPrefix), containerIdentifier.count > Self.containerPrefix.count else {
      throw .invalidContainer(containerIdentifier)
    }
    guard !zoneName.isEmpty, !zoneName.hasPrefix("_") else { throw .invalidZoneName(zoneName) }
    self.containerIdentifier = containerIdentifier
    self.zoneName = zoneName
  }
}

public enum CloudKitConfigurationError: ShadowError, Equatable {
  case invalidContainer(String)
  case invalidZoneName(String)
  case engineAlreadyRunning(String)

  public var code: String {
    switch self {
    case .invalidContainer: "cloudkit.invalid_container"
    case .invalidZoneName: "cloudkit.invalid_zone_name"
    case .engineAlreadyRunning: "cloudkit.engine_already_running"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .invalidContainer(let identifier): "The CloudKit container \"\(identifier)\" must start with \"iCloud.\" and name the container."
    case .invalidZoneName(let name): "The CloudKit zone name \"\(name)\" must not be empty or start with an underscore."
    case .engineAlreadyRunning(let identifier): "A CloudKit client for \"\(identifier)\" is already running in this process."
    }
  }
}
