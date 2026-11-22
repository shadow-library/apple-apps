import Foundation
import NovelForgeCore
import Observation
import ShadowAppShell
import ShadowStore

struct ActionFailure: Identifiable, Equatable {
  let id = UUID()
  let error: PresentedError
}

@MainActor
@Observable
final class LibraryModel {
  let store: VaultStore
  var selection: UUID?
  var presenting: NovelSheet?
  var failure: ActionFailure?
  private(set) var generation = 0
  private let service: LibraryService
  private let observer = ReadObserver<LibraryList>()
  private var awaiting = Set<UUID>()

  init(store: VaultStore) {
    self.store = store
    service = LibraryService(store: store)
  }

  var state: Loadable<LibraryList> { observer.state }

  func observe() async {
    let store = store
    await observer.run { store.observe(LibraryList.self) }
  }

  func retry() {
    generation += 1
  }

  func present(_ sheet: NovelSheet) {
    guard presenting == nil else { return }
    presenting = sheet
  }

  func context(for novel: UUID) -> NovelContext {
    NovelContext(store: store, novel: novel)
  }

  var knownNovels: Set<UUID> {
    guard let list = state.value else { return [] }
    return Set((list.novels + list.archived).map(\.novel.id))
  }

  func reconcileSelection() {
    guard state.value != nil else { return }
    let known = knownNovels
    awaiting.subtract(known)
    guard let selection, !known.contains(selection), !awaiting.contains(selection) else { return }
    self.selection = nil
  }

  func create(title: String, notes: String) async throws(DomainError) -> UUID {
    let id = try await service.create(title: title, notes: notes)
    select(created: id)
    return id
  }

  func edit(novel: UUID, title: String?, notes: String?) async throws(DomainError) {
    try await service.edit(novel: novel, title: title, notes: notes)
  }

  func clone(source: UUID, name: String) async throws(DomainError) -> UUID {
    let id = try await service.clone(source: source, name: name)
    select(created: id)
    return id
  }

  func loadNotes(novel: UUID) async throws(DomainError) -> String {
    try await service.notes(novel: novel)
  }

  func archive(_ novel: UUID) async {
    await setArchived(true, novel: novel)
  }

  func restore(_ novel: UUID) async {
    await setArchived(false, novel: novel)
  }

  private func select(created id: UUID) {
    awaiting.insert(id)
    selection = id
  }

  private func setArchived(_ archived: Bool, novel: UUID) async {
    do {
      try await service.setArchived(archived, novel: novel)
    } catch {
      failure = ActionFailure(error: PresentedError(error, known: LibraryErrors.headline))
    }
  }
}
