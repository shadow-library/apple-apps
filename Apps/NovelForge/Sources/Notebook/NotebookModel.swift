import Foundation
import NovelForgeCore
import Observation
import ShadowAppShell
import ShadowStore

enum NotebookSheet: Identifiable, Equatable {
  case add(LedgerEntryKind)
  case rewrite(NotebookEntry)
  case withdraw(NotebookEntry)

  var id: String {
    switch self {
    case .add(let kind): "add-\(kind.rawValue)"
    case .rewrite(let entry): "rewrite-\(entry.id.uuidString)"
    case .withdraw(let entry): "withdraw-\(entry.id.uuidString)"
    }
  }
}

@MainActor
@Observable
final class NotebookModel {
  let context: NovelContext
  let notes: NotebookNotes
  var presenting: NotebookSheet?
  private var visibilities: [NotebookTopic: NotebookVisibility] = [:]
  private(set) var generation = 0
  private let service: NotebookService
  private let observer = ReadObserver<NotebookSnapshot>()

  init(context: NovelContext) {
    self.context = context
    notes = NotebookNotes(context: context)
    service = NotebookService(store: context.store, novel: context.novel)
  }

  var state: Loadable<NotebookSnapshot> { observer.state }

  func observe() async {
    let store = context.store
    let novel = context.novel
    await observer.run { store.observeReads { transaction in try NotebookSnapshot.load(novel: novel, in: transaction) } }
  }

  func visibility(of topic: NotebookTopic) -> NotebookVisibility {
    visibilities[topic] ?? .active
  }

  func setVisibility(_ visibility: NotebookVisibility, of topic: NotebookTopic) {
    visibilities[topic] = visibility
  }

  func retry() {
    generation += 1
  }

  func present(_ sheet: NotebookSheet) {
    guard presenting == nil else { return }
    presenting = sheet
  }

  func add(_ entry: AuthorNotebookEntry) async throws(NotebookError) -> UUID {
    try await service.add(entry)
  }

  func rewrite(_ id: UUID, as rewrite: NotebookRewrite) async throws(NotebookError) -> UUID {
    try await service.rewrite(id, as: rewrite)
  }

  func withdraw(_ id: UUID, reason: String) async throws(NotebookError) {
    try await service.withdraw(id, reason: reason)
  }
}
