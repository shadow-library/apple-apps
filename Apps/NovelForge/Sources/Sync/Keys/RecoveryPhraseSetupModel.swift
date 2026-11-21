import Foundation
import Observation
import ShadowSync
import ShadowSyncRuntime

/// Sets up a recovery phrase on a device that holds the library's key. The words live only in the runtime's pending phrase for as long as this flow
/// shows them; they are recorded only after the user types back the words at three positions, and then dropped. All the app keeps is the phrase's
/// recipient id, to notice later that another device replaced it.
@MainActor
@Observable
final class RecoveryPhraseSetupModel {
  enum Step: Equatable {
    case showing
    case confirming
    case saving
    /// `isComplete` is false when copies of a key that arrived meanwhile, or the removal of the old phrase's copies, are left for the next sync.
    case finished(isComplete: Bool)
  }

  let vault: VaultID
  private(set) var step = Step.showing
  private(set) var failure: PresentedError?
  private(set) var mismatched: [Int] = []
  var entries: [Int: String] = [:]
  @ObservationIgnored private let source: SyncKeyServicesSource
  @ObservationIgnored private let record: RecoveryPhraseRecord
  @ObservationIgnored private var pending: PendingRecoveryPhrase?

  init(vault: VaultID, pending: PendingRecoveryPhrase, source: SyncKeyServicesSource, record: RecoveryPhraseRecord) {
    self.vault = vault
    self.pending = pending
    self.source = source
    self.record = record
  }

  /// Empty except while the words are on screen.
  var words: [String] {
    guard step == .showing, let phrase = pending?.phrase else { return [] }
    return phrase.words
  }

  var positions: [Int] { pending?.confirmationPositions ?? [] }

  var canConfirm: Bool {
    step == .confirming && positions.allSatisfy { !(entries[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }

  func wroteDown() {
    guard step == .showing else { return }
    step = .confirming
  }

  func showWordsAgain() {
    guard step == .confirming else { return }
    failure = nil
    mismatched = []
    step = .showing
  }

  func confirm() async {
    guard canConfirm, let pending else { return }
    failure = nil
    mismatched = []
    step = .saving
    let confirmation = entries
    do throws(SyncKeysError) {
      let outcome = try await source.perform(for: vault) { access throws(SyncKeysError) in
        try await SyncKeysError.recovery { () async throws(RecoveryError) in try await access.commitRecoveryPhrase(pending, confirming: confirmation) }
      }
      record.save(outcome.recipientID, for: vault)
      forget()
      step = .finished(isComplete: outcome.isComplete)
    } catch {
      if case .recovery(.confirmationMismatch(let positions)) = error { mismatched = positions }
      failure = SyncKeysErrors.presented(error)
      step = .confirming
    }
  }

  /// Drops the phrase and what was typed; the vault's phrase stays as it was.
  func cancel() {
    forget()
  }

  private func forget() {
    pending = nil
    entries = [:]
  }
}
