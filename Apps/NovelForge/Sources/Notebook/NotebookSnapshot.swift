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
  private let history: NotebookLedgerHistory?

  static func load(novel: UUID, in transaction: ReadTransaction) throws -> NotebookSnapshot {
    NotebookSnapshot(history: try NotebookHistory.load(novel, in: transaction).notebook.value)
  }

  var isAvailable: Bool { history != nil }
  var unreadable: Int { ledger.unreadable }

  var ledger: NotebookLedger { history?.ledger ?? NotebookLedger(entries: []) }

  func lookup(_ id: UUID) -> NotebookLookup {
    guard let entry = history?.entry(id), NotebookTopics.isVisibleInNotebook(entry.record.topic) else { return .missing }
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
    history?.successor(of: entry)
  }

  func predecessor(of entry: NotebookEntry) -> NotebookEntry? {
    history?.predecessor(of: entry)
  }

  func history(of entry: NotebookEntry) -> [NotebookEntry] {
    ledger.history(topic: entry.record.topic).sorted(by: Self.newestFirst)
  }

  func reason(for entry: NotebookEntry) -> String? {
    history?.reason(for: entry)
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
