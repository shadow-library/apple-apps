import Foundation
import NovelForgeCore
import Observation
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
  private(set) var removed: [RemovedStoryItem] = []
  private let service: StoryService
  private let structureObserver = ReadObserver<StoryStructure>()
  private let ledgerObserver = ReadObserver<KnowledgeLedger>()
  private let bibleObserver = ReadObserver<StoryBibleContents>()
  private let chaptersObserver = ReadObserver<ChapterList>()

  init(context: NovelContext) {
    self.context = context
    service = StoryService(store: context.store, novel: context.novel)
  }

  var structure: Loadable<StoryStructure> { structureObserver.state }
  var ledger: Loadable<KnowledgeLedger> { ledgerObserver.state }
  var bible: Loadable<StoryBibleContents> { bibleObserver.state }
  var chapters: Loadable<ChapterList> { chaptersObserver.state }

  func observe() async {
    async let structure: Void = observeStructure()
    async let ledger: Void = observeLedger()
    async let bible: Void = observeBible()
    async let chapters: Void = observeChapters()
    _ = await (structure, ledger, bible, chapters)
  }

  private func observeStructure() async {
    let (store, novel) = (context.store, context.novel)
    await structureObserver.run { store.observe(StoryStructure.self, novel) }
  }

  private func observeLedger() async {
    let (store, novel) = (context.store, context.novel)
    await ledgerObserver.run { store.observe(KnowledgeLedger.self, novel) }
  }

  private func observeBible() async {
    let (store, novel) = (context.store, context.novel)
    await bibleObserver.run { store.observe(StoryBibleContents.self, novel) }
  }

  private func observeChapters() async {
    let (store, novel) = (context.store, context.novel)
    await chaptersObserver.run { store.observe(ChapterList.self, novel) }
  }

  func retry() {
    generation += 1
  }

  func present(_ sheet: StorySheet) {
    guard presenting == nil else { return }
    presenting = sheet
  }

  var restorable: [RemovedStoryItem] {
    guard let structure = structure.value else { return removed }
    return removed.filter { !structure.isLive($0) }
  }

  func characters() -> [EntityRecord] {
    guard let entities = bible.value?.entities.value?.items else { return [] }
    return entities.filter { $0.type.known == .character }
  }

  func entityName(_ key: String) -> String {
    guard let entities = bible.value?.entities.value?.items, let entity = entities.first(where: { $0.entity == key }) else { return key }
    return entity.name
  }

  func createVolume(key: String, title: String, objective: String, body: String) async throws(DomainError) {
    try await service.createVolume(key: key, title: title.storyNonBlank, objective: objective.storyNonBlank, body: body.storyNonBlank)
  }

  func editVolume(key: String, title: String, objective: String, body: String) async throws(DomainError) {
    let changes = VolumeChanges(title: .set(title.storyNonBlank), objective: .set(objective.storyNonBlank), body: .set(body.storyNonBlank))
    try await service.editVolume(key: key, changes)
  }

  func removeVolume(_ item: VolumeItem) async {
    guard await attempt({ () async throws(DomainError) in try await self.service.removeVolume(key: item.record.volume) }) != nil else { return }
    remember(.volume(key: item.record.volume, name: item.displayName))
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
    guard await attempt({ () async throws(DomainError) in try await self.service.removeMilestone(key: item.record.milestone) }) != nil else { return }
    remember(.milestone(key: item.record.milestone, name: item.record.label))
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
    guard await attempt({ () async throws(DomainError) in try await self.service.removePromise(item.ref) }) != nil else { return }
    remember(.promise(item.ref, name: item.label))
  }

  func saveSecret(key: String, text: String, writerNote: String, constraintNote: String, revealChapter: Int?, unlock: UnlockChange) async throws(DomainError) {
    var changes = SecretChanges(constraintNote: .set(constraintNote.storyNonBlank), writerNote: .set(writerNote.storyNonBlank), revealChapter: .set(revealChapter))
    if case .replace(let terms) = unlock { changes.unlock = .set(UnlockTerm.condition(terms)) }
    try await service.saveSecret(key: key, text: text, changes)
  }

  func removeSecret(_ secret: SecretRecord) async {
    guard await attempt({ () async throws(DomainError) in try await self.service.removeSecret(key: secret.secret) }) != nil else { return }
    remember(.secret(key: secret.secret, name: secret.text))
  }

  func reveal(secret: String, to entity: String, chapter: Int, note: String) async throws(DomainError) {
    try await service.reveal(secret: secret, to: entity, chapter: chapter, note: note.storyNonBlank)
  }

  func retract(secret: String, from entity: String) async {
    _ = await attempt { () async throws(DomainError) in try await self.service.retract(secret: secret, from: entity) }
  }

  func restore(_ item: RemovedStoryItem) async {
    let restored: Void? = await attempt { () async throws(DomainError) in
      switch item {
      case .volume(let key, _): try await self.service.restoreVolume(key: key)
      case .milestone(let key, _): try await self.service.restoreMilestone(key: key)
      case .promise(let promise, _): try await self.service.restorePromise(promise)
      case .secret(let key, _): try await self.service.restoreSecret(key: key)
      }
    }
    guard restored != nil else { return }
    removed.removeAll { $0 == item }
  }

  private func remember(_ item: RemovedStoryItem) {
    removed.removeAll { $0.id == item.id }
    removed.append(item)
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
