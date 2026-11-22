import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

/// apps/novel-forge-web/src/features/chat/ChatComposer.tsx:86-176 as ChatColumn.tsx:1029-1053 wires it, without the queue and prompt chips.
struct ChatComposer: View {
  @Bindable var state: ChatComposerState
  @Binding var draft: String
  let sessionMode: ChatSessionMode
  let offer: ChatReplyOffer
  let isOpening: Bool
  let canSend: Bool
  let isSending: Bool
  let isLocked: Bool
  let isRunning: Bool
  /// Nil for the opening composer, whose chat is created with the mode.
  let saveMode: ((ChatSessionMode) async -> Bool)?
  let send: () -> Void
  var stop: (() -> Void)?
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      if !state.chips.isEmpty { ChatComposerPassages(state: state) }
      TextField(text: $draft, prompt: placeholder, axis: .vertical) {
        Text("Message", tableName: "ChatComposer")
      }
      .lineLimit(1...6)
      .shadowField()
      .disabled(isLocked || isSending)
      .focused($isFocused)
      .onSubmit(submit)
      .onChange(of: state.focusRequest) { isFocused = true }
      HStack(spacing: Spacing.space3) {
        ChatComposerModeMenu(value: state.mode(in: sessionMode)) { mode in
          Task { await state.choose(mode, current: sessionMode, save: saveMode) }
        }
        .disabled(!state.canChangeMode(isLocked: isLocked, isRunning: isRunning, isSending: isSending))
        ChatReplyOptionsMenu(options: $state.replyOptions, offer: offer)
          .disabled(isLocked)
        Toggle(isOn: $state.proseEdits) {
          Text("Edit prose", tableName: "ChatComposer")
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(isLocked)
        Spacer(minLength: Spacing.space2)
        action
      }
      if state.proseEdits {
        Text("Forge may rewrite the chapter text itself.", tableName: "ChatComposer").shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
      if let caption {
        caption.shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
      }
    }
    .padding(Spacing.space3)
    .background(ShadowColor.surfaceApp)
  }

  @ViewBuilder
  private var action: some View {
    if isRunning, let stop {
      Button(action: stop) {
        Label {
          Text("Stop", tableName: "ChatComposer")
        } icon: {
          Image(systemName: "stop.fill")
        }
      }
      .labelStyle(.iconOnly)
      .keyboardShortcut(".", modifiers: .command)
    } else {
      Button(action: submit) {
        Label {
          Text("Send", tableName: "ChatComposer")
        } icon: {
          Image(systemName: "arrow.up")
        }
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderedProminent)
      .keyboardShortcut(.return, modifiers: .command)
      .disabled(!canSend)
    }
  }

  /// ChatComposer.tsx:51-56, without the queue's wording: a message typed while a turn runs is not queued here.
  private var placeholder: Text {
    if !state.chips.isEmpty { return Text("Add a note for the whole revision…", tableName: "ChatComposer") }
    if state.justDiscussing { return Text("Think out loud — what if…", tableName: "ChatComposer") }
    return Text("Tell the chat what you want, or ask it anything…", tableName: "ChatComposer")
  }

  /// chat-queue.ts:111-116 and ChatColumn.tsx:786-790
  private var caption: Text? {
    let typed = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if typed && state.switching != nil { return Text("Saving the mode. Send again in a moment.", tableName: "ChatComposer") }
    if state.hasStaleChips { return Text("A passage you commented on changed — select it again, or remove its comment.", tableName: "ChatComposer") }
    if isOpening && !state.chips.isEmpty && !typed { return Text("Write a message to start the chat — your comments go with it.", tableName: "ChatComposer") }
    return nil
  }

  private func submit() {
    guard canSend else { return }
    send()
  }
}

/// apps/novel-forge-web/src/features/chat/ComposerModeMenu.tsx:15-37 over chat-view.ts:602-606
struct ChatComposerModeMenu: View {
  let value: ChatComposerMode
  let change: @MainActor (ChatComposerMode) -> Void

  var body: some View {
    Menu {
      Picker(selection: Binding(get: { value }, set: change)) {
        ForEach(ChatComposerMode.allCases, id: \.self) { mode in
          VStack(alignment: .leading) {
            mode.label
            mode.detail
          }
          .tag(mode)
        }
      } label: {
        Text("Mode", tableName: "ChatComposer")
      }
      .pickerStyle(.inline)
    } label: {
      value.label
    }
    .menuStyle(.button)
    .buttonStyle(.borderless)
    .fixedSize()
    .accessibilityLabel(Text("Mode", tableName: "ChatComposer"))
    .accessibilityValue(value.label)
  }
}

extension ChatComposerMode {
  var label: Text {
    switch self {
    case .editFreely: Text("Edit freely", tableName: "ChatComposer")
    case .askFirst: Text("Ask first", tableName: "ChatComposer")
    case .justDiscuss: Text("Just discuss", tableName: "ChatComposer")
    }
  }

  var detail: Text {
    switch self {
    case .editFreely: Text("Applies most Story Bible changes right away. Removals, plans, prose and secrets still ask. Undo any time.", tableName: "ChatComposer")
    case .askFirst: Text("Suggests every change. You approve each one.", tableName: "ChatComposer")
    case .justDiscuss: Text("Nothing changes until you approve it.", tableName: "ChatComposer")
    }
  }
}

/// apps/novel-forge-web/src/features/chat/ReplyOptionsMenu.tsx:13-47: hidden when the novel offers neither option. Before the owner has confirmed their age on
/// this device, turning Unrestricted on asks for that first.
struct ChatReplyOptionsMenu: View {
  @Binding var options: ChatReplyOptions
  let offer: ChatReplyOffer
  @Environment(AdultConfirmationModel.self) private var adult
  @State private var confirmingAge = false

  var body: some View {
    if !offer.isEmpty {
      Menu {
        if offer.thinkDeeper {
          Toggle(isOn: $options.thinkDeeper) {
            Text("Think deeper", tableName: "ChatComposer")
            Text("Takes longer and uses more of your allowance.", tableName: "ChatComposer")
          }
        }
        if offer.unrestricted != .hidden {
          Toggle(isOn: unrestricted) {
            Text("Unrestricted", tableName: "ChatComposer")
            Text("For dark or explicit material in this reply.", tableName: "ChatComposer")
          }
          .accessibilityHint(offer.unrestricted == .gated ? Text("Asks you to confirm your age first.", tableName: "ChatComposer") : Text(verbatim: ""))
        }
      } label: {
        label
      }
      .menuStyle(.button)
      .buttonStyle(.borderless)
      .fixedSize()
      .accessibilityLabel(Text("Reply options", tableName: "ChatComposer"))
      .accessibilityValue(isOn ? label : Text("none", tableName: "ChatComposer"))
      .sheet(isPresented: $confirmingAge) {
        AdultConfirmationSheet(adult: adult) { options.unrestricted = true }
      }
    }
  }

  private var unrestricted: Binding<Bool> {
    Binding {
      options.unrestricted && offer.unrestricted == .open
    } set: { on in
      guard on, offer.unrestricted == .gated else {
        options.unrestricted = on
        return
      }
      confirmingAge = true
    }
  }

  private var isOn: Bool { (options.thinkDeeper && offer.thinkDeeper) || (options.unrestricted && offer.unrestricted == .open) }

  /// chat-model.ts:58-61
  private var label: Text {
    switch (options.thinkDeeper && offer.thinkDeeper, options.unrestricted && offer.unrestricted == .open) {
    case (true, true): Text("Think deeper · Unrestricted", tableName: "ChatComposer")
    case (true, false): Text("Think deeper", tableName: "ChatComposer")
    case (false, true): Text("Unrestricted", tableName: "ChatComposer")
    case (false, false): Text("Reply options", tableName: "ChatComposer")
    }
  }
}

/// apps/novel-forge-web/src/features/chat/PassageChips.tsx:15-36: each comment with its chapter and quote; opening one shows its chapter in the Reader.
struct ChatComposerPassages: View {
  let state: ChatComposerState
  @Environment(NovelNavigator.self) private var navigator

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      ForEach(state.chips) { chip in
        HStack(alignment: .top, spacing: Spacing.space2) {
          Button {
            navigator.open(.reader, ReaderRoute.chapter(chip.passage.chapter))
          } label: {
            passage(chip)
          }
          .buttonStyle(.plain)
          .help(Text(verbatim: chip.passage.quote))
          Button {
            state.remove(chip.id)
          } label: {
            Label {
              Text("Remove the comment on chapter \(chip.passage.chapter)", tableName: "ChatComposer")
            } icon: {
              Image(systemName: "xmark")
            }
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
        }
        .padding(Spacing.space2)
        .background(ShadowColor.surfaceWell, in: RoundedRectangle(cornerRadius: Radius.md))
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Passage comments", tableName: "ChatComposer"))
  }

  private func passage(_ chip: ChatPassageChip) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space05) {
      ChatPassageReference(chapter: chip.passage.chapter, first: chip.firstParagraph, last: chip.lastParagraph)
      Text(verbatim: chip.passage.quote).shadowFont(.footnote).foregroundStyle(ShadowColor.textPrimary).lineLimit(2)
      if chip.isStale {
        Text("changed — select it again", tableName: "ChatComposer").shadowFont(.caption).foregroundStyle(ShadowColor.warningText)
      } else if !chip.passage.comment.isEmpty {
        Text(verbatim: chip.passage.comment).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary).lineLimit(2)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }
}

/// passage-comments.ts:53-56
struct ChatPassageReference: View {
  let chapter: Int
  let first: Int
  let last: Int

  var body: some View {
    reference.shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
  }

  private var reference: Text {
    first == last ? Text("Ch \(chapter) · ¶\(first)", tableName: "ChatComposer") : Text("Ch \(chapter) · ¶\(first)–\(last)", tableName: "ChatComposer")
  }
}
