import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

extension LedgerEntryKind {
  var notebookTitle: LocalizedStringResource {
    switch self {
    case .decision, .system: LocalizedStringResource("Decision", table: "Notebook")
    case .direction: LocalizedStringResource("Direction", table: "Notebook")
    case .rejected: LocalizedStringResource("Turned down", table: "Notebook")
    case .backlog: LocalizedStringResource("Backlog", table: "Notebook")
    }
  }
}

extension LedgerEntryStatus {
  var notebookTitle: LocalizedStringResource {
    switch self {
    case .active: LocalizedStringResource("Active", table: "Notebook")
    case .superseded: LocalizedStringResource("Replaced", table: "Notebook")
    case .withdrawn: LocalizedStringResource("Withdrawn", table: "Notebook")
    }
  }

  var intent: ShadowIntent {
    switch self {
    case .active: .success
    case .superseded: .neutral
    case .withdrawn: .warning
    }
  }
}

struct NotebookBadge: View {
  let title: Text
  let intent: ShadowIntent

  var body: some View {
    title
      .shadowFont(.caption)
      .foregroundStyle(intent.foreground)
      .padding(.horizontal, Spacing.space2)
      .padding(.vertical, Spacing.space05)
      .background(intent == .neutral ? ShadowColor.surfaceWell : intent.background, in: Capsule())
      .overlay { if intent == .neutral { Capsule().strokeBorder(ShadowColor.borderDefault) } }
  }
}

struct NotebookEntryRow: View {
  let entry: NotebookEntry

  var body: some View {
    ShadowListRow(
      title: Text(verbatim: entry.record.statement), subtitle: entry.record.why.map { Text(verbatim: $0) }, caption: Text(verbatim: entry.record.topic),
      value: entry.status == .active ? nil : Text(entry.status.notebookTitle), accessory: .chevron
    )
  }
}
