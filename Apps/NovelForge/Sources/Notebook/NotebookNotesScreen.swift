import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

struct NotebookNotesScreen: View {
  let notes: NotebookNotes

  var body: some View {
    content
      .task { await notes.load() }
      .onDisappear { notes.flush() }
  }

  @ViewBuilder
  private var content: some View {
    switch notes.phase {
    case .idle, .loading:
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let error):
      ShadowContentUnavailable(Text("Your notes could not be read", tableName: "Notebook"), kind: .error, message: error.text) {
        Button {
          Task { await notes.load() }
        } label: {
          Text("Try Again", tableName: "Notebook")
        }
      }
      .fillingSurface()
    case .loaded:
      editor
    }
  }

  private var editor: some View {
    @Bindable var notes = notes
    return ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        Text("Anything you wrote when you started. Nothing here is changed on its own; it stays as your source.", tableName: "Notebook")
          .shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
        ShadowTextEditor(text: $notes.text, placeholder: Text("Characters, the world, the first scene, the ending, books you love.", tableName: "Notebook"), minHeight: 240) {
          _ in Text(verbatim: "")
        }
        .disabled(notes.isSaving)
        footer
        if let failure = notes.saveFailure { ShadowValidationMessage(failure.text) }
        HStack(spacing: Spacing.space2) {
          Spacer()
          Button {
            notes.revert()
          } label: {
            Text("Revert", tableName: "Notebook")
          }
          .disabled(!notes.hasChanges || notes.isSaving)
          Button {
            Task { await notes.save() }
          } label: {
            Text("Save Notes", tableName: "Notebook")
          }
          .keyboardShortcut("s", modifiers: .command)
          .disabled(!notes.canSave)
        }
      }
      .padding(Spacing.space6)
      .frame(maxWidth: 760, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
    }
    .shadowScreen(.root)
  }

  @ViewBuilder
  private var footer: some View {
    if notes.wordsOver > 0 {
      Text("\(notes.words) words, \(notes.wordsOver) over the limit", tableName: "Notebook").shadowFont(.footnote).foregroundStyle(ShadowColor.destructiveLabel)
    } else {
      Text("\(notes.words) of \(LibraryLimits.notesWords) words", tableName: "Notebook").shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary).monospacedDigit()
    }
  }
}
