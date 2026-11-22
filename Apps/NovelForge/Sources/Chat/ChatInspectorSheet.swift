import NovelForgeCore
import ShadowAppShell
import ShadowDesignSystem
import ShadowStore
import SwiftUI

/// The last request a reply's turn sent, as the provider received it. Only the device that made the call keeps it, for its chat's 20 newest turns.
struct ChatInspectorSheet: View {
  let store: VaultStore
  let reply: UUID
  @State private var inspection: Loadable<ChatCallInspection?> = .loading
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    content
      .shadowSheetHeader(
        Text("Request", tableName: "Chat"), subtitle: Text("What this reply's turn last sent to the model.", tableName: "Chat"),
        cancel: ShadowSheetCancel(Text("Close", tableName: "Chat"), action: { dismiss() })
      )
      .shadowSheetStyle(.form)
      .task { await load() }
  }

  @ViewBuilder
  private var content: some View {
    switch inspection {
    case .loading:
      ProgressView().frame(maxWidth: .infinity, minHeight: 200)
    case .failed(let error):
      ShadowContentUnavailable(Text("The request could not be read", tableName: "Chat"), kind: .error, message: error.text)
        .frame(maxWidth: .infinity, minHeight: 200)
    case .loaded(nil):
      ShadowContentUnavailable(
        Text("No request kept on this device", tableName: "Chat"), systemImage: "doc.text.magnifyingglass",
        message: Text("Only the device that wrote a reply keeps its request, and only for the chat's latest turns.", tableName: "Chat")
      )
      .frame(maxWidth: .infinity, minHeight: 200)
    case .loaded(let inspection?):
      ChatInspection(inspection: inspection)
    }
  }

  private func load() async {
    do {
      inspection = .loaded(try await store.chatCallInspection(reply: reply))
    } catch {
      inspection = .failed(PresentedError(error))
    }
  }
}

private struct ChatInspection: View {
  let inspection: ChatCallInspection

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space4) {
        ShadowGroupedSection {
          VStack(alignment: .leading, spacing: Spacing.space2) {
            fact(Text("Model", tableName: "Chat"), inspection.model)
            if let effort = inspection.effort { fact(Text("Effort", tableName: "Chat"), effort) }
            fact(Text("Output limit", tableName: "Chat"), inspection.maxOutputTokens.formatted())
            fact(Text("Attempt", tableName: "Chat"), inspection.attempt.formatted())
            if inspection.isRepair { Text("A repair request, after an answer that could not be used.", tableName: "Chat").foregroundStyle(ShadowColor.warningText) }
            fact(Text("Sent", tableName: "Chat"), inspection.recordedAt.formatted(date: .abbreviated, time: .standard))
          }
          .padding(Spacing.space3)
        }
        ForEach(Array(inspection.system.enumerated()), id: \.offset) { index, segment in
          block(Text("System \(index + 1)", tableName: "Chat"), segment, cached: inspection.stablePrefixEnd == index)
        }
        ForEach(Array(inspection.messages.enumerated()), id: \.offset) { _, message in
          block(Text(verbatim: message.role.capitalized), message.text, cached: false)
        }
      }
      .padding(.bottom, Spacing.space1)
    }
  }

  private func fact(_ label: Text, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      label.foregroundStyle(ShadowColor.textSecondary)
      Spacer(minLength: Spacing.space3)
      Text(verbatim: value).textSelection(.enabled)
    }
    .shadowFont(.footnote)
  }

  private func block(_ title: Text, _ text: String, cached: Bool) -> some View {
    ShadowGroupedSection {
      Text(verbatim: text)
        .shadowFont(.monoBody)
        .foregroundStyle(ShadowColor.textPrimary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.space3)
    } header: {
      HStack(spacing: Spacing.space2) {
        title.shadowFont(.headline)
        if cached { ShadowBadge(Text("Cached up to here", tableName: "Chat"), intent: .info) }
      }
    }
  }
}
