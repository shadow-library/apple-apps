import ShadowDesignSystem
import SwiftUI

struct CatalogBook: Identifiable, Hashable {
  let id: String
  let title: String
  let progress: String
  let symbol: String
  let color: Color

  static let shelf: [CatalogBook] = [
    CatalogBook(id: "IX", title: "The Ninth Archive", progress: "Chapter 12 of 40", symbol: "building.columns", color: ShadowColor.chart1),
    CatalogBook(id: "G&A", title: "Glass and Ash", progress: "Chapter 25 of 64", symbol: "flame", color: ShadowColor.chart2),
    CatalogBook(id: "SK", title: "Salt Kings", progress: "Chapter 9 of 30", symbol: "crown", color: ShadowColor.chart3),
    CatalogBook(id: "LC", title: "The Lantern Court", progress: "Chapter 3 of 41", symbol: "lamp.table", color: ShadowColor.chart7),
    CatalogBook(id: "AG", title: "Ash Garden", progress: "Chapter 18 of 50", symbol: "leaf", color: ShadowColor.chart5),
    CatalogBook(id: "MC", title: "The Moth Choir", progress: "Chapter 1 of 12", symbol: "moon.stars", color: ShadowColor.chart4),
    CatalogBook(id: "GS", title: "The Glass Stair", progress: "Chapter 42 of 60", symbol: "stairs", color: ShadowColor.chart6),
    CatalogBook(id: "MV", title: "Mira Vale", progress: "Chapter 7 of 22", symbol: "sparkles", color: ShadowColor.chart8),
  ]

  static let prose =
    "The stair was made of glass, and every step remembered who had climbed it. Mira counted forty before the Archivist spoke, and by then the lanterns below had gone out one by one."
}

struct CoverArt: View {
  let book: CatalogBook
  var showsTitle = true

  var body: some View {
    RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
      .fill(LinearGradient(colors: [book.color, book.color.mix(with: .black, by: 0.35)], startPoint: .topLeading, endPoint: .bottomTrailing))
      .overlay(alignment: .topTrailing) {
        Image(systemName: book.symbol)
          .font(.system(.largeTitle, weight: .light))
          .foregroundStyle(ShadowColor.onAccent.opacity(0.55))
          .padding(Spacing.space2)
      }
      .overlay(alignment: .bottomLeading) {
        if showsTitle {
          VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: book.id).font(.system(.caption, weight: .bold))
            Text(verbatim: book.title).font(.system(.caption2, weight: .medium)).lineLimit(2)
          }
          .foregroundStyle(ShadowColor.onAccent)
          .padding(Spacing.space2)
        }
      }
      .accessibilityElement()
      .accessibilityLabel(Text(verbatim: book.title))
  }
}

struct CoverWall: View {
  var columns = 4
  var books = CatalogBook.shelf

  var body: some View {
    Grid(horizontalSpacing: Spacing.space2, verticalSpacing: Spacing.space2) {
      ForEach(Array(stride(from: 0, to: books.count, by: columns)), id: \.self) { start in
        GridRow {
          ForEach(books[start..<min(start + columns, books.count)]) { book in
            CoverArt(book: book)
          }
        }
      }
    }
  }
}

struct GlassStage<Chrome: View>: View {
  var height: CGFloat = 180
  var alignment: Alignment = .top
  @ViewBuilder let chrome: Chrome

  var body: some View {
    chrome
      .padding(Spacing.space2)
      .frame(maxWidth: .infinity, minHeight: height, alignment: alignment)
      .background {
        CoverWall()
          .padding(Spacing.space2)
          .background(ShadowColor.surfaceCard)
      }
      .clipShape(.rect(cornerRadius: ShadowCardMetrics().cornerRadius, style: .continuous))
  }
}
