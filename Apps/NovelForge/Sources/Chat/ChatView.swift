import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

struct ChatView: View {
  let context: NovelContext
  @Environment(ChatRuntimes.self) private var runtimes
  @Environment(AIServices.self) private var services

  var body: some View {
    ChatHome(model: runtimes.runtime(for: context.store, services: services).model(for: context))
  }
}

struct ChatHome: View {
  @Bindable var model: ChatNovelModel

  var body: some View {
    content
      .navigationTitle(Text(verbatim: model.current.map(model.title(of:)) ?? String(localized: "New chat", table: "Chat")))
      .toolbar { ChatToolbar(model: model, session: model.current) }
      .sheet(item: $model.presenting) { sheet in
        switch sheet {
        case .history: ChatHistorySheet(model: model)
        case .inspect(let reply): ChatInspectorSheet(store: model.context.store, reply: reply)
        }
      }
      .chatSessionDialogs(model, isActive: model.presenting == nil)
      .task(id: model.generation) { await model.observe() }
  }

  @ViewBuilder
  private var content: some View {
    switch model.state {
    case .loading:
      ProgressView().fillingSurface()
    case .failed(let error):
      ShadowContentUnavailable(Text("Your chats could not be read", tableName: "Chat"), kind: .error, message: error.text) {
        Button {
          model.retry()
        } label: {
          Text("Try Again", tableName: "Chat")
        }
      }
      .fillingSurface()
    case .loaded(let snapshot):
      if snapshot.all.sessions.isUnavailable {
        ChatUnavailable()
      } else if let current = model.current {
        ChatSessionScreen(model: model.session(current), chats: model).id(current)
      } else {
        ChatStartScreen(model: model)
      }
    }
  }
}

struct ChatUnavailable: View {
  var body: some View {
    ShadowContentUnavailable(
      Text("Chats are unavailable", tableName: "Chat"), kind: .error,
      message: Text("They are not up to date on this device yet. Try again after syncing.", tableName: "Chat")
    )
    .fillingSurface()
  }
}

private struct ChatToolbar: ToolbarContent {
  let model: ChatNovelModel
  let session: UUID?

  var body: some ToolbarContent {
    ToolbarItemGroup {
      if let session { ChatSessionMenu(model: model, session: session) }
      Button {
        model.presenting = .history
      } label: {
        Label {
          Text("History", tableName: "Chat")
        } icon: {
          Image(systemName: "clock")
        }
      }
      Button {
        model.newChat()
      } label: {
        Label {
          Text("New Chat", tableName: "Chat")
        } icon: {
          Image(systemName: "square.and.pencil")
        }
      }
      AISettingsButton(store: model.context.store)
    }
  }
}

private struct ChatSessionMenu: View {
  let model: ChatNovelModel
  let session: UUID

  var body: some View {
    Menu {
      ChatSessionActions(model: model, session: session)
    } label: {
      Label {
        Text("Chat Actions", tableName: "Chat")
      } icon: {
        Image(systemName: "ellipsis.circle")
      }
    }
  }
}

/// Rename, archive or unarchive, and delete (apps/novel-forge-web/src/routes/novels/$novelId/chat.tsx:310-320).
struct ChatSessionActions: View {
  let model: ChatNovelModel
  let session: UUID

  var body: some View {
    Button {
      model.beginRename(session)
    } label: {
      Label {
        Text("Rename Chat…", tableName: "Chat")
      } icon: {
        Image(systemName: "pencil")
      }
    }
    .disabled(model.overview(of: session)?.record == nil)
    Button {
      Task { await model.setArchived(session, !model.isArchived(session)) }
    } label: {
      if model.isArchived(session) {
        Label {
          Text("Unarchive Chat", tableName: "Chat")
        } icon: {
          Image(systemName: "tray.and.arrow.up")
        }
      } else {
        Label {
          Text("Archive Chat", tableName: "Chat")
        } icon: {
          Image(systemName: "archivebox")
        }
      }
    }
    .disabled(model.overview(of: session)?.record == nil)
    Divider()
    Button(role: .destructive) {
      model.deleting = session
    } label: {
      Label {
        Text("Delete Chat…", tableName: "Chat")
      } icon: {
        Image(systemName: "trash")
      }
    }
  }
}

extension View {
  func chatSessionDialogs(_ model: ChatNovelModel, isActive: Bool) -> some View {
    modifier(ChatSessionDialogs(model: model, isActive: isActive))
  }
}

private struct ChatSessionDialogs: ViewModifier {
  @Bindable var model: ChatNovelModel
  let isActive: Bool

  func body(content: Content) -> some View {
    content
      .alert(Text("Rename Chat", tableName: "Chat"), isPresented: presented(\.renaming)) {
        TextField(text: $model.renameText, prompt: Text("Chat title", tableName: "Chat")) { Text("Chat title", tableName: "Chat") }
        Button {
          Task { await model.commitRename() }
        } label: {
          Text("Rename", tableName: "Chat")
        }
        Button(role: .cancel) {
          model.renaming = nil
        } label: {
          Text("Cancel", tableName: "Chat")
        }
      } message: {
        Text("Leave it empty to use the name Novel Forge gave it.", tableName: "Chat")
      }
      .confirmationDialog(deleteTitle, isPresented: presented(\.deleting), titleVisibility: .visible) {
        Button(role: .destructive) {
          Task { await model.confirmDelete() }
        } label: {
          Text("Delete Chat", tableName: "Chat")
        }
      } message: {
        Text("The conversation and its full history are removed on every device. Changes it already made or suggested are kept.", tableName: "Chat")
      }
      .alert(Text("Something went wrong", tableName: "Chat"), isPresented: Binding(get: { isActive && model.failure != nil }, set: { if !$0 { model.failure = nil } })) {
        Button {
          model.failure = nil
        } label: {
          Text("OK", tableName: "Chat")
        }
      } message: {
        if let failure = model.failure { failure.error.text }
      }
  }

  private var deleteTitle: Text {
    let title = model.deleting.map(model.title(of:)) ?? ""
    return Text("Delete “\(title)”?", tableName: "Chat")
  }

  private func presented(_ key: ReferenceWritableKeyPath<ChatNovelModel, UUID?>) -> Binding<Bool> {
    Binding(get: { isActive && model[keyPath: key] != nil }, set: { if !$0 { model[keyPath: key] = nil } })
  }
}

/// The centred state before a chat exists (apps/novel-forge-web/src/features/chat/ChatColumn.tsx:1022-1027): its first message creates the chat.
struct ChatStartScreen: View {
  @Bindable var model: ChatNovelModel

  var body: some View {
    ChatHero(novelTitle: model.novelTitle, mode: model.composer.draftMode)
      .fillingSurface()
      .safeAreaInset(edge: .bottom, spacing: 0) {
        ChatComposer(
          state: model.composer, draft: $model.draft, sessionMode: model.composer.draftMode, offer: model.replyOffer, isOpening: true, canSend: model.canStartDraft,
          isSending: model.isStarting, isLocked: false, isRunning: false, saveMode: nil
        ) {
          Task { await model.startDraft() }
        }
      }
  }
}

/// apps/novel-forge-web/src/features/chat/chat-view.ts:635-638
struct ChatHero: View {
  let novelTitle: String?
  let mode: ChatSessionMode

  var body: some View {
    VStack(spacing: Spacing.space3) {
      Text("What are we working on?", tableName: "Chat").shadowFont(.title2).foregroundStyle(ShadowColor.textPrimary)
      Text(verbatim: text).shadowFont(.body).foregroundStyle(ShadowColor.textSecondary).multilineTextAlignment(.center)
    }
    .frame(maxWidth: 520)
    .padding(Spacing.space5)
  }

  private var text: String {
    let name = novelTitle ?? String(localized: "this novel", table: "Chat")
    switch mode {
    case .manual: return String(localized: "Forge reads every part of “\(name)”. This chat is manual: every change waits for your yes.", table: "Chat")
    case .auto:
      return String(
        localized: "Forge reads every part of “\(name)”. Clear instructions in your own words apply at once and can be undone; its own ideas wait for your yes.",
        table: "Chat")
    }
  }
}
