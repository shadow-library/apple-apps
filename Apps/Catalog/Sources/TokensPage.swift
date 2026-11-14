import ShadowDesignSystem
import SwiftUI

struct TokensPage: View {
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Spacing.space8) {
        StateSection("Colour", note: "Every semantic token, rendered in light (left) and dark (right).") {
          LazyVStack(alignment: .leading, spacing: Spacing.space2) {
            ForEach(ShadowColorToken.allCases, id: \.self) { token in
              ColorSwatchRow(token: token)
            }
          }
        }
        StateSection("Spacing") {
          VStack(alignment: .leading, spacing: Spacing.space2) {
            ForEach(Spacing.tokens) { token in
              TokenBarRow(token: token)
            }
          }
        }
        StateSection("Radius") {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: Spacing.space3)], alignment: .leading, spacing: Spacing.space3) {
            ForEach(Radius.tokens) { token in
              RadiusSwatch(token: token)
            }
          }
        }
        StateSection("Type styles") {
          VStack(alignment: .leading, spacing: Spacing.space3) {
            ForEach(ShadowTextStyle.allCases, id: \.self) { style in
              VStack(alignment: .leading, spacing: Spacing.space05) {
                Text("The Ninth Archive").shadowFont(style).foregroundStyle(ShadowColor.textPrimary)
                Text(style.rawValue).shadowFont(.monoBody).foregroundStyle(ShadowColor.textSecondary)
              }
            }
          }
        }
      }
      .frame(maxWidth: ShadowMetrics.readableWidth, alignment: .leading)
      .padding(Spacing.space4)
      .frame(maxWidth: .infinity)
    }
    .catalogScrollAnchor()
    .background(ShadowColor.surfaceApp)
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
