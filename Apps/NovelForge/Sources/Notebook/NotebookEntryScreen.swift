import Foundation
import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

struct NotebookEntryScreen: View {
  let model: NotebookModel
  let entry: UUID

  var body: some View {
    NotebookLoaded(model: model) { snapshot in
      switch snapshot.lookup(entry) {
      case .missing: NotebookNotFound()
      case .found(let found): details(found, snapshot)
      }
    }
    .navigationTitle(Text("Entry", tableName: "Notebook"))
    .toolbar { toolbar }
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    if case .loaded(let snapshot) = model.state, case .found(let found) = snapshot.lookup(entry), found.status == .active {
      ToolbarItemGroup {
        Button {
          model.present(.rewrite(found))
        } label: {
          Label(title: { Text("Rewrite…", tableName: "Notebook") }, icon: { Image(systemName: "pencil") })
        }
        .disabled(found.record.entryKind.known == nil)
        Button {
          model.present(.withdraw(found))
        } label: {
          Label(title: { Text("Withdraw…", tableName: "Notebook") }, icon: { Image(systemName: "arrow.uturn.backward") })
        }
      }
    }
  }

  private func details(_ found: NotebookEntry, _ snapshot: NotebookSnapshot) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space6) {
        header(found)
        status(found, snapshot)
        body(of: found)
        history(of: found, snapshot)
      }
      .padding(Spacing.space6)
      .frame(maxWidth: 760, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
    }
    .shadowScreen(.root)
  }

  private func header(_ found: NotebookEntry) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      HStack(spacing: Spacing.space2) {
        if let kind = found.record.entryKind.known {
          ShadowBadge(Text(kind.notebookTitle), intent: .info)
        } else {
          ShadowBadge(Text("Unknown kind", tableName: "Notebook"), intent: .warning)
        }
        ShadowBadge(Text(found.status.notebookTitle), intent: found.status.intent)
      }
      Text(verbatim: found.record.statement).shadowFont(.title3).foregroundStyle(ShadowColor.textPrimary).textSelection(.enabled)
      Text(verbatim: found.record.topic).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
    }
  }

  @ViewBuilder
  private func status(_ found: NotebookEntry, _ snapshot: NotebookSnapshot) -> some View {
    if found.status == .withdrawn {
      ShadowCallout(Text("This entry was withdrawn", tableName: "Notebook"), message: snapshot.reason(for: found).map { Text(verbatim: $0) }, intent: .warning)
    }
    if let next = snapshot.successor(of: found) {
      VStack(alignment: .leading, spacing: Spacing.space2) {
        if found.status == .superseded {
          ShadowCallout(Text("This entry was replaced by a newer one", tableName: "Notebook"), intent: .info)
        }
        link(Text("Replaced by", tableName: "Notebook"), next)
      }
    }
    if let previous = snapshot.predecessor(of: found) { link(Text("Replaces", tableName: "Notebook"), previous) }
  }

  private func link(_ label: Text, _ target: NotebookEntry) -> some View {
    NavigationLink(value: NotebookRoute.entry(target.id)) {
      HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
        label.shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
        Text(verbatim: target.record.statement).shadowFont(.subheadline).foregroundStyle(ShadowColor.accentText).lineLimit(2)
      }
    }
    .buttonStyle(.plain)
  }

  private func body(of found: NotebookEntry) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space4) {
      if let why = found.record.why { field(Text("Why", tableName: "Notebook"), why) }
      if let line = found.record.writerLine { field(Text("For the writer", tableName: "Notebook"), line) }
      if !found.record.rejectedAlternatives.isEmpty {
        VStack(alignment: .leading, spacing: Spacing.space1) {
          fieldLabel(Text("Passed over", tableName: "Notebook"))
          ForEach(found.record.rejectedAlternatives, id: \.self) { alternative in
            Text(verbatim: "• \(alternative)").shadowFont(.body).foregroundStyle(ShadowColor.textPrimary).textSelection(.enabled)
          }
        }
      }
      if found.record.decidedBy == .known(.system) { fieldLabel(Text("Decided by Novel Forge", tableName: "Notebook")) }
    }
  }

  @ViewBuilder
  private func history(of found: NotebookEntry, _ snapshot: NotebookSnapshot) -> some View {
    let all = snapshot.history(of: found)
    if all.count > 1 {
      VStack(alignment: .leading, spacing: Spacing.space2) {
        Text("History of this topic", tableName: "Notebook").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary).accessibilityAddTraits(.isHeader)
        ForEach(all, id: \.id) { item in
          if item.id == found.id {
            historyRow(item, current: true)
          } else {
            NavigationLink(value: NotebookRoute.entry(item.id)) { historyRow(item, current: false) }.buttonStyle(.plain)
          }
        }
      }
    }
  }

  private func historyRow(_ item: NotebookEntry, current: Bool) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
      ShadowBadge(Text(item.status.notebookTitle), intent: item.status.intent)
      Text(verbatim: item.record.statement).shadowFont(.subheadline).foregroundStyle(current ? ShadowColor.textPrimary : ShadowColor.textSecondary).lineLimit(2)
    }
  }

  private func field(_ label: Text, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      fieldLabel(label)
      Text(verbatim: value).shadowFont(.body).foregroundStyle(ShadowColor.textPrimary).textSelection(.enabled)
    }
  }

  private func fieldLabel(_ text: Text) -> some View {
    text.shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
  }
}
