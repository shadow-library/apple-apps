import Foundation
import ShadowSync

/// Which recovery phrase this device last set up or recovered with, per vault, by its recipient id alone: enough to notice that another device replaced
/// it, and nothing that could recover a key. Also whether the user turned down the offer to set one up.
struct RecoveryPhraseRecord {
  static let keyPrefix = "\(SyncWiring.app).sync.recovery-recipient."
  static let declinedPrefix = "\(SyncWiring.app).sync.recovery-offer-declined."

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func recipientID(for vault: VaultID) -> String? {
    defaults.string(forKey: Self.key(vault))
  }

  func save(_ recipientID: String, for vault: VaultID) {
    defaults.set(recipientID, forKey: Self.key(vault))
  }

  func isOfferDeclined(for vault: VaultID) -> Bool {
    defaults.bool(forKey: Self.declinedPrefix + vault.rawValue)
  }

  func declineOffer(for vault: VaultID) {
    defaults.set(true, forKey: Self.declinedPrefix + vault.rawValue)
  }

  private static func key(_ vault: VaultID) -> String {
    keyPrefix + vault.rawValue
  }
}
