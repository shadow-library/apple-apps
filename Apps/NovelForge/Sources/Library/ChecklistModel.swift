import Foundation
import NovelForgeCore
import Observation
import ShadowAppShell
import ShadowStore

enum ChecklistCard: Equatable {
  case loading
  case failed(PresentedError)
  case hidden
  case unavailable
  case shown(Checklist)
  case dismissedOnly(Checklist)
}

@MainActor
@Observable
final class ChecklistModel {
  private(set) var generation = 0
  private(set) var failure: PresentedError?
  private(set) var busy: Set<ProgressItemKey> = []
  private let context: NovelContext
  private let service: NotebookService
  private let observer = ReadObserver<ProgressChecklist>()
  private let makeStream: () -> AsyncThrowingStream<ProgressChecklist, any Error>

  init(context: NovelContext, observe: (() -> AsyncThrowingStream<ProgressChecklist, any Error>)? = nil) {
    self.context = context
    let (store, novel) = (context.store, context.novel)
    makeStream = observe ?? { store.observe(ProgressChecklist.self, novel) }
    service = NotebookService(store: context.store, novel: context.novel)
  }

  var card: ChecklistCard {
    switch observer.state {
    case .loading: .loading
    case .failed(let error): .failed(error)
    case .loaded(let reading): card(for: reading)
    }
  }

  func observe() async {
    await observer.run(makeStream)
  }

  func markUndecided(_ key: ProgressItemKey) async {
    await apply(key) { try await service.override(key, as: .undecided) }
  }

  func dismiss(_ key: ProgressItemKey) async {
    await apply(key) { try await service.override(key, as: .dismissed) }
  }

  func clear(_ key: ProgressItemKey) async {
    await apply(key) { try await service.clearOverride(key) }
  }

  func retry() {
    generation += 1
  }

  private func card(for reading: ProgressChecklist) -> ChecklistCard {
    guard let checklist = reading.checklist.value?.checklist else { return reading.checklist.isUnavailable ? .unavailable : .hidden }
    guard !checklist.visible.isEmpty, !checklist.isComplete else { return checklist.dismissed > 0 ? .dismissedOnly(checklist) : .hidden }
    return .shown(checklist)
  }

  private func apply(_ key: ProgressItemKey, _ work: () async throws -> Void) async {
    guard busy.insert(key).inserted else { return }
    defer { busy.remove(key) }
    failure = nil
    do {
      try await work()
    } catch {
      failure = NotebookErrors.present(error)
    }
  }
}
