@_spi(Preview) import ShadowDesignSystem
import SwiftUI

struct SearchFieldPage: View {
  @State private var query = "glass st"
  @State private var emptyQuery = ""
  @State private var eventQuery = "session.rev"
  @State private var isShowingSearch = false

  var body: some View {
    ComponentPage(component: .searchField) {
      StateSection(
        "Standalone field", note: "For search inside content. A capsule on iPhone and iPad, a radius-md field on Mac, always on surface-well with a magnifier and a clear button."
      ) {
        VStack(spacing: Spacing.space3) {
          ShadowSearchField("Search the library", text: $emptyQuery, clearLabel: "Clear search")
          ShadowSearchField("Search the library", text: $query, clearLabel: "Clear search")
            .shadowPreviewFieldFocus(true)
          ShadowSearchField("Search the library", text: $eventQuery, clearLabel: "Clear search")
            .disabled(true)
        }
        .shadowCard()
      }
      StateSection(
        "System search",
        note: "In navigation contexts use .searchable with suggestions, scopes and tokens. The sample opens in its own sheet so it has a navigation bar of its own."
      ) {
        Button("Try search", systemImage: "magnifyingglass") { isShowingSearch = true }
          .buttonStyle(.shadowTinted)
          .sheet(isPresented: $isShowingSearch) { SearchSampleSheet() }
      }
      StateSection("Suggestions", note: "Typing shows matching titles first and a catch-all “search everything” row last. Selecting a row completes the query.") {
        #if os(macOS)
          MacSuggestions(query: $eventQuery)
        #else
          TouchSuggestions()
        #endif
      }
    }
  }
}

private struct SuggestionRow: View {
  let title: LocalizedStringKey
  let subtitle: LocalizedStringKey

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(title).foregroundStyle(ShadowColor.textPrimary)
      Text(subtitle).shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
    }
  }
}

#if !os(macOS)
  private struct TouchSuggestions: View {
    @State private var query = "glass st"

    var body: some View {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        ShadowSearchField("Search the library", text: $query, clearLabel: "Clear search")
        Text("Suggestions").shadowFont(.headline).foregroundStyle(ShadowColor.textSecondary).padding(.leading, Spacing.space2)
        VStack(spacing: 0) {
          row("The Glass Stair", subtitle: "Chapter 42 · The Ninth Archive", systemImage: "book", completion: "The Glass Stair")
          Divider().padding(.leading, Spacing.space10 + Spacing.space4)
          row("Glass and Ash", subtitle: "Novel · 64 chapters", systemImage: "book", completion: "Glass and Ash")
          Divider().padding(.leading, Spacing.space10 + Spacing.space4)
          row("“glass st”", subtitle: "Search everything", systemImage: "magnifyingglass", completion: "glass st")
        }
        .background(ShadowColor.surfaceCard, in: .rect(cornerRadius: Radius.xl, style: .continuous))
      }
      .shadowCard()
    }

    private func row(_ title: LocalizedStringKey, subtitle: LocalizedStringKey, systemImage: String, completion: String) -> some View {
      Button {
        query = completion
      } label: {
        HStack(spacing: Spacing.space3) {
          Image(systemName: systemImage)
            .frame(width: ShadowMetrics.controlTouchSm, height: ShadowMetrics.controlTouchSm)
            .background(ShadowColor.surfaceWell, in: .rect(cornerRadius: Radius.md, style: .continuous))
          SuggestionRow(title: title, subtitle: subtitle)
          Spacer(minLength: 0)
        }
        .padding(Spacing.space3)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
    }
  }
#endif

#if os(macOS)
  private struct MacSuggestions: View {
    @Binding var query: String
    @State private var selection = "session.revoked"

    var body: some View {
      VStack(alignment: .leading, spacing: Spacing.space2) {
        ShadowSearchField("Search events", text: $query, clearLabel: "Clear search")
          .frame(maxWidth: 280)
        List(selection: $selection) {
          Section("Event types") {
            Label("session.revoked", systemImage: "key").tag("session.revoked")
            Label("session.refreshed", systemImage: "key").tag("session.refreshed")
          }
          Section("Recent") {
            Label("template:welcome-email", systemImage: "clock").tag("template")
          }
        }
        .frame(width: 280, height: 190)
        .clipShape(.rect(cornerRadius: Radius.lg, style: .continuous))
        .shadowElevation(.e2)
      }
    }
  }
#endif

private struct SearchSampleSheet: View {
  enum Scope: Hashable { case all, novels, chapters }
  enum SearchToken: String, Identifiable, Hashable, CaseIterable {
    case reading = "Reading"
    case saved = "Saved"
    var id: Self { self }
  }

  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var tokens: [SearchToken] = []
  @State private var scope = Scope.all
  @State private var isSearching = false

  private var results: [CatalogBook] {
    guard !query.isEmpty else { return CatalogBook.shelf }
    return CatalogBook.shelf.filter { $0.title.localizedCaseInsensitiveContains(query) }
  }

  var body: some View {
    NavigationStack {
      List(results) { book in
        SuggestionRow(title: LocalizedStringKey(book.title), subtitle: LocalizedStringKey(book.progress))
      }
      .navigationTitle("Library")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
      }
      .searchable(text: $query, tokens: $tokens, isPresented: $isSearching, prompt: "Search the library") { token in
        Text(token.rawValue)
      }
      .searchScopes($scope) {
        Text("All").tag(Scope.all)
        Text("Novels").tag(Scope.novels)
        Text("Chapters").tag(Scope.chapters)
      }
      .searchSuggestions {
        Text("The Glass Stair").searchCompletion("The Glass Stair")
        Text("Glass and Ash").searchCompletion("Glass and Ash")
        Text("Reading").searchCompletion(SearchToken.reading)
      }
    }
    #if os(macOS)
      .frame(minWidth: 420, minHeight: 360)
    #endif
  }
}
