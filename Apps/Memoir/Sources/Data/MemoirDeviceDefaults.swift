import Foundation
import ShadowAppShell

/// This device's own Memoir preferences, every defaults key under `com.shadow.apps.memoir.`: hero dismissals and acknowledgements, "Remind me on this
/// device", the weight unit, the Health metrics read here. The shell's keys stay: the AI settings belong to the provider connection, as its key in the
/// keychain does, and sync's recovery records describe the vault at its sync location, which deleting on this device does not remove.
nonisolated struct MemoirDeviceDefaults {
  static let prefix = "\(AppIdentity.memoir.id)."
  static let kept = ["\(AppIdentity.memoir.id).ai.", "\(AppIdentity.memoir.id).sync."]

  let defaults: UserDefaults

  /// Returns the keys it removed, sorted.
  @discardableResult
  func forget() -> [String] {
    let keys = defaults.dictionaryRepresentation().keys.filter { key in key.hasPrefix(Self.prefix) && !Self.kept.contains { key.hasPrefix($0) } }.sorted()
    for key in keys { defaults.removeObject(forKey: key) }
    return keys
  }
}
