import Foundation
import MemoirCore
import ShadowAppShell

/// "Not now" on Coming back sets the choices aside for the account's day on this device only, as memoir-web keeps it in its local meta
/// (`synced-hero-provider.ts:366-375`); they come back when the day turns.
struct ComingBackDismissal {
  static let key = "\(AppIdentity.memoir.id).hero.coming-back-dismissed-on"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func isDismissed(on day: LocalDate) -> Bool {
    defaults.string(forKey: Self.key) == day.isoString
  }

  func dismiss(on day: LocalDate) {
    defaults.set(day.isoString, forKey: Self.key)
  }
}
