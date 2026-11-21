import ProjectDescription

public enum AppCapability: Hashable, Sendable {
  case iCloud(container: String? = nil)
  case pushNotifications
  case remoteNotificationBackgroundMode
  case keychainSharing
  case camera(usage: String)
  case macSandbox

  var supportedPlatforms: Set<Platform> {
    switch self {
    case .iCloud, .pushNotifications, .keychainSharing: [.iOS, .macOS, .visionOS, .tvOS, .watchOS]
    case .remoteNotificationBackgroundMode: [.iOS, .visionOS, .tvOS]
    case .camera: [.iOS, .macOS, .visionOS]
    case .macSandbox: [.macOS]
    }
  }

  var needsSigningTeam: Bool {
    switch self {
    case .iCloud, .pushNotifications, .keychainSharing: true
    case .remoteNotificationBackgroundMode, .camera, .macSandbox: false
    }
  }
}

struct AppCapabilities {
  static let sharedKeychainAccessGroup = "$(AppIdentifierPrefix)\(Organization.appBundleIdPrefix).shared"
  /// The Info.plist dictionary naming the restricted capabilities this build was signed with, so the app never touches one it lacks.
  static let infoPlistKey = "ShadowCapabilities"

  let entitlements: Entitlements?
  let infoPlist: [String: Plist.Value]
  let settings: SettingsDictionary

  init(_ requested: [AppCapability], bundleId: String, platform: AppPlatform, team: String = Organization.developmentTeam) {
    let platforms = platform.destinations.platforms
    let hasUIKit = !platforms.isDisjoint(with: [.iOS, .visionOS, .tvOS])
    let hasMac = platforms.contains(.macOS)
    let signed = !team.isEmpty
    let capabilities = Self.validated(requested, platforms: platforms).filter { signed || !$0.needsSigningTeam }

    var entitlements: [String: Plist.Value] = [:]
    var infoPlist: [String: Plist.Value] = [:]
    var settings: SettingsDictionary = [:]
    var signedWith: [String: Plist.Value] = [:]

    for capability in capabilities {
      switch capability {
      case .iCloud(let container):
        entitlements["com.apple.developer.icloud-container-identifiers"] = [.string(container ?? "iCloud.\(bundleId)")]
        entitlements["com.apple.developer.icloud-services"] = ["CloudKit"]
        signedWith["CloudKitContainer"] = .string(container ?? "iCloud.\(bundleId)")
      case .pushNotifications:
        entitlements["$(SHADOW_APS_ENVIRONMENT_KEY)"] = "development"
        settings["SHADOW_APS_ENVIRONMENT_KEY"] = "aps-environment"
        settings["SHADOW_APS_ENVIRONMENT_KEY[sdk=macosx*]"] = "com.apple.developer.aps-environment"
        signedWith["PushNotifications"] = true
      case .remoteNotificationBackgroundMode:
        if hasUIKit { infoPlist["UIBackgroundModes"] = ["remote-notification"] }
      case .keychainSharing:
        entitlements["keychain-access-groups"] = [.string("$(AppIdentifierPrefix)\(bundleId)"), .string(Self.sharedKeychainAccessGroup)]
        signedWith["SharedKeychainGroup"] = .string(Self.sharedKeychainAccessGroup)
      case .camera(let usage):
        infoPlist["NSCameraUsageDescription"] = .string(usage)
        if hasMac { settings["ENABLE_RESOURCE_ACCESS_CAMERA[sdk=macosx*]"] = "YES" }
      case .macSandbox:
        settings["ENABLE_APP_SANDBOX[sdk=macosx*]"] = "YES"
        settings["ENABLE_OUTGOING_NETWORK_CONNECTIONS[sdk=macosx*]"] = "YES"
        settings["ENABLE_USER_SELECTED_FILES[sdk=macosx*]"] = "readwrite"
      }
    }

    if !signedWith.isEmpty { infoPlist[Self.infoPlistKey] = .dictionary(signedWith) }
    self.entitlements = entitlements.isEmpty ? nil : .dictionary(entitlements)
    self.infoPlist = infoPlist
    self.settings = settings
  }

  private static func validated(_ requested: [AppCapability], platforms: Set<Platform>) -> [AppCapability] {
    var kinds: Set<String> = []
    for capability in requested {
      let kind = String(String(describing: capability).prefix { $0 != "(" })
      precondition(kinds.insert(kind).inserted, "capability \(kind) declared more than once")
      precondition(!platforms.isDisjoint(with: capability.supportedPlatforms), "capability \(kind) applies to none of the app's destinations")
      if case .camera(let usage) = capability { precondition(!usage.isEmpty, "camera capability needs a purpose string") }
    }
    return requested
  }
}
