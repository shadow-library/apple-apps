import Foundation
import NovelForgeCore

extension ChatNovelModel {
  /// ChatColumn.tsx:545-552: the chat's mode as the composer's mode menu sets it; a failure is reported like any other chat operation.
  func saveMode(_ mode: ChatSessionMode, of session: UUID) async -> Bool {
    do {
      try await context.store.setChatSessionMode(session, novel: context.novel, mode: mode)
      return true
    } catch {
      failure = ActionFailure(error: ChatErrors.presented(error))
      return false
    }
  }
}
