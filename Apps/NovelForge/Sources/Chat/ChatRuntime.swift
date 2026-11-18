import Foundation
import NovelForgeCore
import OSLog
import Observation
import ShadowStore

/// One turn engine per open vault, shared by every window: the engine alone knows which turns run here, so a second engine on the same vault would read a
/// running turn as interrupted and resume it twice.
@MainActor
@Observable
final class ChatRuntimes {
  @ObservationIgnored private var current: (store: ObjectIdentifier, runtime: ChatRuntime)?

  func runtime(for store: VaultStore, services: AIServices) -> ChatRuntime {
    if let current, current.store == ObjectIdentifier(store) { return current.runtime }
    let created = ChatRuntime.live(store: store, services: services)
    current = (ObjectIdentifier(store), created)
    return created
  }

  func launch(_ store: VaultStore?, services: AIServices) async {
    guard let store else { return }
    await runtime(for: store, services: services).launch()
  }
}

@MainActor
final class ChatRuntime {
  nonisolated private static let logger = Logger(subsystem: "com.shadow.apps.novelforge", category: "chat")

  let store: VaultStore
  let engine: ChatTurnEngine
  private var novels: [UUID: ChatNovelModel] = [:]
  private var launching: Task<Void, Never>?

  init(store: VaultStore, engine: ChatTurnEngine) {
    self.store = store
    self.engine = engine
  }

  static func live(store: VaultStore, services: AIServices) -> ChatRuntime {
    let engine = ChatTurnEngine(store: store, router: { await services.router(store: store) }, consent: ConsentDisclosure.novelText.requirement)
    return ChatRuntime(store: store, engine: engine)
  }

  func model(for context: NovelContext) -> ChatNovelModel {
    if let existing = novels[context.novel] { return existing }
    let created = ChatNovelModel(context: context, engine: engine)
    novels[context.novel] = created
    return created
  }

  /// Once per vault open: pending card actions run, interrupted turns resume or end, and every open chat and Waiting on you then read their turns again.
  func launch() async {
    if let launching { return await launching.value }
    let engine = engine
    let task = Task { [weak self] in
      do throws(StoreError) {
        let resumed = try await engine.resumeInterruptedTurns()
        Self.logger.info("Resumed interrupted chat turns count=\(resumed.count, privacy: .public)")
      } catch {
        Self.logger.error("Interrupted chat turns could not be resumed code=\(error.code, privacy: .public)")
      }
      for novel in self?.novels.values.map({ $0 }) ?? [] { await novel.refreshActivities() }
    }
    launching = task
    await task.value
  }
}
