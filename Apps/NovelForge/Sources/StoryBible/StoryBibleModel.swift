import Foundation
import NovelForgeCore
import Observation
import ShadowStore

struct BibleFailure: Identifiable, Equatable {
  let id = UUID()
  let error: PresentedError
}

enum RemovedEntry: Equatable {
  case page(PageAddress, title: String)
  case entity(String, name: String)

  var name: String {
    switch self {
    case .page(_, let title): title
    case .entity(_, let name): name
    }
  }
}

enum BibleSheet: Identifiable, Equatable {
  case newPage
  case newEntity

  var id: Self { self }
}

@MainActor
@Observable
final class StoryBibleModel {
  let context: NovelContext
  var query = ""
  var kind = BibleKindFilter.all
  var presenting: BibleSheet?
  var failure: BibleFailure?
  private(set) var removed: RemovedEntry?
  private(set) var generation = 0
  private(set) var state = Loadable<StoryBibleContents>.loading
  private(set) var catalogue = BibleCatalogue.empty
  private let service: StoryBibleService

  init(context: NovelContext) {
    self.context = context
    service = StoryBibleService(store: context.store, novel: context.novel)
  }

  func observe() async {
    let store = context.store
    let novel = context.novel
    if case .failed = state { state = .loading }
    do {
      for try await contents in store.observe(StoryBibleContents.self, novel) {
        catalogue = BibleCatalogue(pages: contents.pages.value?.items ?? [], entities: contents.entities.value?.items ?? [])
        state = .loaded(contents)
      }
    } catch is CancellationError {
      return
    } catch {
      state = .failed(PresentedError(error))
    }
  }

  func summary(of address: PageAddress) -> PageSummary? {
    state.value?.pages.value?.items.first { $0.section == address.section && $0.slug == address.slug }
  }

  func retry() {
    generation += 1
  }

  func present(_ sheet: BibleSheet) {
    guard presenting == nil else { return }
    presenting = sheet
  }

  func dismissRemoved() {
    removed = nil
  }

  func createPage(section: BiblePageSection, title: String, slug: String, body: String) async throws -> PageAddress {
    try await service.createPage(section: section, title: title, slug: slug, body: body)
  }

  func savePage(_ address: PageAddress, title: String, body: String, basedOn revision: String?) async throws -> PageSaved {
    try await service.savePage(address, title: title, body: body, basedOn: revision)
  }

  func createEntity(key: String, type: EntityType, name: String, details: EntityDetails) async throws -> String {
    try await service.createEntity(key: key, type: type, name: name, details: details)
  }

  func editEntity(key: String, name: String?, details: EntityDetails) async throws {
    try await service.editEntity(key: key, name: name, details: details)
  }

  func removePage(_ address: PageAddress, title: String) async {
    await perform {
      try await service.removePage(address)
    } onSuccess: {
      removed = .page(address, title: title)
    }
  }

  func removeEntity(_ key: String, name: String) async {
    await perform {
      try await service.removeEntity(key)
    } onSuccess: {
      removed = .entity(key, name: name)
    }
  }

  func restorePage(_ address: PageAddress) async {
    await perform {
      try await service.restorePage(address)
    } onSuccess: {
      forgetRemoved(.page(address, title: removed?.name ?? ""))
    }
  }

  func restoreEntity(_ key: String) async {
    await perform {
      try await service.restoreEntity(key)
    } onSuccess: {
      forgetRemoved(.entity(key, name: removed?.name ?? ""))
    }
  }

  func restoreVersion(_ address: PageAddress, revision: String) async -> Bool {
    await perform {
      try await service.restoreVersion(address, revision: revision)
    } onSuccess: {
    }
  }

  func undoRemoval() async {
    switch removed {
    case .page(let address, _): await restorePage(address)
    case .entity(let key, _): await restoreEntity(key)
    case nil: return
    }
  }

  private func forgetRemoved(_ restored: RemovedEntry) {
    switch (removed, restored) {
    case (.page(let left, _), .page(let right, _)) where left == right: removed = nil
    case (.entity(let left, _), .entity(let right, _)) where left == right: removed = nil
    default: return
    }
  }

  @discardableResult
  private func perform(_ work: () async throws -> Void, onSuccess: () -> Void) async -> Bool {
    do {
      try await work()
      onSuccess()
      return true
    } catch {
      failure = BibleFailure(error: StoryBibleErrors.presented(error))
      return false
    }
  }
}
