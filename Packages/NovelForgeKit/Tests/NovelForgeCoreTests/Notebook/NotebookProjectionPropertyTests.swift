import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

@testable import NovelForgeCore

private typealias Fixture = NotebookFixture

private let topics = ["premise", "pace", "world.rules"]
private let ideas = ["i1", "i2", "i3"]

private func choose(in transaction: borrowing WriteTransaction, _ position: Int) throws -> (id: UUID, novel: UUID)? {
  let entries = try NotebookEntryRecord.listing(in: transaction).entries.map { (id: $0.record.id, novel: $0.record.novel) }
  let items = try NotebookWithdrawalRecord.listing(in: transaction).entries.map { (id: $0.record.id, novel: $0.record.novel) }
  let all = (entries + items).sorted { $0.id.uuidString < $1.id.uuidString }
  return all.isEmpty ? nil : all[position % all.count]
}

private func chooseEntry(in transaction: borrowing WriteTransaction, _ position: Int) throws -> NotebookEntryRecord? {
  let entries = try NotebookEntryRecord.listing(in: transaction).records.sorted { $0.id.uuidString < $1.id.uuidString }
  return entries.isEmpty ? nil : entries[position % entries.count]
}

private func attempting<T>(_ body: () throws(NotebookError) -> T) throws {
  do throws(NotebookError) { _ = try body() } catch {
    guard case .store(let store) = error else { return }
    throw store
  }
}

enum NotebookOperations {
  static let all: [ProjectionOperation] = [
    ProjectionOperation(name: "record Notebook entry", weight: 4) { generator, universe in
      let (novel, topic, text) = (universe.novel(&generator), generator.pick(from: topics), universe.text(&generator))
      let entry =
        generator.chance(0.3)
        ? Fixture.rejection(generator.pick(from: ideas))
        : NewNotebookEntry(kind: generator.pick(from: [.decision, .direction, .backlog, .system]), topic: topic, statement: text, decidedBy: .author)
      return { transaction in try attempting { () throws(NotebookError) in try Notebook.record(entry, novel: novel, in: &transaction) } }
    },
    ProjectionOperation(name: "supersede an entry", weight: 3) { generator, universe in
      let (position, text) = (generator.int(in: 0...10_000), universe.text(&generator))
      return { transaction in
        guard let entry = try chooseEntry(in: transaction, position) else { return }
        try attempting { () throws(NotebookError) in try Notebook.supersedeByAuthor(entry.id, rewrite: NotebookRewrite(statement: text), novel: entry.novel, in: &transaction) }
      }
    },
    ProjectionOperation(name: "withdraw an entry", weight: 2) { generator, _ in
      let position = generator.int(in: 0...10_000)
      return { transaction in
        guard let entry = try chooseEntry(in: transaction, position) else { return }
        try attempting { () throws(NotebookError) in try Notebook.withdraw(entry.id, reason: "No", novel: entry.novel, in: &transaction) }
      }
    },
    ProjectionOperation(name: "supersede without the guards", weight: 3) { generator, universe in
      let (position, id, novel, text) = (generator.int(in: 0...10_000), generator.uuid(), universe.novel(&generator), universe.text(&generator))
      let shape = generator.int(in: 0...9)
      return { transaction in
        let target = try chooseEntry(in: transaction, position)
        let supersedes: UUID? =
          switch shape {
          case 0: UUID()
          case 1: id
          default: target?.id
          }
        let entry = NotebookEntryRecord(
          id: id, novel: shape == 2 ? novel : target?.novel ?? novel, entryKind: .known(.decision), topic: target?.topic ?? "premise", statement: text, supersedes: supersedes)
        _ = try entry.append(in: &transaction)
      }
    },
    ProjectionOperation(name: "withdraw without the guards", weight: 3) { generator, universe in
      let (position, novel, id) = (generator.int(in: 0...10_000), universe.novel(&generator), generator.uuid())
      let shape = generator.int(in: 0...9)
      return { transaction in
        let target = try chooseEntry(in: transaction, position)
        let entry = shape == 0 ? UUID() : target?.id ?? UUID()
        let withdrawal = NotebookWithdrawalRecord(id: id, novel: shape == 1 ? novel : target?.novel ?? novel, entry: entry, reason: "No")
        _ = try withdrawal.append(in: &transaction)
      }
    },
    ProjectionOperation(name: "append an unreadable Notebook entry", weight: 1) { generator, universe in
      let (novel, id) = (universe.novel(&generator), generator.uuid())
      return { transaction in _ = try transaction.append(NovelForgeKey.notebookEntry(id), item: ["novel": .string(novel.uuidString.lowercased())]) }
    },
    ProjectionOperation(name: "purge a Notebook item", weight: 1) { generator, _ in
      let (position, purges) = (generator.int(in: 0...10_000), generator.chance(0.4))
      return { transaction in
        guard purges, let item = try choose(in: transaction, position) else { return }
        for ref in [NovelForgeKey.notebookEntry(item.id), NovelForgeKey.notebookWithdrawal(item.id)] { _ = try transaction.purge(ref) }
      }
    },
  ]
}

private struct Expected: Equatable, CustomStringConvertible {
  let status: LedgerEntryStatus
  let successor: UUID?
  let withdrawal: UUID?

  var description: String { "\(status) successor=\(successor?.uuidString ?? "-") withdrawal=\(withdrawal?.uuidString ?? "-")" }
}

private struct Item {
  let id: UUID
  let novel: UUID
  let supersedes: UUID?
  let clock: HLCTimestamp
  let ref: EntityRef

  func precedes(_ other: Item) -> Bool { clock == other.clock ? ref < other.ref : clock < other.clock }
}

private let reached = Mutex(Set<String>())

private func oracle(_ reconciler: NovelForgeReconciler, _ store: VaultStore, _ universe: ProjectionUniverse) async throws {
  let (entries, withdrawals) = try await store.read { transaction in
    let entries = try NotebookEntryRecord.listing(in: transaction).entries.map {
      Item(id: $0.record.id, novel: $0.record.novel, supersedes: $0.record.supersedes, clock: $0.clock, ref: $0.record.ref)
    }
    let withdrawals = try NotebookWithdrawalRecord.listing(in: transaction).entries.map {
      (item: Item(id: $0.record.id, novel: $0.record.novel, supersedes: nil, clock: $0.clock, ref: $0.record.ref), entry: $0.record.entry)
    }
    return (entries, withdrawals)
  }

  func target(of item: Item) -> UUID? {
    guard let target = item.supersedes, target != item.id, entries.contains(where: { $0.id == target && $0.novel == item.novel }) else { return nil }
    return target
  }

  var expected = [UUID: Expected]()
  for entry in entries {
    var claimants = entries.filter { target(of: $0) == entry.id }
    if let parent = target(of: entry), let newest = entries.filter({ target(of: $0) == parent }).max(by: { $0.precedes($1) }), newest.id != entry.id { claimants.append(newest) }
    let successor = claimants.max { $0.precedes($1) }?.id
    let withdrawal = withdrawals.filter { $0.entry == entry.id && $0.item.novel == entry.novel }.min { $0.item.precedes($1.item) }?.item.id
    expected[entry.id] = Expected(status: withdrawal != nil ? .withdrawn : successor != nil ? .superseded : .active, successor: successor, withdrawal: withdrawal)
  }

  var actual = [UUID: Expected]()
  for novel in universe.novels {
    for row in try await Projection.fetch(NotebookEntryStateDerivation.request(for: novel), in: store) {
      guard entries.first(where: { $0.id == row.entry })?.novel == novel else { throw ProjectionPropertyFailure.oracle("row \(row.entry) filed under novel \(novel)") }
      actual[row.entry] = Expected(status: row.status, successor: row.successor, withdrawal: row.withdrawal)
    }
  }
  let all = try await Projection.fetch(NotebookEntryStateRow.all(), in: store)
  guard all.count == actual.count else { throw ProjectionPropertyFailure.oracle("rows of novels outside the universe") }
  var facts = Set<String>()
  for (id, state) in expected {
    if state.status == .superseded { facts.insert("superseded") }
    if state.status == .withdrawn { facts.insert("withdrawn") }
    if state.status == .withdrawn, state.successor != nil { facts.insert("withdrawn and superseded") }
    if let next = state.successor, let successor = entries.first(where: { $0.id == next }), successor.supersedes != id { facts.insert("superseded by a sibling") }
    if entries.filter({ target(of: $0) == id }).count >= 2 { facts.insert("concurrent supersedes") }
  }
  reached.withLock { $0.formUnion(facts) }
  guard actual == expected else { throw ProjectionPropertyFailure.oracle("Notebook states \(actual) differ from \(expected)") }
}

@Suite("Notebook projection property", TestTimeLimit.property)
struct NotebookProjectionPropertyTests {
  @Test(arguments: [CausalReplicaOrder.causal, .writerOrderOnly])
  func shouldMatchARebuildAtEveryStepAndAgreeWithTheOracleOnEveryReplica(order: CausalReplicaOrder) async throws {
    let property = ProjectionProperty(operations: ProjectionOperations.novels + NotebookOperations.all, iterations: 12, steps: 40, gated: true, settled: oracle)
    try await property.check(order: order, seed: order == .causal ? 0xD17C0 : 0xD17C1)
    #expect(reached.withLock { $0 } == ["superseded", "withdrawn", "withdrawn and superseded", "superseded by a sibling", "concurrent supersedes"])
  }
}
