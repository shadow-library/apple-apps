import Foundation
import ShadowSync

/// Which recovery phrase this device last set up or recovered with, per vault, by its recipient id alone: enough to notice that another device replaced
/// it, and nothing that could recover a key. Also whether the user turned down the offer to set one up.
struct RecoveryPhraseRecord {
  private let keyPrefix: String
  private let declinedPrefix: String
  private let defaults: UserDefaults

  init(identity: AppIdentity, defaults: UserDefaults = .standard) {
    keyPrefix = identity.recoveryRecipientKeyPrefix
    declinedPrefix = identity.recoveryOfferDeclinedKeyPrefix
    self.defaults = defaults
  }

  func recipientID(for vault: VaultID) -> String? {
    defaults.string(forKey: key(vault))
  }

  func save(_ recipientID: String, for vault: VaultID) {
    defaults.set(recipientID, forKey: key(vault))
  }

  func isOfferDeclined(for vault: VaultID) -> Bool {
    defaults.bool(forKey: declinedPrefix + vault.rawValue)
  }

  func declineOffer(for vault: VaultID) {
    defaults.set(true, forKey: declinedPrefix + vault.rawValue)
  }

  private func key(_ vault: VaultID) -> String {
    keyPrefix + vault.rawValue
  }
}
