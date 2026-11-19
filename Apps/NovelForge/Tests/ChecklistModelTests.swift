import Foundation
import NovelForgeCore
import ShadowStore
import Testing

@testable import NovelForge

@MainActor
@Suite("ChecklistModel")
struct ChecklistModelTests {
  private struct World {
    let store: VaultStore
    let novel: UUID
    let model: ChecklistModel
    let task: Task<Void, Never>
  }

  private func makeWorld() async throws -> World {
    let store = try NovelForgeStore.openInMemory()
    let novel = try await LibraryService(store: store).create(title: "Ashfall", notes: "")
    let model = ChecklistModel(context: NovelContext(store: store, novel: novel))
    let task = Task { await model.observe() }
    try await waitUntil { checklist(model) != nil }
    return World(store: store, novel: novel, model: model, task: task)
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<12_000 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting for the checklist")
  }

  private func checklist(_ model: ChecklistModel) -> Checklist? {
    guard case .shown(let checklist) = model.card else { return nil }
    return checklist
  }

  private func status(_ key: ProgressItemKey, _ model: ChecklistModel) -> ProgressStatus? {
    checklist(model)?.items.first { $0.key == key }?.status
  }

  @Test("should show a fresh novel's checklist with open items")
  func showsOpenItems() async throws {
    let world = try await makeWorld()
    defer { world.task.cancel() }

    let shown = try #require(checklist(world.model))
    #expect(shown.items.map(\.key).contains(.premise))
    #expect(status(.theme, world.model) == .open)
    #expect(shown.percent < 100)
  }

  @Test("should mark an item undecided and clear it back to open")
  func undecidedAndClear() async throws {
    let world = try await makeWorld()
    defer { world.task.cancel() }

    await world.model.markUndecided(.theme)
    try await waitUntil { status(.theme, world.model) == .undecided }
    #expect(world.model.failure == nil)

    await world.model.clear(.theme)
    try await waitUntil { status(.theme, world.model) == .open }
  }

  @Test("should dismiss an item out of the visible list and bring it back")
  func dismissAndRestore() async throws {
    let world = try await makeWorld()
    defer { world.task.cancel() }
    let before = try #require(checklist(world.model)).visible.count

    await world.model.dismiss(.theme)
    try await waitUntil { checklist(world.model)?.visible.count == before - 1 }
    #expect(checklist(world.model)?.dismissed == 1)
    #expect(status(.theme, world.model) == .dismissed)

    await world.model.clear(.theme)
    try await waitUntil { checklist(world.model)?.visible.count == before }
  }

  @Test("should hide the card once every visible item is settled")
  func hidesWhenComplete() async throws {
    let world = try await makeWorld()
    defer { world.task.cancel() }
    let keys = try #require(checklist(world.model)).visible.map(\.key)

    for key in keys { await world.model.markUndecided(key) }

    try await waitUntil { world.model.card == .hidden }
  }

  @Test("should keep a way to bring dismissed items back when the card would hide")
  func dismissedOnlyRow() async throws {
    let world = try await makeWorld()
    defer { world.task.cancel() }
    let keys = try #require(checklist(world.model)).visible.map(\.key)

    await world.model.dismiss(keys[0])
    for key in keys.dropFirst() { await world.model.markUndecided(key) }

    try await waitUntil {
      guard case .dismissedOnly(let list) = world.model.card else { return false }
      return list.dismissed == 1
    }
    await world.model.clear(keys[0])
    try await waitUntil { checklist(world.model) != nil }
  }

  @Test("should show a loading card before the first reading and no card for a missing novel")
  func loadingThenHidden() async throws {
    let store = try NovelForgeStore.openInMemory()
    let model = ChecklistModel(context: NovelContext(store: store, novel: UUID()))
    #expect(model.card == .loading)

    let task = Task { await model.observe() }
    defer { task.cancel() }

    try await waitUntil { model.card == .hidden }
  }

  @Test("should show an error with Try Again for a failing observation and recover on retry")
  func failedThenRetried() async throws {
    let store = try NovelForgeStore.openInMemory()
    let novel = try await LibraryService(store: store).create(title: "Ashfall", notes: "")
    let attempts = Attempts()
    let model = ChecklistModel(context: NovelContext(store: store, novel: novel)) {
      attempts.next() == 1 ? AsyncThrowingStream { $0.finish(throwing: StoreError.database("boom")) } : store.observe(ProgressChecklist.self, novel)
    }
    var generation = model.generation
    let first = Task { await model.observe() }
    try await waitUntil {
      if case .failed = model.card { return true }
      return false
    }
    first.cancel()

    model.retry()
    #expect(model.generation == generation + 1)
    generation = model.generation
    let second = Task { await model.observe() }
    defer { second.cancel() }

    try await waitUntil { checklist(model) != nil }
    #expect(attempts.count == 2)
  }

  @Test("should refuse a second action on the same item while one is running")
  func serialisesPerItem() async throws {
    let world = try await makeWorld()
    defer { world.task.cancel() }

    async let first: Void = world.model.dismiss(.theme)
    async let second: Void = world.model.dismiss(.theme)
    _ = await (first, second)

    #expect(world.model.busy.isEmpty)
    #expect(world.model.failure == nil)
  }

  @Test("should show a localized failure when the novel is gone")
  func failureForMissingNovel() async throws {
    let store = try NovelForgeStore.openInMemory()
    let model = ChecklistModel(context: NovelContext(store: store, novel: UUID()))

    await model.dismiss(.theme)

    #expect(model.failure?.headline == NotebookErrors.headline(for: .novelNotFound(UUID())))
  }

  @Test("should localize every item and status by key")
  func localizedByKey() {
    for key in ProgressItemKey.allCases {
      #expect(!String(localized: key.title).isEmpty)
      #expect(String(localized: key.title) != key.rawValue)
      #expect(!String(localized: key.reason).isEmpty)
    }
    #expect(String(localized: ProgressItemKey.readerPromise.title) == "Reader promise")
    #expect(String(localized: ProgressStatus.undecided.title) == "Undecided for now")
  }
}

private nonisolated final class Attempts: @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0

  var count: Int { lock.withLock { calls } }

  func next() -> Int {
    lock.withLock {
      calls += 1
      return calls
    }
  }
}
