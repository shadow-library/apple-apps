import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

struct PageVersionsSheet: View {
  let model: StoryBibleModel
  let address: PageAddress
  let title: String
  let versions: [PageVersion]
  @State private var confirming: PageVersion?
  @State private var isRestoring = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    List(versions, id: \.revision) { version in row(version) }
      .shadowSheetHeader(
        Text("Versions", tableName: "StoryBible"), subtitle: Text(verbatim: title),
        cancel: ShadowSheetCancel(Text("Done", tableName: "StoryBible"), systemImage: "checkmark") { dismiss() }
      )
      .shadowSheetStyle(.form)
      .overlay {
        if versions.isEmpty {
          ShadowContentUnavailable(Text("No versions", tableName: "StoryBible"), systemImage: "clock.arrow.circlepath")
        }
      }
      .confirmationDialog(
        Text("Restore this version?", tableName: "StoryBible"), isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible,
        presenting: confirming
      ) { version in
        Button {
          Task { await restore(version) }
        } label: {
          Text("Restore", tableName: "StoryBible")
        }
      } message: { _ in
        Text("It becomes the newest version. Nothing is lost from the history.", tableName: "StoryBible")
      }
  }

  private func row(_ version: PageVersion) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      HStack(spacing: Spacing.space2) {
        Text(version.date, format: .dateTime.day().month().year().hour().minute()).shadowFont(.body).foregroundStyle(ShadowColor.textPrimary)
        if version.isHead { ShadowBadge(Text("Current", tableName: "StoryBible")) }
        Spacer(minLength: Spacing.space3)
        if !version.isHead {
          Button {
            confirming = version
          } label: {
            Text("Restore…", tableName: "StoryBible")
          }
          .disabled(version.content == nil || isRestoring)
        }
      }
      preview(version)
    }
    .padding(.vertical, Spacing.space1)
  }

  @ViewBuilder
  private func preview(_ version: PageVersion) -> some View {
    if let content = version.content {
      let text = (content.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      Text(verbatim: text.isEmpty ? "—" : String(text.prefix(280))).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary).lineLimit(4)
    } else {
      Label(title: { Text("Stored in a form this version cannot read", tableName: "StoryBible") }, icon: { Image(systemName: "exclamationmark.triangle") })
        .shadowFont(.footnote)
        .foregroundStyle(ShadowColor.warningText)
    }
  }

  private func restore(_ version: PageVersion) async {
    isRestoring = true
    defer { isRestoring = false }
    if await model.restoreVersion(address, revision: version.revision) { dismiss() }
  }
}
