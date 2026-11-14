import ShadowDesignSystem
import SwiftUI

struct TextEditorPage: View {
  @State private var note = "Thank you for reading this far. Chapter 44 lands on Friday, and the wiki unlocks once you reach it."
  @State private var empty = ""
  @State private var overLimit = String(repeating: "The stair was made of glass. ", count: 6)
  @State private var long = CatalogBook.prose + " " + CatalogBook.prose + " " + CatalogBook.prose

  private func counter(_ count: ShadowCharacterCount) -> Text {
    if count.isOverLimit { return Text("\(-(count.remaining ?? 0)) characters over the limit of \(count.limit ?? 0).") }
    return Text("Markdown. \(count.count) of \(count.limit ?? 0) characters.")
  }

  var body: some View {
    ComponentPage(component: .textEditor) {
      StateSection("Default and filled", note: "Grows with its content inside a form, so long text never scrolls inside a scrolling page. The count is live when there is a limit.")
      {
        FieldStack {
          FieldRow(title: "Author’s note") {
            ShadowTextEditor(text: $empty, placeholder: Text("Say something to your readers"), limit: 600, counter: counter)
          }
          FieldRow(title: "Author’s note") {
            ShadowTextEditor(text: $note, placeholder: Text("Say something to your readers"), limit: 600, counter: counter)
          }
        }
      }
      StateSection("Over the limit", note: "Typing is never blocked; the field turns to the error style and the count says by how much.") {
        FieldStack {
          FieldRow(title: "Author’s note") {
            ShadowTextEditor(text: $overLimit, placeholder: Text("Say something to your readers"), limit: 100, counter: counter)
          }
        }
      }
      StateSection("Disabled") {
        FieldStack {
          FieldRow(title: "Author’s note") {
            ShadowTextEditor(text: $note, placeholder: Text("Say something to your readers"), limit: 600, counter: counter)
              .disabled(true)
          }
        }
      }
      StateSection("Long text", note: "The editor keeps growing; the page scrolls instead.") {
        FieldStack {
          FieldRow(title: "Chapter prose") {
            ShadowTextEditor(text: $long, placeholder: Text("Start writing"), counter: counter)
          }
        }
      }
      StateSection(
        "Formatting",
        note:
          "These notes are plain text, so there is no formatting bar. Where the output keeps formatting, as in chapter prose, add one above the keyboard on iPhone and iPad, and on Mac in the toolbar or the Format menu with ⌘B, ⌘I and ⌘K."
      ) {
        EmptyView()
      }
    }
  }
}
