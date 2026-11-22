import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

struct ChapterEditorView: View {
  @Bindable var editor: ChapterEditorModel
  let onLeave: () -> Void
  @State private var replaced: ChapterText?
  @State private var confirmingLeave = false

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space4) {
      banner
      TextField(text: $editor.draftTitle, prompt: Text("Untitled chapter", tableName: "Reader")) { Text("Chapter title", tableName: "Reader") }
        .shadowField()
        .disabled(!editor.isEditable)
      ShadowTextEditor(text: $editor.draftBody, placeholder: Text("Write the chapter here.", tableName: "Reader"), minHeight: 360) { _ in Text(verbatim: "") }
        .disabled(!editor.isEditable)
      footer
    }
    .onChange(of: editor.text) { editor.textChanged() }
    .confirmationDialog(Text("Leave the editor?", tableName: "Reader"), isPresented: $confirmingLeave, titleVisibility: .visible) {
      Button(role: .destructive) {
        onLeave()
      } label: {
        Text("Leave", tableName: "Reader")
      }
      Button(role: .cancel) {
      } label: {
        Text("Stay", tableName: "Reader")
      }
    } message: {
      Text(verbatim: editor.status.leaveWarning)
    }
  }

  @ViewBuilder
  private var banner: some View {
    switch editor.status {
    case .conflict:
      ShadowCallout(
        Text("A newer version of this chapter arrived", tableName: "Reader"),
        message: Text("Your edits are waiting. Saving would replace a version you have not read.", tableName: "Reader"), intent: .warning
      ) {
        HStack {
          Button {
            editor.keepMine()
          } label: {
            Text("Keep My Text", tableName: "Reader")
          }
          .disabled(editor.theirs == nil)
          Button {
            replaced = editor.takeTheirs()
          } label: {
            Text("Use the Newer Version", tableName: "Reader")
          }
          .disabled(editor.theirs == nil)
          copyButton
          leaveButton
        }
      }
    case .locked:
      ShadowCallout(
        Text("This chapter was finalized", tableName: "Reader"), message: Text("Your edits cannot be saved here. Copy them before you leave.", tableName: "Reader"),
        intent: .warning
      ) {
        HStack {
          copyButton
          leaveButton
        }
      }
    case .deleted:
      ShadowCallout(
        Text("This chapter's draft was removed", tableName: "Reader"), message: Text("Your edits cannot be saved here. Copy them before you leave.", tableName: "Reader"),
        intent: .warning
      ) {
        HStack {
          copyButton
          leaveButton
        }
      }
    case .failed(let error):
      ShadowCallout(Text("Your changes were not saved", tableName: "Reader"), message: error.text, intent: .danger) {
        Button {
          editor.retry()
          Task { await editor.save() }
        } label: {
          Text("Try Again", tableName: "Reader")
        }
      }
    case .idle, .saving:
      if let replacedText = replaced {
        ShadowCallout(Text("Your edits were replaced with the newer version", tableName: "Reader"), intent: .info) {
          Button {
            editor.restore(replacedText)
            replaced = nil
          } label: {
            Text("Undo", tableName: "Reader")
          }
        }
      }
    }
  }

  private var leaveButton: some View {
    Button {
      confirmingLeave = true
    } label: {
      Text("Leave Editor", tableName: "Reader")
    }
  }

  private var copyButton: some View {
    Button {
      Clipboard.copy(editor.text.title.isEmpty ? editor.text.body : "\(editor.text.title)\n\n\(editor.text.body)")
    } label: {
      Text("Copy My Text", tableName: "Reader")
    }
  }

  private var footer: some View {
    let words = editor.words
    return HStack(spacing: Spacing.space3) {
      saveState
      Spacer()
      Text("\(words) words", tableName: "Reader")
    }
    .shadowFont(.footnote)
    .foregroundStyle(ShadowColor.textSecondary)
    .monospacedDigit()
  }

  @ViewBuilder
  private var saveState: some View {
    switch editor.status {
    case .saving: Text("Saving…", tableName: "Reader")
    case .idle where editor.isDirty: Text("Unsaved changes", tableName: "Reader")
    case .idle: Text("Saved", tableName: "Reader")
    case .conflict, .failed, .locked, .deleted: Text("Not saved", tableName: "Reader")
    }
  }
}

extension ChapterEditorModel {
  var draftTitle: String {
    get { text.title }
    set { text.title = newValue }
  }

  var draftBody: String {
    get { text.body }
    set { text.body = newValue }
  }
}

enum WordCount {
  static func words(in text: String) -> Int {
    text.split(whereSeparator: \.isWhitespace).count
  }
}
