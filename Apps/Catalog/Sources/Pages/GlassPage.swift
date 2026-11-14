import ShadowDesignSystem
import SwiftUI

struct GlassPage: View {
  var body: some View {
    ComponentPage(component: .glass) {
      StateSection("Regular", note: "Bar buttons and grouped actions in regular glass, with one tinted action that completes the task.") {
        GlassStage(height: 132) {
          HStack(spacing: Spacing.space2) {
            ShadowIconButton("Back", systemImage: "chevron.backward", variant: .glass) {}
            ShadowIconButtonGroup {
              ShadowIconButton("Bookmark", systemImage: "bookmark", variant: .glass) {}
              ShadowIconButton("Text size", systemImage: "textformat.size", variant: .glass) {}
              ShadowIconButton("Share", systemImage: "square.and.arrow.up", variant: .glass) {}
            }
            Spacer(minLength: 0)
            if ShadowDensity.current == .touch {
              ShadowIconButton("Done", systemImage: "checkmark", variant: .glassProminent) {}
            } else {
              Button("Publish") {}.buttonStyle(.shadowGlassProminent)
            }
          }
        }
      }
      StateSection("Interactive", note: "Touch-down lifts, scales and brightens the glass; the system draws it. Press and hold any of these.") {
        GlassStage(height: 132, alignment: .center) {
          HStack(spacing: Spacing.space3) {
            ShadowIconButton("Favourite", systemImage: "heart", variant: .glass) {}
            Button("Save", systemImage: "bookmark") {}.buttonStyle(.shadowGlass)
            Button("Save", systemImage: "bookmark") {}.buttonStyle(.shadowGlass).controlSize(.large)
          }
        }
      }
      StateSection("Grouping", note: "Glass in one container merges when items sit closer than its spacing, so related actions read as one shape.") {
        GlassStage(height: 132, alignment: .center) {
          GroupingDemo()
        }
      }
      StateSection("Morphing", note: "Shapes morph between states with glassEffectID instead of cross-fading. Tap the button to collapse and expand.") {
        GlassStage(height: 132, alignment: .center) {
          MorphingDemo()
        }
      }
      StateSection("Clear", note: "Only over photos, covers and full-bleed media, with a dimming layer and white glyphs.") {
        ClearDemo()
      }
      StateSection("Dense panels", note: "Menus, popovers and the palette carry reading text, so they use denser glass. Regular glass on the left for comparison.") {
        GlassStage(height: 196, alignment: .center) {
          ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Spacing.space3) {
              ChapterMenu(glass: .regular)
              ChapterMenu(glass: .dense)
            }
            VStack(spacing: Spacing.space3) {
              ChapterMenu(glass: .regular)
              ChapterMenu(glass: .dense)
            }
          }
        }
      }
      StateSection("Scroll edge", note: "Content scrolls beneath floating glass; the soft scroll-edge effect keeps the bar legible without an opaque background.") {
        ScrollEdgeDemo()
      }
      StateSection("Content stays flat", note: "Inside a card, glass is refused: glass buttons fall back to bordered and filled, and .shadowGlass draws nothing.") {
        ShadowCard {
          HStack(spacing: Spacing.space3) {
            Button("Save", systemImage: "bookmark") {}.buttonStyle(.shadowGlass)
            Button("Publish") {}.buttonStyle(.shadowGlassProminent)
            Text("Not glass")
              .shadowFont(.subheadline)
              .padding(.horizontal, Spacing.space3)
              .padding(.vertical, Spacing.space2)
              .shadowGlass()
          }
        } header: {
          ShadowCardHeader("Glass and Ash", subtitle: "Chapter 25 of 64")
        }
      }
    }
  }
}

private struct GroupingDemo: View {
  var body: some View {
    HStack(spacing: Spacing.space6) {
      ShadowGlassGroup(spacing: 0) {
        HStack(spacing: Spacing.space3) {
          ShadowIconButton("Bold", systemImage: "bold", variant: .glass) {}
          ShadowIconButton("Italic", systemImage: "italic", variant: .glass) {}
        }
      }
      ShadowGlassGroup(spacing: Spacing.space6) {
        HStack(spacing: Spacing.space1) {
          ShadowIconButton("Bold", systemImage: "bold", variant: .glass) {}
          ShadowIconButton("Italic", systemImage: "italic", variant: .glass) {}
        }
      }
    }
  }
}

private struct MorphingDemo: View {
  @State private var isExpanded = true
  @Namespace private var namespace
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ShadowGlassGroup(spacing: Spacing.space5) {
      HStack(spacing: Spacing.space2) {
        if isExpanded {
          ShadowIconButton("Camera", systemImage: "camera", variant: .glass) {}
            .shadowGlassID("camera", in: namespace)
          ShadowIconButton("Photos", systemImage: "photo", variant: .glass) {}
            .shadowGlassID("photos", in: namespace)
          ShadowIconButton("Files", systemImage: "doc", variant: .glass) {}
            .shadowGlassID("files", in: namespace)
        }
        ShadowIconButton(isExpanded ? "Close attachments" : "Add attachment", systemImage: isExpanded ? "xmark" : "plus", variant: .glass) {
          withAnimation(.shadow(.emphasized, reduceMotion: reduceMotion)) { isExpanded.toggle() }
        }
        .shadowGlassID("toggle", in: namespace)
      }
    }
  }
}

private struct ClearDemo: View {
  var body: some View {
    CoverWall(columns: 4)
      .frame(height: 220)
      .overlay(alignment: .top) {
        HStack {
          ShadowIconButton("Back", systemImage: "chevron.backward", variant: .glass) {}
            .shadowGlass(.clear.interactive(), in: Circle())
          Spacer()
          ShadowIconButtonGroup(.clear) {
            ShadowIconButton("Share", systemImage: "square.and.arrow.up", variant: .glass) {}
            ShadowIconButton("More", systemImage: "ellipsis", variant: .glass) {}
          }
        }
        .padding(Spacing.space2)
      }
      .clipShape(.rect(cornerRadius: ShadowCardMetrics().cornerRadius, style: .continuous))
  }
}

private struct ChapterMenu: View {
  let glass: ShadowGlass

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      MenuRow(title: "New chapter", shortcut: "⌘N")
      MenuRow(title: "Duplicate", shortcut: "⌘D", isHighlighted: true)
      MenuRow(title: "Move to Archive", shortcut: "⌘⌫")
    }
    .padding(Spacing.space1)
    .frame(minWidth: 220, maxWidth: 260)
    .fixedSize(horizontal: false, vertical: true)
    .shadowGlass(glass, in: RoundedRectangle(cornerRadius: ShadowDensity.current == .touch ? Radius.panel : Radius.lg, style: .continuous))
  }
}

private struct MenuRow: View {
  let title: LocalizedStringKey
  let shortcut: String
  var isHighlighted = false

  var body: some View {
    HStack {
      Text(title)
      Spacer(minLength: Spacing.space3)
      Text(verbatim: shortcut).foregroundStyle(isHighlighted ? ShadowColor.onAccent : ShadowColor.textSecondary)
    }
    .shadowFont(.body)
    .foregroundStyle(isHighlighted ? ShadowColor.onAccent : ShadowColor.textPrimary)
    .padding(.horizontal, Spacing.space3)
    .frame(minHeight: ShadowMetrics.rowHeight)
    .background {
      if isHighlighted {
        RoundedRectangle(cornerRadius: ShadowDensity.current == .touch ? Radius.panel - Spacing.space1 : Radius.md, style: .continuous)
          .fill(ShadowColor.accent)
      }
    }
  }
}

private struct ScrollEdgeDemo: View {
  @State private var position = ScrollPosition()

  var body: some View {
    ScrollView {
      VStack(spacing: Spacing.space2) {
        ForEach(CatalogBook.shelf) { book in
          BookRow(book: book)
        }
      }
      .padding(.horizontal, Spacing.space2)
    }
    .scrollPosition($position)
    .onAppear { position.scrollTo(y: 72) }
    .modifier(SoftTopScrollEdge())
    .safeAreaBar(edge: .top) {
      HStack {
        ShadowIconButton("Back", systemImage: "chevron.backward", variant: .glass) {}
        Spacer()
        ShadowIconButtonGroup {
          ShadowIconButton("Search", systemImage: "magnifyingglass", variant: .glass) {}
          ShadowIconButton("More", systemImage: "ellipsis", variant: .glass) {}
        }
      }
      .padding(.horizontal, Spacing.space2)
      .padding(.vertical, Spacing.space1)
    }
    .frame(height: 260)
    .background(ShadowColor.surfaceApp)
    .clipShape(.rect(cornerRadius: ShadowCardMetrics().cornerRadius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: ShadowCardMetrics().cornerRadius, style: .continuous).strokeBorder(ShadowColor.borderDefault)
    }
  }
}

private struct SoftTopScrollEdge: ViewModifier {
  func body(content: Content) -> some View {
    #if os(visionOS)
      content
    #else
      content.scrollEdgeEffectStyle(.soft, for: .top)
    #endif
  }
}

private struct BookRow: View {
  let book: CatalogBook

  var body: some View {
    HStack(spacing: Spacing.space3) {
      CoverArt(book: book, showsTitle: false)
        .frame(width: 44, height: 56)
      VStack(alignment: .leading, spacing: Spacing.space05) {
        Text(verbatim: book.title).shadowFont(.body).foregroundStyle(ShadowColor.textPrimary)
        Text(verbatim: book.progress).shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
      }
      Spacer(minLength: 0)
      Image(systemName: "chevron.forward")
        .shadowFont(.footnote)
        .foregroundStyle(ShadowColor.textTertiary)
        .accessibilityHidden(true)
    }
    .padding(Spacing.space3)
    .background(ShadowColor.surfaceCard, in: .rect(cornerRadius: ShadowCardMetrics().innerCornerRadius + Spacing.space2, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}
