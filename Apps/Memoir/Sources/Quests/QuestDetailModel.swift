import Foundation
import MemoirCore
import Observation
import ShadowAppShell

@MainActor
@Observable
final class QuestDetailModel {
  static let historyLimit = 10

  private let context: MemoirScreenContext
  let questID: UUID
  let detail = ReadObserver<QuestDetail>()
  let threshold = ReadObserver<QuestThresholdSummary?>()
  var isConfirmingDelete = false
  private var isAwaitingConfirmation = false
  private(set) var isDeleting = false
  var failure: PresentedError?

  init(questID: UUID, context: MemoirScreenContext) {
    self.questID = questID
    self.context = context
  }

  /// Only a quest still running can be deleted; deleting keeps it, inactive, with its history (`quest.delete`).
  var canDelete: Bool { detail.state.value?.summary?.quest.isActive == true && !isDeleting }

  func observe() async {
    let id = questID
    let stores = context.stores
    let query = QuestDetailQuery(quest: id, historyLimit: Self.historyLimit)
    async let detail: Void = detail.run { stores.main.observe(QuestDetail.self, query) }
    async let threshold: Void = threshold.run { QuestThresholdReader.observe(id, in: stores) }
    _ = await (detail, threshold)
  }

  func requestDelete() {
    guard canDelete else { return }
    isAwaitingConfirmation = true
    isConfirmingDelete = true
  }

  func cancelDelete() {
    isAwaitingConfirmation = false
    isConfirmingDelete = false
  }

  /// Deletes only what `requestDelete` asked to confirm; the dialog clears `isConfirmingDelete` itself before its button runs.
  @discardableResult
  func delete() async -> Bool {
    let confirmed = isAwaitingConfirmation
    cancelDelete()
    guard confirmed, canDelete else { return false }
    isDeleting = true
    defer { isDeleting = false }
    failure = nil
    do {
      try await context.writer.issue(.questDelete(QuestReference(questId: questID)))
      return true
    } catch {
      failure = WritingErrors.presented(error)
      return false
    }
  }
}
