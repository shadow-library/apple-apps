import ProjectDescription

public enum AppCapability: Hashable, Sendable {
  case iCloud(container: String? = nil)
  case pushNotifications
  case remoteNotificationBackgroundMode
  case keychainSharing
  case camera(usage: String)
  case macSandbox
  /// `BGContinuedProcessingTaskRequest` identifiers `<bundle id>.<context>.<suffix>`, permitted by the wildcard `<bundle id>.<context>.*`. Apple documents no
  /// background mode for it, unlike `processing` for `BGProcessingTask` and `fetch` for `BGAppRefreshTask`.
  case continuedProcessing(context: String)
  /// Read-only: no `NSHealthUpdateUsageDescription`, since the app never writes to Health. iOS only, as Apple offers HealthKit to no Mac app.
  case healthKit(usage: String, backgroundDelivery: Bool = false)

  var supportedPlatforms: Set<Platform> {
    switch self {
    case .iCloud, .pushNotifications, .keychainSharing: [.iOS, .macOS, .visionOS, .tvOS, .watchOS]
    case .remoteNotificationBackgroundMode: [.iOS, .visionOS, .tvOS]
    case .camera: [.iOS, .macOS, .visionOS]
    case .macSandbox: [.macOS]
    case .continuedProcessing, .healthKit: [.iOS]
    }
  }

  var needsSigningTeam: Bool {
    switch self {
    case .iCloud, .pushNotifications, .keychainSharing, .healthKit: true
    case .remoteNotificationBackgroundMode, .camera, .macSandbox, .continuedProcessing: false
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
    let hasIOS = platforms.contains(.iOS)
    let signed = !team.isEmpty
    let capabilities = Self.validated(requested, platforms: platforms).filter { signed || !$0.needsSigningTeam }

    var entitlements: [String: Plist.Value] = [:]
    var infoPlist: [String: Plist.Value] = [:]
    var settings: SettingsDictionary = [:]
    var signedWith: [String: Plist.Value] = [:]
    var backgroundModes: [String] = []
    var iOSOnlyEntitlements: [String] = []

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
        if hasUIKit { backgroundModes.append("remote-notification") }
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
      case .continuedProcessing(let context):
        if hasIOS { infoPlist["BGTaskSchedulerPermittedIdentifiers"] = [.string("\(bundleId).\(context).*")] }
      case .healthKit(let usage, let backgroundDelivery):
        iOSOnlyEntitlements.append("com.apple.developer.healthkit")
        if backgroundDelivery { iOSOnlyEntitlements.append("com.apple.developer.healthkit.background-delivery") }
        infoPlist["NSHealthShareUsageDescription"] = .string(usage)
        signedWith["HealthKit"] = "$(SHADOW_HEALTHKIT)"
        settings["SHADOW_HEALTHKIT"] = "NO"
        settings["SHADOW_HEALTHKIT[sdk=iphone*]"] = "YES"
      }
    }

    if !backgroundModes.isEmpty { infoPlist["UIBackgroundModes"] = .array(backgroundModes.map { .string($0) }) }
    if !signedWith.isEmpty { infoPlist[Self.infoPlistKey] = .dictionary(signedWith) }
    if !iOSOnlyEntitlements.isEmpty { settings["CODE_SIGN_ENTITLEMENTS_CONTENTS[sdk=iphone*]"] = .string(Self.entitlementsPlist(enabling: iOSOnlyEntitlements)) }
    self.entitlements = entitlements.isEmpty ? nil : .dictionary(entitlements)
    self.infoPlist = infoPlist
    self.settings = settings
  }

  /// The entitlements file is shared by every platform of a target and a key whose build setting expands to nothing breaks the build, so entitlements one
  /// platform must not carry go through `CODE_SIGN_ENTITLEMENTS_CONTENTS`, which Xcode merges over the file per SDK.
  private static func entitlementsPlist(enabling keys: [String]) -> String {
    #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>"# + keys.map { "<key>\($0)</key><true/>" }.joined() + "</dict></plist>"
  }

  private static func validated(_ requested: [AppCapability], platforms: Set<Platform>) -> [AppCapability] {
    var kinds: Set<String> = []
    for capability in requested {
      let kind = String(String(describing: capability).prefix { $0 != "(" })
      precondition(kinds.insert(kind).inserted, "capability \(kind) declared more than once")
      precondition(!platforms.isDisjoint(with: capability.supportedPlatforms), "capability \(kind) applies to none of the app's destinations")
      if case .camera(let usage) = capability { precondition(!usage.isEmpty, "camera capability needs a purpose string") }
      if case .healthKit(let usage, _) = capability { precondition(!usage.isEmpty, "HealthKit capability needs a purpose string") }
      if case .continuedProcessing(let context) = capability {
        precondition(!context.isEmpty && !context.contains("*") && !context.hasPrefix(".") && !context.hasSuffix("."), "continued processing needs a context such as \"job\"")
      }
    }
    return requested
  }
}
