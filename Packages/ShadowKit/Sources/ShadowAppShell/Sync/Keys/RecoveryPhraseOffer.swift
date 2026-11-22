import Foundation
import Observation
import ShadowDesignSystem
import ShadowSync
import ShadowSyncRuntime
import SwiftUI

/// The offer to set up a recovery phrase, made while this device holds the attached vault's key and no phrase is set up, until the user sets one up or
/// turns the offer down for that vault on this device.
@MainActor
@Observable
final class RecoveryPhraseOffer {
  let sync: SyncRuntimes
  /// The vault the offer is for; nil while there is nothing to offer.
  private(set) var vault: VaultID?
  @ObservationIgnored private let record: RecoveryPhraseRecord

  init(sync: SyncRuntimes, record: RecoveryPhraseRecord? = nil) {
    self.sync = sync
    self.record = record ?? RecoveryPhraseRecord(identity: sync.identity)
  }

  func refresh() async {
    guard let runtime = sync.runtime, let access = try? await runtime.keyServices(), access.holdsKey, !record.isOfferDeclined(for: access.vault) else {
      vault = nil
      return
    }
    vault = (try? await access.recoveryStatus()) == .notSetUp ? access.vault : nil
  }

  func decline() {
    guard let vault else { return }
    record.declineOffer(for: vault)
    self.vault = nil
  }
}

/// `open` shows phrase setup in place; nil opens it the way the sync indicator does, through `SyncKeysButton`.
struct RecoveryPhraseOfferCallout: View {
  let offer: RecoveryPhraseOffer
  let open: (() -> Void)?

  var body: some View {
    ShadowCallout(
      Text("Set up a recovery phrase", tableName: "SyncKeys", bundle: .module),
      message: Text(
        "If you ever lose all your devices, a recovery phrase is the only way back into your synced \(offer.sync.identity.vaultNoun).", tableName: "SyncKeys", bundle: .module),
      intent: .info, systemImage: "checkmark.shield"
    ) {
      if let open {
        Button(action: open) {
          Text("Set Up Recovery Phrase", tableName: "SyncKeys", bundle: .module)
        }
      } else {
        SyncKeysButton(start: .phraseSetup)
      }
      Button(action: offer.decline) {
        Text("Not Now", tableName: "SyncKeys", bundle: .module)
      }
    }
  }
}
