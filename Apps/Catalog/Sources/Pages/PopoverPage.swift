import ShadowDesignSystem
import SwiftUI

struct PopoverPage: View {
  @State private var showsTextSettings = false

  var body: some View {
    ComponentPage(component: .popover) {
      StateSection(
        "Text settings",
        note:
          "Quick settings for one control. iPad and Mac: a glass panel anchored to the button, changes apply live, no Save. iPhone adapts it to a sheet at the medium detent."
      ) {
        ReaderPreview {
          Button {
            showsTextSettings = true
          } label: {
            GlassCircleLabel {
              Label("Text settings", systemImage: "textformat").labelStyle(.iconOnly)
            }
          }
          .buttonStyle(.plain)
          .help("Text settings for this book")
          .popover(isPresented: $showsTextSettings, arrowEdge: .top) {
            TextSettingsPanel()
              .presentationCompactAdaptation(.sheet)
              .shadowFittedDetents()
              .presentationDragIndicator(.visible)
          }
        }
      }
      StateSection("Panel content", note: "The same controls as the popover, shown inline so the panel is visible in a still image.") {
        StaticIllustration {
          PresentationBackdrop(height: 240, alignment: .top) {
            TextSettingsPanel()
              .frame(width: 300)
              .fixedSize(horizontal: false, vertical: true)
              .shadowGlass(.dense, in: RoundedRectangle(cornerRadius: ShadowDensity.current == .touch ? Radius.panel : Radius.lg, style: .continuous))
              .shadowElevation(.e3)
          }
        }
      }
      StateSection(
        "Help tag",
        note: "Mac shows a help tag (.help) after a pause over a control. Touch platforms never show one, so keep essential information out of it."
      ) {
        VStack(alignment: .leading, spacing: Spacing.space2) {
          HStack(spacing: Spacing.space2) {
            Button("About text settings", systemImage: "info.circle") {}
              .labelStyle(.iconOnly)
              .buttonStyle(.borderless)
              .foregroundStyle(ShadowColor.accentText)
              .help("Text settings for this book")
            StaticHelpTag(text: "Text settings for this book")
          }
          ShadowBadge("Static illustration", intent: .neutral, systemImage: "photo")
        }
      }
    }
    .catalogAutoPresent($showsTextSettings)
  }
}

private struct ReaderPreview<Control: View>: View {
  @ViewBuilder let control: Control

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      ForEach(DemoProse.paragraphs.prefix(3), id: \.self) { paragraph in
        Text(verbatim: paragraph)
      }
    }
    .shadowFont(.body)
    .lineSpacing(Spacing.space1)
    .foregroundStyle(ShadowColor.textPrimary)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, ShadowMetrics.control(.medium) + Spacing.space2)
    .shadowCard()
    .overlay(alignment: .topTrailing) {
      control.padding(Spacing.space3)
    }
  }
}

struct TextSettingsPanel: View {
  @State private var theme = ReadingTheme.sepia
  @State private var size = 0.45

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space3) {
      Text("Text")
        .shadowFont(.headline)
        .foregroundStyle(ShadowColor.textPrimary)
      Picker("Theme", selection: $theme) {
        ForEach(ReadingTheme.allCases) { theme in
          if theme == .sepia {
            Text(theme.title).tag(theme)
          } else {
            Label(theme.title, systemImage: theme.systemImage).labelStyle(.iconOnly).tag(theme)
          }
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      HStack(spacing: Spacing.space3) {
        Image(systemName: "textformat.size.smaller")
          .accessibilityHidden(true)
        Slider(value: $size) {
          Text("Text size")
        }
        .labelsHidden()
        .tint(ShadowColor.accent)
        Image(systemName: "textformat.size.larger")
          .accessibilityHidden(true)
      }
      .foregroundStyle(ShadowColor.textSecondary)
      Spacer(minLength: 0)
    }
    .padding(Spacing.space4)
    .frame(minWidth: 280)
  }
}
