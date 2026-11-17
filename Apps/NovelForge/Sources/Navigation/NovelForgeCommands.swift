import SwiftUI

extension FocusedValues {
  @Entry var newNovel: (() -> Void)?
}

struct NovelForgeCommands: Commands {
  @FocusedValue(\.newNovel) private var newNovel

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button {
        newNovel?()
      } label: {
        Text("New Novel", tableName: "Library")
      }
      .keyboardShortcut("n")
      .disabled(newNovel == nil)
    }
  }
}
