import ShadowDesignSystem
import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

enum DemoPlatform {
  static var opensDetail: Bool {
    #if os(macOS)
      true
    #elseif os(iOS)
      UIDevice.current.userInterfaceIdiom == .pad
    #else
      true
    #endif
  }

  static var hasPointer: Bool { opensDetail }
}

enum DemoChapterStatus: String, CaseIterable, Hashable {
  case draft = "Draft"
  case review = "In review"
  case canon = "Canon"

  var intent: ShadowBadgeIntent {
    switch self {
    case .draft: .neutral
    case .review: .warning
    case .canon: .success
    }
  }

  var systemImage: String {
    switch self {
    case .draft: "pencil"
    case .review: "eye"
    case .canon: "checkmark"
    }
  }
}

struct DemoChapter: Identifiable, Hashable {
  let id: Int
  let title: String
  let words: Int
  let status: DemoChapterStatus
  let draftedBy: String
  let unlocks: String?

  var heading: String { "Chapter \(id)" }
  var wordCount: String { words.formatted(.number.grouping(.automatic)) }

  private static let earlierTitles: [String] = [
    "The first lantern", "Salt in the ink", "A choir of one", "The court convenes", "Ash on the sill", "What Mira kept",
    "The stair, from below", "A borrowed name", "The moth season", "Ledgers and lies", "The lantern bearer", "Before the climb",
  ]

  private static let earlier: [DemoChapter] = earlierTitles.enumerated().map { index, title in
    DemoChapter(id: 23 + index, title: title, words: 2_400 + index * 85, status: .canon, draftedBy: "Mira Vale", unlocks: nil)
  }

  static let all: [DemoChapter] =
    earlier + [
      DemoChapter(id: 35, title: "The lantern below", words: 2_870, status: .canon, draftedBy: "Mira Vale", unlocks: nil),
      DemoChapter(id: 36, title: "Names on the stair", words: 3_105, status: .canon, draftedBy: "Mira Vale", unlocks: "Secret: The first climb"),
      DemoChapter(id: 37, title: "A ledger of ash", words: 2_640, status: .canon, draftedBy: "AI · reviewed", unlocks: nil),
      DemoChapter(id: 38, title: "The salt road", words: 3_420, status: .canon, draftedBy: "Mira Vale", unlocks: nil),
      DemoChapter(id: 39, title: "What the moth choir sang", words: 2_990, status: .canon, draftedBy: "Mira Vale", unlocks: "Quest: Count the moths"),
      DemoChapter(id: 40, title: "Still warm", words: 2_120, status: .canon, draftedBy: "Mira Vale", unlocks: nil),
      DemoChapter(id: 41, title: "Lanterns out", words: 2_560, status: .canon, draftedBy: "AI · reviewed", unlocks: nil),
      DemoChapter(id: 42, title: "The glass stair", words: 3_214, status: .canon, draftedBy: "AI · reviewed", unlocks: "Secret: The Archivist"),
      DemoChapter(id: 43, title: "The forty-first step", words: 2_780, status: .review, draftedBy: "Mira Vale", unlocks: nil),
      DemoChapter(id: 44, title: "A door with no handle", words: 3_050, status: .review, draftedBy: "AI · draft", unlocks: nil),
      DemoChapter(id: 45, title: "The Archivist’s bargain", words: 2_410, status: .draft, draftedBy: "AI · draft", unlocks: "Secret: The bargain"),
      DemoChapter(id: 46, title: "Ash Garden", words: 860, status: .draft, draftedBy: "Mira Vale", unlocks: nil),
    ]

  static let recent = Array(all.suffix(12))

  static let featured = all.first { $0.id == 42 } ?? all[0]
}

struct DemoQuest: Identifiable, Hashable {
  let id: String
  let title: String
  let detail: String
  let progress: Double
  let isNew: Bool

  static let all: [DemoQuest] = [
    DemoQuest(id: "moths", title: "Count the moths", detail: "The Moth Choir · 3 of 7 found", progress: 3 / 7, isNew: true),
    DemoQuest(id: "stair", title: "Climb the glass stair", detail: "The Ninth Archive · 40 of 60 steps", progress: 40 / 60, isNew: true),
    DemoQuest(id: "salt", title: "Walk the salt road", detail: "Salt Kings · Chapter 9 of 30", progress: 9 / 30, isNew: true),
    DemoQuest(id: "ledger", title: "Balance the ledger of ash", detail: "Glass and Ash · 2 of 5 entries", progress: 2 / 5, isNew: true),
    DemoQuest(id: "court", title: "Earn a seat at court", detail: "The Lantern Court · Chapter 3 of 41", progress: 3 / 41, isNew: false),
    DemoQuest(id: "garden", title: "Name every flower", detail: "Ash Garden · 18 of 50", progress: 18 / 50, isNew: false),
    DemoQuest(id: "streak", title: "Read twelve days in a row", detail: "Memoir · 12 of 12 days", progress: 1, isNew: false),
    DemoQuest(id: "archive", title: "Open the ninth archive", detail: "The Ninth Archive · Locked", progress: 0, isNew: false),
  ]
}

enum DemoProse {
  static let paragraphs: [String] = [
    CatalogBook.prose,
    "“You read the names on the way up,” he said. “Most people only read their own.” She did not tell him which names she had seen, or that one of them was still warm.",
    "The Archivist kept his ledgers in glass cases that fogged when anyone lied near them. Mira had learned to breathe slowly in that room, and to answer questions with other questions.",
    "Below them the lantern court was waking. Someone was singing the moth song again, the one with the verse nobody admits to knowing, and the stair hummed along in a key just under hearing.",
    "“Forty steps,” the Archivist said at last, “and each one keeps a name. You will want to know which is yours. Everyone does. It is the wrong question.”",
    "She asked the right one instead. He laughed, which she had not heard him do before, and the glass beneath her feet went briefly clear, so that she could see all the way down.",
    "There were more steps than forty. There always had been. The lanterns had only ever lit the ones people were ready to climb.",
    "When she reached the landing the door had no handle, only a seam of light and the faint smell of salt. She put her palm flat against it and waited for it to decide about her.",
  ]
}

struct DemoReader: View {
  var bold = false
  var italic = false

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space4) {
      ForEach(DemoProse.paragraphs, id: \.self) { paragraph in
        Text(verbatim: paragraph)
          .bold(bold)
          .italic(italic)
      }
    }
    .shadowFont(.body)
    .lineSpacing(Spacing.space1)
    .foregroundStyle(ShadowColor.textPrimary)
    .frame(maxWidth: ShadowMetrics.readableWidth, alignment: .leading)
    .padding(.horizontal, DemoLayout.margin)
    .padding(.vertical, Spacing.space4)
    .frame(maxWidth: .infinity)
  }
}

enum DemoLayout {
  static var margin: CGFloat { ShadowDensity.current == .touch ? Spacing.space4 : Spacing.space5 }
}

struct DemoCoverGrid: View {
  var books = Array(CatalogBook.shelf.prefix(6))

  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: Spacing.space2)], spacing: Spacing.space2) {
      ForEach(books) { book in
        CoverArt(book: book)
          .aspectRatio(0.75, contentMode: .fit)
      }
    }
  }
}

struct DemoCoverShelf: View {
  var books = CatalogBook.shelf

  var body: some View {
    ScrollView(.horizontal) {
      LazyHStack(spacing: Spacing.space2) {
        ForEach(books) { book in
          CoverArt(book: book)
            .frame(width: 110, height: 146)
        }
      }
    }
    .scrollIndicators(.hidden)
    .contentMargins(.horizontal, DemoLayout.margin, for: .scrollContent)
    .padding(.horizontal, -DemoLayout.margin)
  }
}

struct DemoBookRows: View {
  var books = Array(CatalogBook.shelf.dropFirst().prefix(3))

  var body: some View {
    ForEach(books) { book in
      ShadowListRow(title: Text(verbatim: book.title), subtitle: Text(verbatim: book.progress), accessory: .chevron) { ListCover(book: book) }
    }
  }
}

struct ContinueReadingAccessory: View {
  #if os(iOS)
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
  #endif

  private var isInline: Bool {
    #if os(iOS)
      placement == .inline
    #else
      false
    #endif
  }

  var body: some View {
    HStack(spacing: Spacing.space3) {
      RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
        .fill(CatalogBook.shelf[0].color.gradient)
        .frame(width: 24, height: 32)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 0) {
        Text(verbatim: CatalogBook.shelf[0].title)
          .shadowFont(.subheadline)
          .fontWeight(.semibold)
          .foregroundStyle(ShadowColor.textPrimary)
        Text(isInline ? "Chapter 42" : "Chapter 42 · 68%")
          .shadowFont(.caption)
          .foregroundStyle(ShadowColor.textSecondary)
      }
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)
      Button("Continue reading", systemImage: "play.fill") {}
        .labelStyle(.iconOnly)
        .foregroundStyle(ShadowColor.accentText)
    }
    .padding(.horizontal, Spacing.space4)
  }
}

extension View {
  func demoInspector<Inspector: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Inspector) -> some View {
    #if os(visionOS)
      sheet(isPresented: isPresented, content: content)
    #else
      inspector(isPresented: isPresented, content: content)
    #endif
  }
}
