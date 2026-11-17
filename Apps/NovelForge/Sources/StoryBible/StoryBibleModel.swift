import Foundation
import NovelForgeCore
import Observation
import ShadowStore

struct BibleFailure: Identifiable, Equatable {
  let id = UUID()
  let error: PresentedError
}

enum RemovedEntry: Identifiable, Equatable {
  case page(PageAddress, title: String)
  case entity(String, name: String)

  var id: String {
    switch self {
    case .page(let address, _): "page:\(address.section.rawValue)/\(address.slug)"
    case .entity(let key, _): "entity:\(key)"
    }
  }

  var name: String {
    switch self {
    case .page(_, let title): title
    case .entity(_, let name): name
    }
  }

  var isPage: Bool {
    guard case .page = self else { return false }
    return true
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
  private(set) var generation = 0
  private(set) var catalogue = BibleCatalogue.empty
  private let service: StoryBibleService
  private let observer = ReadObserver<StoryBibleContents>()
  private let removedObserver = ReadObserver<RemovedRecords>()

  init(context: NovelContext) {
    self.context = context
    service = StoryBibleService(store: context.store, novel: context.novel)
  }

  var state: Loadable<StoryBibleContents> { observer.state }

  var removed: [RemovedEntry] {
    guard let bible = removedObserver.state.value?.bible.value else { return [] }
    return bible.entities.items.map { .entity($0.entity, name: $0.name) } + bible.pages.items.map { .page(PageAddress(section: $0.section, slug: $0.slug), title: $0.title) }
  }

  func observe() async {
    async let contents: Void = observeContents()
    async let removed: Void = observeRemoved()
    _ = await (contents, removed)
  }

  func removedEntries(kind: BibleKindFilter, query: String) -> [RemovedEntry] {
    removed.filter { entry in
      switch kind {
      case .all: true
      case .records: !entry.isPage
      case .guides: entry.isPage
      }
    }
    .filter { BibleCatalogue.matches($0.name, query: query) }
  }

  private func observeContents() async {
    let (store, novel) = (context.store, context.novel)
    await observer.run({ store.observe(StoryBibleContents.self, novel) }, onValue: { [self] contents in refreshCatalogue(from: contents) })
  }

  private func observeRemoved() async {
    let (store, novel) = (context.store, context.novel)
    await removedObserver.run { store.observe(RemovedRecords.self, novel) }
  }

  private func refreshCatalogue(from contents: StoryBibleContents) {
    let next = BibleCatalogue(pages: contents.pages.value?.items ?? [], entities: contents.entities.value?.items ?? [], stages: contents.stages.value)
    if next != catalogue { catalogue = next }
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
    await perform { try await service.removePage(address) }
  }

  func removeEntity(_ key: String, name: String) async {
    await perform { try await service.removeEntity(key) }
  }

  func restorePage(_ address: PageAddress) async {
    await perform { try await service.restorePage(address) }
  }

  func restoreEntity(_ key: String) async {
    await perform { try await service.restoreEntity(key) }
  }

  func restoreVersion(_ address: PageAddress, revision: String) async -> Bool {
    await perform { try await service.restoreVersion(address, revision: revision) }
  }

  func restore(_ entry: RemovedEntry) async {
    switch entry {
    case .page(let address, _): await restorePage(address)
    case .entity(let key, _): await restoreEntity(key)
    }
  }

  @discardableResult
  private func perform(_ work: () async throws -> Void) async -> Bool {
    do {
      try await work()
      return true
    } catch {
      failure = BibleFailure(error: StoryBibleErrors.presented(error))
      return false
    }
  }
}
