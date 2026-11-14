import ShadowDesignSystem
import SwiftUI

struct InspectorPage: View {
  @State private var selection: DemoChapter.ID? = DemoChapter.featured.id
  @State private var showsInspector = true
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif

  private var presentsAsSheet: Bool {
    #if os(iOS)
      horizontalSizeClass == .compact
    #else
      false
    #endif
  }

  private var selectedChapter: DemoChapter? {
    DemoChapter.all.first { $0.id == selection }
  }

  var body: some View {
    NavigationStack {
      List(DemoChapter.recent, selection: $selection) { chapter in
        ShadowListRow(
          title: Text(verbatim: chapter.heading), subtitle: Text(verbatim: chapter.title), value: Text(verbatim: chapter.wordCount),
          isSelected: chapter.id == selection)
      }
      .shadowListStyle(.plain)
      .catalogScrollAnchor()
      .navigationTitle("Chapters")
      .demoSubtitle("The Ninth Archive")
      .shadowScreen(.root)
      .toolbar {
        CatalogDemoCloseItem()
        ToolbarItem(placement: .primaryAction) {
          InspectorToggle(isPresented: $showsInspector)
        }
      }
      .demoInspector(isPresented: $showsInspector) {
        DemoChapterInspector(chapter: selectedChapter, presentsAsSheet: presentsAsSheet, isPresented: $showsInspector)
          .shadowColumnWidth(.inspector)
          .presentationDetents([.medium, .large])
      }
    }
  }
}

struct InspectorToggle: View {
  @Binding var isPresented: Bool

  var body: some View {
    Button(isPresented ? "Hide details" : "Show details", systemImage: "sidebar.trailing") {
      isPresented.toggle()
    }
    .keyboardShortcut("i", modifiers: [.option, .command])
    .help(isPresented ? "Hide details (⌥⌘I)" : "Show details (⌥⌘I)")
    .shadowBarItem()
  }
}

struct DemoChapterInspector: View {
  let chapter: DemoChapter?
  let presentsAsSheet: Bool
  @Binding var isPresented: Bool

  var body: some View {
    if presentsAsSheet {
      VStack(spacing: 0) {
        ZStack {
          Text("Details")
            .shadowFont(.headline)
            .foregroundStyle(ShadowColor.textPrimary)
            .accessibilityAddTraits(.isHeader)
          ShadowIconButton("Close", systemImage: "xmark", variant: .glass) { isPresented = false }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, DemoLayout.margin)
        .padding(.top, Spacing.space4)
        details
      }
    } else {
      details
        .background(ShadowColor.surfaceCard)
    }
  }

  private var details: some View {
    Group {
      if let chapter {
        ScrollView {
          VStack(alignment: .leading, spacing: Spacing.space4) {
            Text("Chapter details")
              .shadowFont(.title3)
              .foregroundStyle(ShadowColor.textPrimary)
              .accessibilityAddTraits(.isHeader)
            InspectorField("Status") {
              ShadowBadge(LocalizedStringKey(chapter.status.rawValue), intent: chapter.status.intent, systemImage: chapter.status.systemImage)
            }
            InspectorField("Words") { Text(verbatim: chapter.wordCount).monospacedDigit() }
            InspectorField("Drafted by") { Text(verbatim: chapter.draftedBy) }
            InspectorField("Unlocks") { Text(verbatim: chapter.unlocks ?? "Nothing yet") }
          }
          .padding(DemoLayout.margin)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        ShadowContentUnavailable("No chapter selected", message: "Select a chapter to see its details.")
      }
    }
  }
}

private struct InspectorField<Value: View>: View {
  let title: LocalizedStringKey
  @ViewBuilder let value: Value

  init(_ title: LocalizedStringKey, @ViewBuilder value: () -> Value) {
    self.title = title
    self.value = value()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      Text(title)
        .shadowFont(.subheadline)
        .foregroundStyle(ShadowColor.textSecondary)
      value
        .shadowFont(.body)
        .foregroundStyle(ShadowColor.textPrimary)
    }
    .accessibilityElement(children: .combine)
  }
}
