import Foundation
import ShadowAppShell

/// The withdrawn-purchase notices the owner has dismissed on this device. Replay's notices are append-only, so without this a warning would stay forever.
struct WithdrawalAcknowledgements {
  static let key = "\(AppIdentity.memoir.id).hero.acknowledged-withdrawals"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var commands: Set<UUID> {
    Set((defaults.stringArray(forKey: Self.key) ?? []).compactMap(UUID.init(uuidString:)))
  }

  func acknowledge(_ acknowledged: some Sequence<UUID>) {
    defaults.set(commands.union(acknowledged).map(\.uuidString).sorted(), forKey: Self.key)
  }
}
