import Foundation
import ShadowAppShell

#if os(iOS)
  import UIKit
#endif

/// "Remind me on this device": kept on this device only, since each device the owner carries decides for itself. Until it is set, an iPhone reminds and
/// an iPad or a Mac does not, so one reminder does not ring on every device at once.
struct ReminderDeviceSetting {
  static let key = "\(AppIdentity.memoir.id).reminders.on-this-device"

  static var remindsByDefault: Bool {
    #if os(iOS)
      UIDevice.current.userInterfaceIdiom == .phone
    #else
      false
    #endif
  }

  private let defaults: UserDefaults
  private let remindsByDefault: Bool

  init(defaults: UserDefaults = .standard, remindsByDefault: Bool = Self.remindsByDefault) {
    self.defaults = defaults
    self.remindsByDefault = remindsByDefault
  }

  var isOn: Bool {
    defaults.object(forKey: Self.key) as? Bool ?? remindsByDefault
  }

  func set(_ isOn: Bool) {
    defaults.set(isOn, forKey: Self.key)
  }
}
