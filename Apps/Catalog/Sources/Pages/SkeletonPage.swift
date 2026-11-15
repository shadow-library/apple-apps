import ShadowDesignSystem
import SwiftUI

private struct RowMetrics {
  let isTouch = ShadowDensity.current == .touch

  var coverWidth: CGFloat { isTouch ? 44 : 28 }
  var coverHeight: CGFloat { isTouch ? 62 : 40 }
  var coverRadius: CGFloat { isTouch ? Radius.md : Radius.sm }
  var verticalPadding: CGFloat { isTouch ? Spacing.space2 + Spacing.space05 : Spacing.space1 + Spacing.space05 }
  let horizontalPadding = Spacing.space4
  let coverGap = Spacing.space3
  let textGap = Spacing.space2
}

struct SkeletonPage: View {
  @State private var isLoading = true

  private let widths: [CGFloat] = [0.4, 0.55, 0.35]

  var body: some View {
    ComponentPage(component: .skeleton) {
      StateSection("Loading list", note: "Same shapes as the loaded rows. Bars use fill-track at the real text sizes, and the pulse stops with Reduce Motion.") {
        SkeletonList(isLoading: true) {
          ForEach(Array(widths.enumerated()), id: \.offset) { _, width in
            SkeletonShapeRow(subtitleWidth: width)
          }
        }
      }
      StateSection("Redacted rows", note: "The real row view with `.shadowSkeleton(_:)`, so the layout does not jump when data lands. Toggle to compare.") {
        VStack(alignment: .leading, spacing: Spacing.space3) {
          SkeletonList(isLoading: isLoading) {
            ForEach(CatalogBook.shelf.prefix(3)) { book in
              BookRow(book: book)
            }
          }
          Button(isLoading ? "Show loaded content" : "Show skeleton") { isLoading.toggle() }
            .buttonStyle(.shadowTinted)
            .controlSize(.small)
        }
      }
      StateSection("Loading cards", note: "Cards keep 16pt inside and 16pt between, so a loading screen breathes like the loaded one.") {
        VStack(spacing: Spacing.space4) {
          ForEach(0..<2, id: \.self) { _ in SkeletonCard() }
        }
      }
      StateSection("Loaded cards", note: "The same cards with content.") {
        VStack(spacing: Spacing.space4) {
          ForEach(CatalogBook.shelf.prefix(2)) { book in ArticleCard(book: book) }
        }
      }
      StateSection("Building blocks", note: "Lines, circles and rectangles for shapes the real view cannot redact.") {
        HStack(alignment: .top, spacing: Spacing.space3) {
          ShadowSkeletonCircle(diameter: Spacing.space10 + Spacing.space2)
          VStack(alignment: .leading, spacing: Spacing.space2) {
            ShadowSkeletonLine(.title, widthFraction: 0.6)
            ShadowSkeletonLine(widthFraction: 0.9)
            ShadowSkeletonLine(widthFraction: 0.45)
            ShadowSkeletonRectangle(cornerRadius: Radius.lg, height: Spacing.space10 + Spacing.space6)
          }
        }
        .shadowSkeleton(true)
        .shadowCard()
      }
      StateSection("Light and dark") {
        SchemePair {
          VStack(alignment: .leading, spacing: Spacing.space2) {
            ShadowSkeletonLine(.title, widthFraction: 0.6)
            ShadowSkeletonLine(widthFraction: 0.4)
            ShadowSkeletonRectangle(height: Spacing.space10)
          }
          .shadowSkeleton(true)
        }
      }
      .shadowColumnSpan(.full)
    }
  }
}

private struct SkeletonList<Content: View>: View {
  let isLoading: Bool
  @ViewBuilder let content: Content

  var body: some View {
    VStack(spacing: 0) {
      Group(subviews: content) { rows in
        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
          if index > 0 { Divider().padding(.leading, RowMetrics().horizontalPadding) }
          row
        }
      }
      .shadowSkeleton(isLoading, label: "Loading")
    }
    .frame(maxWidth: .infinity)
    .background(ShadowColor.surfaceCard, in: .rect(cornerRadius: ShadowCardMetrics().cornerRadius, style: .continuous))
    .overlay {
      if ShadowDensity.current == .compact {
        RoundedRectangle(cornerRadius: ShadowCardMetrics().cornerRadius, style: .continuous).strokeBorder(ShadowColor.borderDefault, lineWidth: 1)
      }
    }
  }
}

private struct SkeletonShapeRow: View {
  let subtitleWidth: CGFloat
  private let metrics = RowMetrics()

  var body: some View {
    HStack(spacing: metrics.coverGap) {
      ShadowSkeletonRectangle(cornerRadius: metrics.coverRadius, width: metrics.coverWidth, height: metrics.coverHeight)
      VStack(alignment: .leading, spacing: metrics.textGap) {
        ShadowSkeletonLine(.title, widthFraction: 0.6)
        ShadowSkeletonLine(widthFraction: subtitleWidth)
      }
    }
    .padding(.horizontal, metrics.horizontalPadding)
    .padding(.vertical, metrics.verticalPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct BookRow: View {
  let book: CatalogBook
  private let metrics = RowMetrics()

  var body: some View {
    HStack(spacing: metrics.coverGap) {
      CoverArt(book: book, showsTitle: false)
        .frame(width: metrics.coverWidth, height: metrics.coverHeight)
        .shadowSkeletonShape(RoundedRectangle(cornerRadius: metrics.coverRadius, style: .continuous))
      VStack(alignment: .leading, spacing: metrics.textGap / 2) {
        Text(verbatim: book.title)
          .shadowFont(.body)
          .foregroundStyle(ShadowColor.textPrimary)
          .shadowSkeletonText()
        Text(verbatim: book.progress)
          .shadowFont(.subheadline)
          .foregroundStyle(ShadowColor.textSecondary)
          .shadowSkeletonText()
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, metrics.horizontalPadding)
    .padding(.vertical, metrics.verticalPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct SkeletonCard: View {
  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      ShadowSkeletonRectangle(cornerRadius: ShadowCardMetrics().innerCornerRadius, height: Spacing.space10 * 3)
      ShadowSkeletonLine(.title, widthFraction: 0.7)
      VStack(alignment: .leading, spacing: Spacing.space2) {
        ShadowSkeletonLine()
        ShadowSkeletonLine(widthFraction: 0.85)
      }
      HStack(spacing: Spacing.space3) {
        ShadowSkeletonCircle(diameter: Spacing.space8)
        ShadowSkeletonLine(widthFraction: 0.4)
      }
    }
    .shadowSkeleton(true, label: "Loading")
    .shadowCard()
  }
}

private struct ArticleCard: View {
  let book: CatalogBook

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      CoverArt(book: book, showsTitle: false)
        .frame(height: Spacing.space10 * 3)
        .clipShape(.rect(cornerRadius: ShadowCardMetrics().innerCornerRadius, style: .continuous))
      Text(verbatim: book.title)
        .shadowFont(.headline)
        .foregroundStyle(ShadowColor.textPrimary)
      Text(verbatim: CatalogBook.prose)
        .shadowFont(.subheadline)
        .foregroundStyle(ShadowColor.textSecondary)
        .lineLimit(2)
      HStack(spacing: Spacing.space3) {
        ShadowAvatar(name: "Mira Vale", size: .small)
        Text("Mira Vale")
          .shadowFont(.footnote)
          .foregroundStyle(ShadowColor.textSecondary)
      }
    }
    .shadowCard()
  }
}
