import Foundation
import MemoirCore
import ShadowAppShell

#if os(iOS)
  import UIKit
#endif

/// Whether this device can read Apple Health for the vault.
nonisolated enum HealthAvailability: Equatable, Sendable {
  case available
  /// A Mac app cannot read Health; the vault's iPhone or iPad does.
  case otherPlatform
  /// The build carries no HealthKit entitlement (`ShadowCapabilities.HealthKit` is not `YES`), as a build signed without a team.
  case notEntitled
  /// HealthKit says this device holds no Health data, as some iPads.
  case unavailableOnDevice
  /// The demo's vault, which never reads Health.
  case demo

  /// `HealthKit` is the one `ShadowCapabilities` entry written as a string: `YES` only in an iPhone or iPad build signed with the entitlement.
  static func resolve(isPhoneOrPad: Bool, infoDictionary: [String: Any]?, isHealthDataAvailable: () -> Bool) -> HealthAvailability {
    guard isPhoneOrPad else { return .otherPlatform }
    let capabilities = infoDictionary?[SyncCapabilities.infoPlistKey] as? [String: Any]
    guard capabilities?["HealthKit"] as? String == "YES" else { return .notEntitled }
    return isHealthDataAvailable() ? .available : .unavailableOnDevice
  }
}

/// The built-in metrics this device reads from Health. Reading is per device (only the vault's designated reader reads), so the choice is kept in this
/// device's defaults rather than in the vault.
nonisolated struct HealthPreferences: Sendable {
  static let key = "com.shadow.apps.memoir.health.read-metrics"

  /// Nil for the app's standard defaults; tests name their own suite.
  private let suiteName: String?

  init(suiteName: String? = nil) {
    self.suiteName = suiteName
  }

  private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

  var metrics: Set<BuiltinMetric> {
    get { Set((defaults.stringArray(forKey: Self.key) ?? []).compactMap(BuiltinMetric.init(rawValue:))) }
    nonmutating set { defaults.set(BuiltinMetric.allCases.filter(newValue.contains).map(\.rawValue), forKey: Self.key) }
  }
}

/// What reading Health needs on this device; tests give a fake source and their own defaults.
nonisolated struct HealthEnvironment: Sendable {
  let availability: HealthAvailability
  /// Nil until the device has an identifier for this app's vendor, briefly after a restart, and always on the Mac.
  let device: HealthReaderDevice?
  let source: (any HealthSampleSource)?
  let preferences: HealthPreferences

  @MainActor
  static func live() -> HealthEnvironment {
    #if os(iOS)
      let availability = HealthAvailability.resolve(
        isPhoneOrPad: true, infoDictionary: Bundle.main.infoDictionary, isHealthDataAvailable: { HealthKitSampleSource.isHealthDataAvailable })
      let device = UIDevice.current.identifierForVendor.map { HealthReaderDevice(id: $0, name: UIDevice.current.name) }
      return HealthEnvironment(
        availability: availability, device: device, source: availability == .available ? HealthKitSampleSource.shared : nil,
        preferences: HealthPreferences())
    #else
      return HealthEnvironment(availability: .otherPlatform, device: nil, source: nil, preferences: HealthPreferences())
    #endif
  }

  /// The demo's: it reads nothing and keeps its metric choices apart from the device's.
  static let demo = HealthEnvironment(
    availability: .demo, device: nil, source: nil, preferences: HealthPreferences(suiteName: DemoDefaults.suiteName(for: .memoir)))

  var canRead: Bool { availability == .available && device != nil && source != nil }
}
