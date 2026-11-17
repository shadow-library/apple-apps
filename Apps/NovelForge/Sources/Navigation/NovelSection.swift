import Foundation

enum NovelSection: String, CaseIterable, Hashable, Identifiable {
  case overview
  case reader
  case story
  case storyBible
  case notebook
  case chat

  var id: Self { self }

  var title: LocalizedStringResource {
    switch self {
    case .overview: LocalizedStringResource("Overview", table: "Navigation")
    case .reader: LocalizedStringResource("Reader", table: "Navigation")
    case .story: LocalizedStringResource("Story", table: "Navigation")
    case .storyBible: LocalizedStringResource("Story Bible", table: "Navigation")
    case .notebook: LocalizedStringResource("Notebook", table: "Navigation")
    case .chat: LocalizedStringResource("Chat", table: "Navigation")
    }
  }

  var systemImage: String {
    switch self {
    case .overview: "square.grid.2x2"
    case .reader: "book"
    case .story: "list.bullet.rectangle"
    case .storyBible: "books.vertical"
    case .notebook: "note.text"
    case .chat: "bubble.left.and.text.bubble.right"
    }
  }
}
