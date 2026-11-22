import Foundation
import MemoirCore
import Observation
import ShadowAppShell

/// `features/settings/delete-screen.tsx` without the server's sign-in step: two statements to tick, then the typed word, then a last question; "Stop here"
/// clears the statements, and nothing is erased before the last answer.
@MainActor
@Observable
final class DeleteVaultModel {
  nonisolated enum Acknowledgement: CaseIterable, Sendable {
    case permanent
    case exported
  }

  enum Stage: Equatable {
    case acknowledging
    case confirming
    case deleting
  }

  private(set) var stage = Stage.acknowledging
  private(set) var acknowledged: Set<Acknowledgement> = []
  private(set) var contents = VaultContents.Load.loading
  /// "Stopped. Nothing was started and nothing was erased."
  private(set) var stopped = false
  private(set) var failure: PresentedError?
  var typed = ""
  var isAskingToDelete = false
  var isAskingToStop = false

  private let stores: MemoirStores

  init(context: MemoirScreenContext) {
    stores = context.stores
  }

  func load() async {
    do {
      contents = .loaded(try await VaultContents.read(stores))
    } catch {
      contents = .failed
    }
  }

  func setAcknowledged(_ acknowledgement: Acknowledgement, _ isOn: Bool) {
    guard stage == .acknowledging else { return }
    if isOn { acknowledged.insert(acknowledgement) } else { acknowledged.remove(acknowledgement) }
    stopped = false
  }

  var canContinue: Bool { stage == .acknowledging && acknowledged.count == Acknowledgement.allCases.count }

  func continueToConfirmation() {
    guard canContinue else { return }
    stage = .confirming
    failure = nil
  }

  var canDelete: Bool { stage == .confirming && typed.trimmingCharacters(in: .whitespacesAndNewlines) == DataCopy.typedConfirmation }

  func askToDelete() {
    guard canDelete else { return }
    isAskingToDelete = true
  }

  func askToStop() {
    guard stage == .confirming || stage == .acknowledging else { return }
    isAskingToStop = true
  }

  /// "Stop here": the statements and the typed word are cleared, so starting again begins from the top.
  func stop() {
    guard stage != .deleting else { return }
    isAskingToStop = false
    isAskingToDelete = false
    acknowledged = []
    typed = ""
    failure = nil
    stage = .acknowledging
    stopped = true
  }

  /// The last answer. A refusal that erased nothing brings the confirmation back with the reason; once the vault has closed, this screen goes with it.
  func delete(_ perform: @MainActor () async throws(VaultDeletionError) -> Void) async {
    isAskingToDelete = false
    guard canDelete else { return }
    stage = .deleting
    failure = nil
    do {
      try await perform()
    } catch {
      stage = .confirming
      failure = DataCopy.deletionFailure(error)
    }
  }
}
