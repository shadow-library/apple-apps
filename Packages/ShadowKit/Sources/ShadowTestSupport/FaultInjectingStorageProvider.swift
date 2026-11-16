import Foundation
import ShadowSync
import Synchronization

public enum StorageOperation: String, Sendable {
  case list
  case get
  case put
  case delete
}

public enum FaultEvent: Sendable, Equatable {
  case transientFailure(StorageOperation)
  case lostAcknowledgement(ObjectKey)
  case staleListing(ObjectKey, operations: Int)
  case partialPage(size: Int)
  case delayedDelete(ObjectKey, operations: Int)
}

public struct FaultPlan: Sendable, Equatable {
  public var transientFailure: Double
  public var lostAcknowledgement: Double
  public var staleListing: Double
  public var partialPage: Double
  public var delayedDelete: Double
  public var staleOperations: ClosedRange<Int>
  public var partialPageSizes: ClosedRange<Int>
  public var pageSize: Int

  public init(
    transientFailure: Double = 0,
    lostAcknowledgement: Double = 0,
    staleListing: Double = 0,
    partialPage: Double = 0,
    delayedDelete: Double = 0,
    staleOperations: ClosedRange<Int> = 1...8,
    partialPageSizes: ClosedRange<Int> = 1...5,
    pageSize: Int = 1000
  ) {
    self.transientFailure = transientFailure
    self.lostAcknowledgement = lostAcknowledgement
    self.staleListing = staleListing
    self.partialPage = partialPage
    self.delayedDelete = delayedDelete
    self.staleOperations = staleOperations
    self.partialPageSizes = partialPageSizes
    self.pageSize = pageSize
  }

  public static let none = FaultPlan()
  public static let hostile = FaultPlan(transientFailure: 0.1, lostAcknowledgement: 0.1, staleListing: 0.5, partialPage: 0.5, delayedDelete: 0.5)
}

public final class FaultInjectingStorageProvider: StorageProvider {
  private struct Ghost {
    let data: Data
    let until: Int
  }

  private struct State {
    var generator: SeededGenerator
    let plan: FaultPlan
    var enabled = true
    var tick = 0
    var hiddenUntil: [ObjectKey: Int] = [:]
    var ghosts: [ObjectKey: Ghost] = [:]
    var log: [FaultEvent] = []

    init(seed: UInt64, plan: FaultPlan) {
      generator = SeededGenerator(seed: seed)
      self.plan = plan
    }

    mutating func roll(_ probability: Double) -> Bool {
      guard enabled, probability > 0 else { return false }
      return generator.chance(probability)
    }

    mutating func begin(_ operation: StorageOperation) -> Bool {
      tick += 1
      hiddenUntil = hiddenUntil.filter { $0.value > tick }
      ghosts = ghosts.filter { $0.value.until > tick }
      guard roll(plan.transientFailure) else { return false }
      log.append(.transientFailure(operation))
      return true
    }
  }

  private let inner: any StorageProvider
  private let state: Mutex<State>

  public init(wrapping inner: any StorageProvider, seed: UInt64, plan: FaultPlan = .hostile) {
    precondition(plan.pageSize > 0, "page size must be positive")
    self.inner = inner
    state = Mutex(State(seed: seed, plan: plan))
  }

  public var capabilities: StorageCapabilities { inner.capabilities }

  public var faultLog: [FaultEvent] { state.withLock { $0.log } }

  public func setFaultsEnabled(_ enabled: Bool) {
    state.withLock { $0.enabled = enabled }
  }

  public func heal() {
    state.withLock { state in
      state.hiddenUntil = [:]
      state.ghosts = [:]
    }
  }

  public func list(prefix: String, after cursor: ListCursor?) async throws(StorageError) -> ListPage {
    if state.withLock({ $0.begin(.list) }) { throw .unavailable("injected failure") }
    let truth = try await inner.listAll(prefix: prefix)
    return state.withLock { state in
      var visible = truth.filter { state.hiddenUntil[$0.key] == nil }
      let present = Set(truth.map(\.key))
      for (key, ghost) in state.ghosts where key.hasPrefix(prefix) && !present.contains(key) {
        visible.append(StorageObject(key: key, size: ghost.data.count))
      }
      visible.sort { $0.key < $1.key }
      let remaining = cursor.map { cursor in visible.filter { cursor.token.utf8.lexicographicallyPrecedes($0.key.rawValue.utf8) } } ?? visible
      var pageSize = state.plan.pageSize
      if state.roll(state.plan.partialPage) {
        pageSize = state.generator.int(in: state.plan.partialPageSizes)
        state.log.append(.partialPage(size: pageSize))
      }
      let objects = Array(remaining.prefix(pageSize))
      let next = remaining.count > pageSize ? objects.last.map { ListCursor(token: $0.key.rawValue) } : nil
      return ListPage(objects: objects, next: next)
    }
  }

  public func get(_ key: ObjectKey) async throws(StorageError) -> Data {
    if state.withLock({ $0.begin(.get) }) { throw .unavailable("injected failure") }
    do {
      return try await inner.get(key)
    } catch {
      guard case .notFound = error, let ghost = state.withLock({ $0.ghosts[key] }) else { throw error }
      return ghost.data
    }
  }

  public func put(_ key: ObjectKey, data: Data, condition: PutCondition) async throws(StorageError) -> PutReceipt {
    if state.withLock({ $0.begin(.put) }) { throw .unavailable("injected failure") }
    let existed = await containsObject(key)
    let receipt = try await inner.put(key, data: data, condition: condition)
    let lost = state.withLock { state in
      state.ghosts[key] = nil
      if !existed && state.roll(state.plan.staleListing) {
        let operations = state.generator.int(in: state.plan.staleOperations)
        state.hiddenUntil[key] = state.tick + operations
        state.log.append(.staleListing(key, operations: operations))
      }
      guard state.roll(state.plan.lostAcknowledgement) else { return false }
      state.log.append(.lostAcknowledgement(key))
      return true
    }
    if lost { throw .unavailable("injected lost acknowledgement") }
    return receipt
  }

  public func delete(_ keys: [ObjectKey]) async throws(StorageError) {
    if state.withLock({ $0.begin(.delete) }) { throw .unavailable("injected failure") }
    let delayed: [(key: ObjectKey, operations: Int)] = state.withLock { state in
      keys.compactMap { key in
        guard state.roll(state.plan.delayedDelete) else { return nil }
        return (key, state.generator.int(in: state.plan.staleOperations))
      }
    }
    var snapshots: [(key: ObjectKey, operations: Int, data: Data)] = []
    for (key, operations) in delayed {
      guard let data = try? await inner.get(key) else { continue }
      snapshots.append((key, operations, data))
    }
    try await inner.delete(keys)
    state.withLock { state in
      for key in keys { state.hiddenUntil[key] = nil }
      for (key, operations, data) in snapshots {
        state.ghosts[key] = Ghost(data: data, until: state.tick + operations)
        state.log.append(.delayedDelete(key, operations: operations))
      }
    }
  }

  private func containsObject(_ key: ObjectKey) async -> Bool {
    guard let page = try? await inner.list(prefix: key.rawValue, after: nil) else { return true }
    return page.objects.first?.key == key
  }

  public func changeNotices() -> AsyncStream<Void> {
    inner.changeNotices()
  }
}
