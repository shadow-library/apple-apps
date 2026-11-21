import NovelForgeCore
import ShadowDesignSystem
import ShadowStore
import SwiftUI

/// The iPhone's home for everything waiting on the author in this novel (phase 8 decision 6), reached from the compact bar's Waiting on you, whose badge
/// counts these rows.
struct PendingView: View {
  let context: NovelContext
  let model: PendingModel
  @Environment(JobRuntimes.self) private var runtimes
  @Environment(ChatRuntimes.self) private var chatRuntimes
  @Environment(AIServices.self) private var services
  @State private var actions = PendingActions()

  var body: some View {
    let chats = chatRuntimes.runtime(for: context.store, services: services).model(for: context)
    let standing = runtimes.existing(for: context.store)?.standing ?? .starting
    content(model.list(replica: context.store.replica, standing: standing), chats: chats)
      .navigationTitle(Text("Waiting on you", tableName: "Pending"))
      .shadowScreen(.pushed)
      .pendingPresentations(actions, context: context)
  }

  @ViewBuilder
  private func content(_ list: PendingList, chats: ChatNovelModel) -> some View {
    switch model.state {
    case .loading:
      ProgressView().fillingSurface()
    case .failed(let error):
      ShadowContentUnavailable(Text("Waiting on you could not be read", tableName: "Pending"), kind: .error, message: error.text) {
        Button {
          model.retry()
        } label: {
          Text("Try Again", tableName: "Pending")
        }
      }
      .fillingSurface()
    case .loaded:
      if list.items.isEmpty {
        empty(isPartial: list.isPartial)
      } else {
        rows(list, chats: chats)
      }
    }
  }

  private func empty(isPartial: Bool) -> some View {
    ShadowContentUnavailable(
      Text("Nothing is waiting on you", tableName: "Pending"), systemImage: "tray",
      message: isPartial
        ? Text("Some of this novel isn't up to date on this device yet, so something may still be on its way.", tableName: "Pending")
        : Text("Cards to apply, drafts to review, Story Bible updates and jobs that need you show up here.", tableName: "Pending")
    )
    .fillingSurface()
  }

  private func rows(_ list: PendingList, chats: ChatNovelModel) -> some View {
    List {
      if list.isPartial {
        Text("Some of this novel isn't up to date on this device yet, so this list may be incomplete.", tableName: "Pending")
          .shadowFont(.footnote).foregroundStyle(ShadowColor.warningText)
      }
      if !list.chats.isEmpty {
        Section {
          ForEach(list.chats) { item in PendingRow(item: item, context: context, actions: actions, chats: chats) }
        } header: {
          Text("In chats", tableName: "Pending")
        }
      }
      if !list.chapters.isEmpty {
        Section {
          ForEach(list.chapters) { item in PendingRow(item: item, context: context, actions: actions, chats: chats) }
        } header: {
          Text("Chapters", tableName: "Pending")
        }
      }
    }
    .listStyle(.inset)
  }
}
