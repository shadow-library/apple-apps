import ShadowDesignSystem
import SwiftUI

struct TokensPage: View {
  private static let swatchRowWidth: CGFloat = 280
  private static let maxSwatchColumns = 8

  var body: some View {
    ComponentPage(id: "tokens") {
      StateSection("Colour", note: "Every semantic token, rendered in light (left) and dark (right).") {
        ShadowAdaptiveColumns(maxColumns: Self.maxSwatchColumns, minColumnWidth: Self.swatchRowWidth, spacing: Spacing.space5, rowSpacing: Spacing.space2) {
          ForEach(ShadowColorToken.allCases, id: \.self) { token in
            ColorSwatchRow(token: token)
          }
        }
      }
      .shadowColumnSpan(.full)
      StateSection("Spacing") {
        VStack(alignment: .leading, spacing: Spacing.space2) {
          ForEach(Spacing.tokens) { token in
            TokenBarRow(token: token)
          }
        }
      }
      StateSection("Radius") {
        ShadowAdaptiveColumns(maxColumns: Radius.tokens.count, minColumnWidth: 96, spacing: Spacing.space3) {
          ForEach(Radius.tokens) { token in
            RadiusSwatch(token: token)
          }
        }
      }
      StateSection("Type styles") {
        ShadowAdaptiveColumns(maxColumns: TypeStyleFamily.allCases.count, minColumnWidth: Self.swatchRowWidth, spacing: Spacing.space5) {
          ForEach(TypeStyleFamily.allCases, id: \.self) { family in
            TypeStyleGroup(family: family)
          }
        }
      }
      .shadowColumnSpan(.full)
    }
  }
}

private struct ColorSwatchRow: View {
  let token: ShadowColorToken

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      Text(token.rawValue).shadowFont(.monoBody).foregroundStyle(ShadowColor.textSecondary)
      HStack(spacing: Spacing.space2) {
        Swatch(token: token, scheme: .light)
        Swatch(token: token, scheme: .dark)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private struct Swatch: View {
    let token: ShadowColorToken
    let scheme: ColorScheme

    var body: some View {
      RoundedRectangle(cornerRadius: Radius.md)
        .fill(token.color)
        .frame(height: 32)
        .overlay { RoundedRectangle(cornerRadius: Radius.md).strokeBorder(ShadowColor.borderDefault) }
        .padding(Spacing.space1)
        .background(ShadowColor.surfaceApp, in: .rect(cornerRadius: Radius.lg))
        .environment(\.colorScheme, scheme)
        .accessibilityLabel(scheme == .light ? "Light" : "Dark")
    }
  }
}

private enum TypeStyleFamily: CaseIterable {
  case touch
  case mac
  case mono

  var title: LocalizedStringKey {
    switch self {
    case .touch: "iOS and iPadOS"
    case .mac: "macOS"
    case .mono: "Mono"
    }
  }

  var styles: [ShadowTextStyle] {
    ShadowTextStyle.allCases.filter { $0.family == self }
  }
}

extension ShadowTextStyle {
  fileprivate var family: TypeStyleFamily {
    switch self {
    case .iosLargeTitle, .iosTitle1, .iosTitle2, .iosTitle3, .iosHeadline, .iosBody, .iosCallout, .iosSubheadline, .iosFootnote, .iosCaption, .iosCaption2: .touch
    case .macLargeTitle, .macTitle1, .macTitle2, .macTitle3, .macHeadline, .macBody, .macCallout, .macSubheadline, .macFootnote, .macCaption: .mac
    case .monoBody, .monoFigure: .mono
    }
  }
}

private struct TypeStyleGroup: View {
  let family: TypeStyleFamily

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      Text(family.title)
        .shadowFont(.subheadline)
        .fontWeight(.semibold)
        .foregroundStyle(ShadowColor.textSecondary)
        .accessibilityAddTraits(.isHeader)
      ForEach(family.styles, id: \.self) { style in
        VStack(alignment: .leading, spacing: Spacing.space05) {
          Text("The Ninth Archive").shadowFont(style).foregroundStyle(ShadowColor.textPrimary)
          Text(style.rawValue).shadowFont(.monoBody).foregroundStyle(ShadowColor.textSecondary)
        }
      }
    }
  }
}

private struct TokenBarRow: View {
  let token: ShadowScalarToken

  var body: some View {
    HStack(spacing: Spacing.space3) {
      Text(token.name).shadowFont(.monoBody).foregroundStyle(ShadowColor.textSecondary).frame(width: 120, alignment: .leading)
      RoundedRectangle(cornerRadius: Radius.sm).fill(ShadowColor.accent).frame(width: token.value, height: Spacing.space4)
      Text("\(Int(token.value)) pt").shadowFont(.footnote).foregroundStyle(ShadowColor.textTertiary)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct RadiusSwatch: View {
  let token: ShadowScalarToken

  var body: some View {
    VStack(spacing: Spacing.space1) {
      RoundedRectangle(cornerRadius: token.value)
        .fill(ShadowColor.accentSoft)
        .overlay { RoundedRectangle(cornerRadius: token.value).strokeBorder(ShadowColor.accent) }
        .frame(height: 56)
      Text(token.name).shadowFont(.monoBody).foregroundStyle(ShadowColor.textSecondary)
    }
    .accessibilityElement(children: .combine)
  }
}
