import ProjectDescription

public enum AppPlatform: String, CaseIterable {
  case ios
  case macos
  case multiplatform
  case phoneAndMac
  case watchos
  case tvos
  case visionos

  public var destinations: Destinations {
    switch self {
    case .ios: [.iPhone, .iPad]
    case .macos: [.mac]
    case .multiplatform: [.iPhone, .iPad, .mac, .appleVision]
    case .phoneAndMac: [.iPhone, .iPad, .mac]
    case .watchos: [.appleWatch]
    case .tvos: [.appleTv]
    case .visionos: [.appleVision]
    }
  }

  public var deploymentTargets: DeploymentTargets {
    let platforms = destinations.platforms
    let version = Organization.minimumOSVersion
    return .multiplatform(
      iOS: platforms.contains(.iOS) ? version : nil,
      macOS: platforms.contains(.macOS) ? version : nil,
      watchOS: platforms.contains(.watchOS) ? version : nil,
      tvOS: platforms.contains(.tvOS) ? version : nil,
      visionOS: platforms.contains(.visionOS) ? version : nil
    )
  }
}
