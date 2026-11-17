import Foundation
import NovelForgeCore

nonisolated enum NotebookTopic: String, CaseIterable, Hashable, Identifiable {
  case decisions
  case directions
  case turnedDown
  case backlog
  case notes

  var id: Self { self }

  var kinds: [LedgerEntryKind] {
    switch self {
    case .decisions: [.decision, .system]
    case .directions: [.direction]
    case .turnedDown: [.rejected]
    case .backlog: [.backlog]
    case .notes: []
    }
  }

  var authorKind: LedgerEntryKind? {
    switch self {
    case .decisions, .notes: nil
    case .directions: .direction
    case .turnedDown: .rejected
    case .backlog: .backlog
    }
  }

  var systemImage: String {
    switch self {
    case .decisions: "checkmark.seal"
    case .directions: "arrow.triangle.turn.up.right.diamond"
    case .turnedDown: "hand.thumbsdown"
    case .backlog: "tray"
    case .notes: "note.text"
    }
  }

  var title: LocalizedStringResource {
    switch self {
    case .decisions: LocalizedStringResource("Decisions", table: "Notebook")
    case .directions: LocalizedStringResource("Directions", table: "Notebook")
    case .turnedDown: LocalizedStringResource("Turned-down ideas", table: "Notebook")
    case .backlog: LocalizedStringResource("Backlog", table: "Notebook")
    case .notes: LocalizedStringResource("Your notes", table: "Notebook")
    }
  }

  var summary: LocalizedStringResource {
    switch self {
    case .decisions: LocalizedStringResource("What has been settled, and what was passed over.", table: "Notebook")
    case .directions: LocalizedStringResource("Standing guidance for the story.", table: "Notebook")
    case .turnedDown: LocalizedStringResource("Ideas you said no to, so they are not offered again.", table: "Notebook")
    case .backlog: LocalizedStringResource("Not yet, but not forgotten.", table: "Notebook")
    case .notes: LocalizedStringResource("The notes you started this novel with.", table: "Notebook")
    }
  }
}

nonisolated enum NotebookRoute: Hashable {
  case topic(NotebookTopic)
  case entry(UUID)
}
