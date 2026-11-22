import Foundation
import NovelForgeCore
import Observation
import ShadowAppShell
import ShadowStore

enum StorySheet: Identifiable, Equatable {
  case newVolume
  case editVolume(String)
  case newMilestone
  case editMilestone(String)
  case newPromise
  case editPromise(PromiseRef)
  case newSecret
  case editSecret(String)
  case reveal(secret: String)

  var id: String {
    switch self {
    case .newVolume: "volume-new"
    case .editVolume(let key): "volume-\(key)"
    case .newMilestone: "milestone-new"
    case .editMilestone(let key): "milestone-\(key)"
    case .newPromise: "promise-new"
    case .editPromise(let promise): "promise-\(promise.kindName)-\(promise.key)"
    case .newSecret: "secret-new"
    case .editSecret(let key): "secret-\(key)"
    case .reveal(let secret): "reveal-\(secret)"
    }
  }
}

enum RemovedStoryItem: Hashable, Identifiable {
  case volume(key: String, name: String)
  case milestone(key: String, name: String)
  case promise(PromiseRef, name: String)
  case secret(key: String, name: String)

  var id: String {
    switch self {
    case .volume(let key, _): "volume-\(key)"
    case .milestone(let key, _): "milestone-\(key)"
    case .promise(let promise, _): "promise-\(promise.kindName)-\(promise.key)"
    case .secret(let key, _): "secret-\(key)"
    }
  }

  var name: String {
    switch self {
    case .volume(_, let name), .milestone(_, let name), .promise(_, let name), .secret(_, let name): name
    }
  }
}

struct GoalAdvanceNotice: Identifiable, Equatable {
  let id = UUID()
  let completed: String
  let activated: String?
}

@MainActor
@Observable
final class StoryModel {
  let context: NovelContext
  var presenting: StorySheet?
  var failure: ActionFailure?
  var confirmingGoalMet: String?
  var confirmingDrop: PromiseRef?
  var advance: GoalAdvanceNotice?
  private(set) var generation = 0
  private let service: StoryService
  private let observer = ReadObserver<StoryScreen>()

  init(context: NovelContext) {
    self.context = context
    service = StoryService(store: context.store, novel: context.novel)
  }

  var screen: Loadable<StoryScreen> { observer.state }
  var structure: Loadable<StoryStructure> { screen.map(\.structure) }
  var ledger: Loadable<KnowledgeLedger> { screen.map(\.knowledge) }
  var nextChapter: Int { screen.value?.next.value ?? 1 }
  var entities: [EntityRecord] { screen.value?.entities.value?.items ?? [] }

  func observe() async {
    let (store, novel) = (context.store, context.novel)
    await observer.run { store.observe(StoryScreen.self, novel) }
  }

  func retry() {
    generation += 1
  }

  func present(_ sheet: StorySheet) {
    guard presenting == nil else { return }
    presenting = sheet
  }

  var restorable: [RemovedStoryItem] {
    guard let removed = screen.value?.removed.value else { return [] }
    let volumes = removed.volumes.items.map { RemovedStoryItem.volume(key: $0.volume, name: $0.title?.storyNonBlank ?? $0.volume) }
    let milestones = removed.milestones.items.map { RemovedStoryItem.milestone(key: $0.milestone, name: $0.label) }
    let promises = removed.promises.items.map { RemovedStoryItem.promise($0.ref, name: $0.label) }
    let secrets = removed.secrets.items.map { RemovedStoryItem.secret(key: $0.secret, name: $0.text) }
    return volumes + milestones + promises + secrets
  }

  var removedIsUnavailable: Bool {
    screen.value?.removed.isUnavailable == true
  }

  var violatingChapters: [Int]? {
    screen.value?.reveals.violatedChapters.value
  }

  func violations(of secret: String) -> Derived<[SecretRevealViolation]>? {
    screen.value?.reveals.violations(of: secret)
  }

  func revealViolations(of secret: String) -> [SecretRevealViolation] {
    violations(of: secret)?.value ?? []
  }

  func characters() -> [EntityRecord] {
    entities.filter { $0.type.known == .character }
  }

  func entityName(_ key: String) -> String {
    screen.value?.entityName(key) ?? key
  }

  func createVolume(key: String, title: String, objective: String, body: String) async throws(DomainError) {
    try await service.createVolume(key: key, title: title.storyNonBlank, objective: objective.storyNonBlank, body: body.storyNonBlank)
  }

  func editVolume(key: String, title: String, objective: String, body: String) async throws(DomainError) {
    let changes = VolumeChanges(title: .set(title.storyNonBlank), objective: .set(objective.storyNonBlank), body: .set(body.storyNonBlank))
    try await service.editVolume(key: key, changes)
  }

  func removeVolume(_ item: VolumeItem) async {
    _ = await attempt { () async throws(DomainError) in try await self.service.removeVolume(key: item.record.volume) }
  }

  func markGoalMet(_ key: String) async {
    let names = structure.value?.volumes.value?.items.reduce(into: [String: String]()) { $0[$1.record.volume] = $1.displayName } ?? [:]
    guard let result = await attempt({ () async throws(DomainError) in try await self.service.markGoalMet(key: key) }) else { return }
    advance = GoalAdvanceNotice(completed: names[result.completed] ?? result.completed, activated: result.activated.map { names[$0] ?? $0 })
  }

  func name(ofVolume key: String?) -> String {
    guard let key else { return "" }
    return structure.value?.volume(key)?.displayName ?? key
  }

  func volumeActivated(afterMarking key: String) -> String? {
    guard let items = structure.value?.volumes.value?.items else { return nil }
    let met = items.map { $0.record.volume == key || $0.record.goalMet }
    let passed = (met.lastIndex(of: true) ?? -1) + 1
    guard let index = met.indices.first(where: { $0 >= passed && !met[$0] }) else { return nil }
    return items[index].displayName
  }

  func moveVolume(_ key: String, by offset: Int) async {
    _ = await attempt { () async throws(DomainError) in try await self.service.moveVolumes(.step(key: key, by: offset)) }
  }

  func moveVolumes(from source: IndexSet, to destination: Int) async {
    guard let items = structure.value?.volumes.value?.items else { return }
    let keys = items.map(\.record.volume)
    let moving = source.sorted().map { keys[$0] }
    let anchor = keys.indices.first { $0 >= destination && !source.contains($0) }.map { keys[$0] }
    _ = await attempt { () async throws(DomainError) in try await self.service.moveVolumes(.relocate(keys: moving, before: anchor)) }
  }

  func createMilestone(key: String, label: String, subject: String?, kind: MilestoneKind) async throws(DomainError) {
    try await service.createMilestone(key: key, label: label, subject: subject, kind: kind)
  }

  func editMilestone(key: String, label: String, subject: String?, kind: MilestoneKind?) async throws(DomainError) {
    let changes = MilestoneChanges(label: label, subject: .set(subject), kind: kind.map { .known($0) })
    try await service.editMilestone(key: key, changes)
  }

  func removeMilestone(_ item: MilestoneItem) async {
    _ = await attempt { () async throws(DomainError) in try await self.service.removeMilestone(key: item.record.milestone) }
  }

  func createPromise(_ promise: PromiseRef, label: String) async throws(DomainError) {
    try await service.createPromise(promise, label: label)
  }

  func editPromise(_ promise: PromiseRef, label: String) async throws(DomainError) {
    try await service.updatePromise(promise, label: label, settlement: nil)
  }

  func settle(_ promise: PromiseRef, _ settlement: PromiseSettlement) async {
    _ = await attempt { () async throws(DomainError) in try await self.service.updatePromise(promise, label: nil, settlement: settlement) }
  }

  func drop(_ promise: PromiseRef) async {
    _ = await attempt { () async throws(DomainError) in try await self.service.dropPromise(promise) }
  }

  func removePromise(_ item: StoryPromise) async {
    _ = await attempt { () async throws(DomainError) in try await self.service.removePromise(item.ref) }
  }

  func saveSecret(key: String, text: String, writerNote: String, constraintNote: String, revealChapter: Int?, unlock: UnlockChange) async throws(DomainError) {
    var changes = SecretChanges(constraintNote: .set(constraintNote.storyNonBlank), writerNote: .set(writerNote.storyNonBlank), revealChapter: .set(revealChapter))
    if case .replace(let terms) = unlock { changes.unlock = .set(UnlockTerm.condition(terms)) }
    try await service.saveSecret(key: key, text: text, changes)
  }

  func removeSecret(_ secret: SecretRecord) async {
    _ = await attempt { () async throws(DomainError) in try await self.service.removeSecret(key: secret.secret) }
  }

  func reveal(secret: String, to entity: String, chapter: Int, note: String) async throws(DomainError) {
    try await service.reveal(secret: secret, to: entity, chapter: chapter, note: note.storyNonBlank)
  }

  func retract(secret: String, from entity: String) async {
    _ = await attempt { () async throws(DomainError) in try await self.service.retract(secret: secret, from: entity) }
  }

  func restore(_ item: RemovedStoryItem) async {
    _ = await attempt { () async throws(DomainError) in
      switch item {
      case .volume(let key, _): try await self.service.restoreVolume(key: key)
      case .milestone(let key, _): try await self.service.restoreMilestone(key: key)
      case .promise(let promise, _): try await self.service.restorePromise(promise)
      case .secret(let key, _): try await self.service.restoreSecret(key: key)
      }
    }
  }

  private func attempt<Value: Sendable>(_ work: () async throws(DomainError) -> Value) async -> Value? {
    do {
      return try await work()
    } catch {
      failure = ActionFailure(error: PresentedError(error, known: StoryErrors.headline))
      return nil
    }
  }
}

nonisolated extension String {
  var storyNonBlank: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
