import Foundation
import NovelForgeCore
import ShadowStore

nonisolated enum NotebookVisibility: String, CaseIterable, Hashable, Sendable {
  case active
  case all
}

nonisolated enum NotebookLookup: Equatable, Sendable {
  case found(NotebookEntry)
  case missing
}

nonisolated struct NotebookSnapshot: Sendable, Equatable {
  let contents: NotebookContents
  let ledger: NotebookLedger
  let reasons: [UUID: String]

  static func load(novel: UUID, in transaction: ReadTransaction) throws -> NotebookSnapshot {
    NotebookSnapshot(
      contents: try NotebookContents.load(NotebookQuery(novel: novel), in: transaction), ledger: try NotebookLedger.load(novel: novel, in: transaction),
      reasons: try NotebookEntryRecord.withdrawals(novel: novel, in: transaction).mapValues(\.record.reason))
  }

  var isAvailable: Bool { contents.notebook.value != nil }
  var unreadable: Int { ledger.unreadable }

  func lookup(_ id: UUID) -> NotebookLookup {
    guard let entry = ledger.entry(id), NotebookTopics.isVisibleInNotebook(entry.record.topic) else { return .missing }
    return .found(entry)
  }

  func entries(in topic: NotebookTopic, showing visibility: NotebookVisibility) -> [NotebookEntry] {
    (visibility == .active ? active(in: topic) : all(in: topic)).sorted(by: Self.newestFirst)
  }

  func activeCount(in topic: NotebookTopic) -> Int {
    active(in: topic).count
  }

  func earlierCount(in topic: NotebookTopic) -> Int {
    all(in: topic).count { $0.status != .active }
  }

  func passedOver() -> [NotebookSections.PassedOver] {
    NotebookSections(of: ledger.entries.filter { $0.status == .active }).passedOver
  }

  func successor(of entry: NotebookEntry) -> NotebookEntry? {
    entry.state.successor.flatMap(ledger.entry)
  }

  func predecessor(of entry: NotebookEntry) -> NotebookEntry? {
    entry.record.supersedes.flatMap(ledger.entry)
  }

  func history(of entry: NotebookEntry) -> [NotebookEntry] {
    ledger.history(topic: entry.record.topic).sorted(by: Self.newestFirst)
  }

  func reason(for entry: NotebookEntry) -> String? {
    reasons[entry.id]
  }

  private static func newestFirst(_ lhs: NotebookEntry, _ rhs: NotebookEntry) -> Bool {
    (lhs.clock, lhs.id.uuidString) > (rhs.clock, rhs.id.uuidString)
  }

  private func active(in topic: NotebookTopic) -> [NotebookEntry] {
    all(in: topic).filter { $0.status == .active }
  }

  private func all(in topic: NotebookTopic) -> [NotebookEntry] {
    ledger.entries.filter { entry in
      guard NotebookTopics.isVisibleInNotebook(entry.record.topic), case .known(let kind) = entry.record.entryKind else { return false }
      return topic.kinds.contains(kind)
    }
  }
}
