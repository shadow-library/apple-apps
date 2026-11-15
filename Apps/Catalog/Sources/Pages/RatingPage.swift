@_spi(Preview) import ShadowDesignSystem
import SwiftUI

struct RatingPage: View {
  @State private var chapter = 4
  @State private var unrated = 0
  @State private var hovered = 2
  @State private var small = 3
  @State private var medium = 4
  @State private var large = 5

  var body: some View {
    ComponentPage(component: .rating) {
      StateSection("Rate this chapter", note: "4 of 5 stars. Adjustable with swipe up or down in VoiceOver; tap or drag on touch, click, drag or arrow keys on Mac.") {
        RatingRow("Rate this chapter") {
          ShadowRating("Rate this chapter", value: $chapter, valueDescription: stars)
        }
      }
      StateSection("Unrated", note: "Empty stars in text-tertiary invite a first rating. Dragging past the first star clears it again.") {
        RatingRow("Rate this chapter") {
          ShadowRating("Rate this chapter", value: $unrated, valueDescription: stars)
        }
      }
      if DemoPlatform.hasPointer {
        StateSection(
          "Hover preview", note: "With a pointer on Mac and iPad, the stars up to the pointer preview the new value at half strength before the click."
        ) {
          RatingRow("Rate this chapter") {
            ShadowRating("Rate this chapter", value: $hovered, valueDescription: stars)
              .shadowPreviewRatingHover(4)
          }
        }
      }
      StateSection("Book ratings", note: "Read-only ratings show half stars, the average and a grouped count of ratings.") {
        VStack(spacing: 0) {
          ForEach(Array(RatedBook.shelf.enumerated()), id: \.element.book.id) { index, rated in
            if index > 0 { Divider().padding(.leading, Spacing.space10 + Spacing.space3) }
            BookRatingRow(rated: rated)
          }
        }
        .shadowCard()
      }
      StateSection("Sizes", note: "Small for list rows, medium beside body text, large on a review screen. Stars follow Dynamic Type.") {
        RatingGroup {
          RatingLine("Small") {
            ShadowRating("Small", value: $small, valueDescription: stars).controlSize(.small)
          }
          Divider()
          RatingLine("Medium") {
            ShadowRating("Medium", value: $medium, valueDescription: stars)
          }
          Divider()
          RatingLine("Large") {
            ShadowRating("Large", value: $large, valueDescription: stars).controlSize(.large)
          }
        }
      }
      StateSection("Half stars", note: "Averages round to the nearest half star; input is always whole stars.") {
        VStack(alignment: .leading, spacing: Spacing.space3) {
          ForEach([3.5, 4.2, 4.8], id: \.self) { value in
            ShadowRating("Average rating", rating: value, showsValue: true, valueDescription: average)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .shadowCard()
      }
      StateSection("Disabled", note: "Ratings lock once a chapter is archived.") {
        RatingRow("Rate this chapter") {
          ShadowRating("Rate this chapter", value: .constant(3), valueDescription: stars)
            .disabled(true)
        }
      }
    }
  }
}

private struct RatingRow<Content: View>: View {
  let title: LocalizedStringKey
  @ViewBuilder let content: Content

  init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    RatingGroup {
      RatingLine(title) { content }
    }
  }
}

private struct RatingLine<Content: View>: View {
  let title: LocalizedStringKey
  @ViewBuilder let content: Content

  init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    HStack(spacing: Spacing.space3) {
      Text(title)
        .foregroundStyle(ShadowColor.textPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
      content
    }
    .frame(minHeight: ShadowMetrics.rowHeight)
  }
}

private struct RatingGroup<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    VStack(spacing: 0) { content }
      #if os(macOS)
        .shadowCard()
      #else
        .padding(.horizontal, Spacing.space4)
        .padding(.vertical, Spacing.space1)
        .background(ShadowColor.surfaceCard, in: .rect(cornerRadius: Radius.section, style: .continuous))
      #endif
  }
}

private struct RatedBook {
  let book: CatalogBook
  let rating: Double
  let count: Int

  static let shelf = [
    RatedBook(book: CatalogBook.shelf[0], rating: 4.6, count: 3_214),
    RatedBook(book: CatalogBook.shelf[1], rating: 4.2, count: 18_402),
    RatedBook(book: CatalogBook.shelf[2], rating: 3.7, count: 862),
    RatedBook(book: CatalogBook.shelf[6], rating: 4.9, count: 1_027_331),
  ]
}

private struct BookRatingRow: View {
  let rated: RatedBook

  var body: some View {
    HStack(spacing: Spacing.space3) {
      CoverArt(book: rated.book, showsTitle: false)
        .frame(width: Spacing.space10, height: Spacing.space10 * 1.4)
      VStack(alignment: .leading, spacing: Spacing.space05) {
        Text(verbatim: rated.book.title)
          .foregroundStyle(ShadowColor.textPrimary)
        ShadowRating("Average rating", rating: rated.rating, count: Text("(\(rated.count, format: .number))"), showsValue: true) { value in
          Text("\(value, format: .number.precision(.fractionLength(1))) out of 5, \(rated.count) ratings")
        }
        .controlSize(.small)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, Spacing.space2)
    .accessibilityElement(children: .combine)
  }
}

private func stars(_ value: Int) -> Text {
  Text("\(value) of 5 stars")
}

private func average(_ value: Double) -> Text {
  Text("\(value, format: .number.precision(.fractionLength(1))) out of 5")
}
