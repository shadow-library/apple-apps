import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

struct BibleNotFound: View {
  enum Subject {
    case page
    case entity
  }

  let subject: Subject
  let restore: (() -> Void)?

  var body: some View {
    ShadowContentUnavailable(title, systemImage: restore == nil ? "doc.questionmark" : "trash", message: message) {
      if let restore {
        Button(action: restore) { Text("Restore", tableName: "StoryBible") }
      }
    }
    .fillingSurface()
  }

  private var title: Text {
    switch (subject, restore == nil) {
    case (.page, true): Text("Page not found", tableName: "StoryBible")
    case (.entity, true): Text("Entry not found", tableName: "StoryBible")
    case (.page, false): Text("This page was removed", tableName: "StoryBible")
    case (.entity, false): Text("This entry was removed", tableName: "StoryBible")
    }
  }

  private var message: Text {
    switch (subject, restore == nil) {
    case (.page, true): Text("No page exists at this address.", tableName: "StoryBible")
    case (.entity, true): Text("No entry exists with this key.", tableName: "StoryBible")
    case (_, false): Text("Restore it to bring it back as it was.", tableName: "StoryBible")
    }
  }
}

struct BibleUnreadable: View {
  var body: some View {
    ShadowContentUnavailable(
      Text("This record cannot be read", tableName: "StoryBible"), systemImage: "lock",
      message: Text("It is stored in a form this version of Novel Forge does not understand.", tableName: "StoryBible")
    )
    .fillingSurface()
  }
}

struct BibleReadFailed: View {
  let error: PresentedError
  let retry: () -> Void

  var body: some View {
    ShadowContentUnavailable(Text("This could not be read", tableName: "StoryBible"), systemImage: "exclamationmark.triangle", message: error.text) {
      Button(action: retry) { Text("Try Again", tableName: "StoryBible") }
    }
    .fillingSurface()
  }
}
