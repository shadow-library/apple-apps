import NovelForgeCore
import ShadowDesignSystem
import ShadowStore
import SwiftUI

/// apps/novel-forge-web/src/features/chat/ChapterReader.tsx:286-366, over the draft's source text: a selection in the rendered prose cannot be read back.
struct ChatPassageCommentSheet: View {
  let context: NovelContext
  let chapter: Int
  @Environment(ChatRuntimes.self) private var runtimes
  @Environment(AIServices.self) private var services
  @Environment(NovelNavigator.self) private var navigator
  @Environment(\.dismiss) private var dismiss
  @State private var observer = ReadObserver<ChatPassageSource?>()
  @State private var generation = 0
  @State private var range = NSRange(location: 0, length: 0)
  @State private var comment = ""
  @State private var isFull = false
  @State private var dismissGuard = ShadowDismissGuard()

  var body: some View {
    content
      .shadowSheetHeader(
        Text("Comment on a Passage", tableName: "ChatComposer"), subtitle: Text("Chapter \(chapter)", tableName: "ChatComposer"),
        cancel: ShadowSheetCancel(Text("Cancel", tableName: "ChatComposer"), action: requestDismiss),
        confirm: ShadowSheetConfirm(Text("Add to Chat", tableName: "ChatComposer"), isDisabled: !canAdd, submitShortcut: true) { Task { await add() } }
      )
      .shadowSheetStyle(.form)
      .shadowDismissGuard(
        $dismissGuard, title: Text("Discard your comment?", tableName: "ChatComposer"), discardTitle: Text("Discard", tableName: "ChatComposer"),
        keepEditingTitle: Text("Keep Editing", tableName: "ChatComposer"), onDiscard: { dismiss() }
      )
      .onChange(of: comment, initial: true) { dismissGuard.hasUnsavedChanges = !comment.allSatisfy(\.isWhitespace) }
      .task(id: generation) {
        let (store, novel, chapter) = (context.store, context.novel, chapter)
        await observer.run { store.observeReads { transaction in try ChatPassageSource.load(novel: novel, chapter: chapter, in: transaction) } }
      }
  }

  @ViewBuilder
  private var content: some View {
    switch observer.state {
    case .loading:
      ProgressView().frame(maxWidth: .infinity, minHeight: 240)
    case .failed(let error):
      ShadowContentUnavailable(Text("This chapter could not be read", tableName: "ChatComposer"), kind: .error, message: error.text) {
        Button {
          generation += 1
        } label: {
          Text("Try Again", tableName: "ChatComposer")
        }
      }
    case .loaded(nil):
      ShadowContentUnavailable(
        Text("No draft to comment on", tableName: "ChatComposer"), systemImage: "text.bubble",
        message: Text("Only a chapter’s draft can be commented on in the chat.", tableName: "ChatComposer"))
    case .loaded(let source?) where source.isolated:
      // passage-comments.ts:71-73
      ShadowContentUnavailable(
        Text("This chapter is isolated", tableName: "ChatComposer"), systemImage: "lock",
        message: Text("Its text never goes to the chat, so it can’t be commented on there.", tableName: "ChatComposer"))
    case .loaded(let source?):
      form(source)
    }
  }

  private func form(_ source: ChatPassageSource) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space4) {
      ChatPassageText(text: source.body, selection: $range)
        .frame(minHeight: 200, maxHeight: 360)
        .background(ShadowColor.surfaceWell, in: RoundedRectangle(cornerRadius: Radius.md))
      selected(source.select(range))
      VStack(alignment: .leading, spacing: Spacing.space2) {
        Text("What should change here?", tableName: "ChatComposer").shadowFont(.subheadline).foregroundStyle(ShadowColor.textPrimary)
        ShadowTextEditor(text: $comment, placeholder: Text("Optional", tableName: "ChatComposer"), limit: ChatPassageChip.commentLimit, minHeight: 56, maxHeight: 140) {
          count in Text("\(count.count.formatted()) of \(ChatPassageChip.commentLimit.formatted())", tableName: "ChatComposer")
        }
        ShadowFlowLayout {
          ForEach(Self.quickComments, id: \.self) { quick in
            ShadowTag(Text(verbatim: quick)) { comment = Self.withQuickComment(comment, quick) }
          }
        }
      }
      if isFull {
        ShadowValidationMessage(Text("A message carries at most \(ChatPassageChip.limit) comments — send these first.", tableName: "ChatComposer"))
      }
    }
  }

  @ViewBuilder
  private func selected(_ selection: Result<ChatPassageSelection, ChatPassageRefusal>) -> some View {
    switch selection {
    case .success(let selection):
      VStack(alignment: .leading, spacing: Spacing.space1) {
        ChatPassageReference(chapter: chapter, first: selection.firstParagraph, last: selection.lastParagraph)
        Text(verbatim: selection.quote).shadowFont(.footnote).foregroundStyle(ShadowColor.textPrimary).lineLimit(3)
      }
    case .failure(.empty):
      Text("Select the words you want to comment on.", tableName: "ChatComposer").shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
    case .failure(.tooLong):
      // passage-comments.ts:42-43
      ShadowValidationMessage(Text("Select at most \(ChatPassageSource.maxQuoteLength.formatted()) characters to comment on.", tableName: "ChatComposer"))
    case .failure(.unmapped):
      ShadowValidationMessage(Text("The reader can’t place that selection in the chapter’s text — select a little less.", tableName: "ChatComposer"))
    }
  }

  private var selection: ChatPassageSelection? {
    guard case .loaded(let source?) = observer.state, !source.isolated, case .success(let selection) = source.select(range) else { return nil }
    return selection
  }

  /// chat.dto.ts:262 counts the comment in code points, as the engine checks it.
  private var canAdd: Bool { selection != nil && comment.unicodeScalars.count <= ChatPassageChip.commentLimit }

  private func add() async {
    guard canAdd, case .loaded(let source?) = observer.state, let selection else { return }
    let chats = runtimes.runtime(for: context.store, services: services).model(for: context)
    guard await chats.addPassage(ChatPassageChip(source, selection, comment: comment)) != .full else {
      isFull = true
      return
    }
    dismissGuard.hasUnsavedChanges = false
    dismiss()
    navigator.show(.chat)
  }

  private func requestDismiss() {
    if dismissGuard.requestDismiss() { dismiss() }
  }

  /// passage-comments.ts:15
  static var quickComments: [String] {
    [
      String(localized: "Tighten", table: "ChatComposer"), String(localized: "Show, don’t tell", table: "ChatComposer"), String(localized: "Cut", table: "ChatComposer"),
      String(localized: "Match the voice", table: "ChatComposer"),
    ]
  }

  /// passage-comments.ts:163-167
  static func withQuickComment(_ current: String, _ quick: String) -> String {
    let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let last = text.last else { return quick }
    return ".!?;:,".contains(last) ? "\(text) \(quick)" : "\(text). \(quick)"
  }
}
