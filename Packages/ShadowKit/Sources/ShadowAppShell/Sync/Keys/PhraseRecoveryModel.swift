import Foundation
import Observation
import ShadowSync
import ShadowSyncRuntime

/// Brings the vault's keys to this device from the 24 words the user typed or pasted. `RecoveryPhrase` normalises the text (case, spacing, Unicode
/// form); the text is cleared once the keys are here or the flow is cancelled.
@MainActor
@Observable
final class PhraseRecoveryModel {
  enum Step: Equatable {
    case entering
    case recovering
    /// `added` counts the keys new to this device.
    case finished(added: Int)
  }

  let vault: VaultID
  var text = ""
  private(set) var step = Step.entering
  private(set) var failure: PresentedError?
  @ObservationIgnored private let source: SyncKeyServicesSource
  @ObservationIgnored private let record: RecoveryPhraseRecord

  @ObservationIgnored private let errors: SyncKeysErrors

  init(vault: VaultID, source: SyncKeyServicesSource, record: RecoveryPhraseRecord, app: AppIdentity) {
    errors = SyncKeysErrors(app: app)
    self.vault = vault
    self.source = source
    self.record = record
  }

  var canRecover: Bool { step == .entering && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  func edited() {
    failure = nil
  }

  func recover() async {
    guard canRecover else { return }
    failure = nil
    let phrase: RecoveryPhrase
    do throws(RecoveryPhraseError) {
      phrase = try RecoveryPhrase(parsing: text)
    } catch {
      failure = errors.presented(.phrase(error))
      return
    }
    step = .recovering
    do throws(SyncKeysError) {
      let imported = try await source.perform(for: vault) { access throws(SyncKeysError) in
        try await SyncKeysError.recovery { () async throws(RecoveryError) in try await access.recover(with: phrase) }
      }
      record.save(RecoveryKey(secret: phrase.secret, vault: vault).recipient.id, for: vault)
      text = ""
      step = .finished(added: imported.added.count)
    } catch {
      failure = errors.presented(error)
      step = .entering
    }
  }

  func cancel() {
    text = ""
  }
}
