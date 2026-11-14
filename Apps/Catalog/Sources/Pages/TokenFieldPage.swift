@_spi(Preview) import ShadowDesignSystem
import SwiftUI

struct TokenFieldPage: View {
  @State private var eventTypes = ["user.created", "session.revoked"]
  @State private var eventQuery = "role.gr"
  @State private var suggestedEvents = ["user.created"]
  @State private var suggestedQuery = "role"
  @State private var emptyTags: [String] = []
  @State private var manyTags = ["fantasy", "found family", "slow burn", "magic academy", "political intrigue", "morally grey", "archives", "glass magic"]
  @State private var selectedTags = ["fantasy", "found family", "slow burn"]
  @State private var limitedGenres: [Genre] = [.fantasy, .mystery, .romance]
  @State private var genres: [Genre] = [.fantasy]
  @State private var invalidGenres: [Genre] = []
  @State private var longTags = ["the-ninth-archive.chapter-42.the-glass-stair.annotations", "mira"]
  @State private var disabledTags = ["fantasy", "archives"]
  @State private var isShowingSearch = false

  var body: some View {
    ComponentPage(component: .tokenField) {
      StateSection(
        "Event types", note: "Tokens are accent-soft capsules with a remove button. Return or a comma commits the text; Backspace selects, then removes, the last token."
      ) {
        FieldStack {
          TokenRow(title: "Event types", help: "Receive audit events at an https endpoint you control.") {
            ShadowTokenField("Event types", tokens: $eventTypes, text: $eventQuery, removeLabel: removeLabel)
              .shadowPreviewFieldFocus(true)
          }
        }
      }
      StateSection("Suggestions", note: "Completions filter as people type; prefix matches come first and existing tokens are left out. Arrow keys move through them.") {
        FieldStack {
          TokenRow(title: "Event types") {
            ShadowTokenField(
              "Event types", tokens: $suggestedEvents, text: $suggestedQuery, suggestions: AuditEvent.all, removeLabel: removeLabel
            )
            .shadowPreviewFieldFocus(true)
          }
        }
      }
      StateSection("Empty", note: "The placeholder names what to add.") {
        FieldStack {
          TokenRow(title: "Tags") {
            ShadowTokenField("Tags", tokens: $emptyTags, prompt: Text("Add a tag"), suggestions: Tag.all, removeLabel: removeLabel)
          }
        }
      }
      StateSection("Many tokens", note: "Tokens wrap onto new lines and the field grows; the text entry fills the rest of the last line.") {
        FieldStack {
          TokenRow(title: "Tags") {
            ShadowTokenField("Tags", tokens: $manyTags, suggestions: Tag.all, removeLabel: removeLabel)
          }
        }
      }
      StateSection("Selected token", note: "The first Backspace on empty text selects the last token; the second removes it. Clicking a token selects it too.") {
        FieldStack {
          TokenRow(title: "Tags") {
            ShadowTokenField("Tags", tokens: $selectedTags, removeLabel: removeLabel)
              .shadowPreviewFieldFocus(true)
              .shadowPreviewTokenSelection(2)
          }
        }
      }
      StateSection("Closed set", note: "Typed values only become tokens when they match a genre. Duplicates are rejected without regard to case.") {
        FieldStack {
          TokenRow(title: "Genres", help: "Up to three.") {
            ShadowTokenField("Genres", tokens: $genres, prompt: Text("Add a genre"), suggestions: Genre.allCases, rules: Genre.rules) { genre in
              Text("Remove \(genre.title)")
            }
          }
        }
      }
      StateSection("Error", note: "The field takes the error ring and the message says how to fix it.") {
        FieldStack {
          TokenRow(title: "Genres") {
            ShadowTokenField("Genres", tokens: $invalidGenres, prompt: Text("Add a genre"), suggestions: Genre.allCases, rules: Genre.rules) { genre in
              Text("Remove \(genre.title)")
            }
            .shadowValidation(Text("Add at least one genre so readers can find this novel."))
          }
          TokenRow(title: "Genres") {
            ShadowTokenField("Genres", tokens: $limitedGenres, suggestions: Genre.allCases, rules: Genre.rules) { genre in
              Text("Remove \(genre.title)")
            }
            .shadowValidation(Text("Choose up to three genres."))
          }
        }
      }
      StateSection("Long token", note: "A token never wraps; the middle truncates so both ends stay recognisable.") {
        FieldStack {
          TokenRow(title: "Tags") {
            ShadowTokenField("Tags", tokens: $longTags, removeLabel: removeLabel)
          }
        }
      }
      StateSection("Disabled") {
        FieldStack {
          TokenRow(title: "Tags") {
            ShadowTokenField("Tags", tokens: $disabledTags, removeLabel: removeLabel)
              .disabled(true)
          }
        }
      }
      StateSection("In navigation search", note: "To filter a screen by tokens, use the system search field with .searchable(text:tokens:) instead.") {
        Button("Try search tokens", systemImage: "magnifyingglass") { isShowingSearch = true }
          .buttonStyle(.shadowTinted)
          .sheet(isPresented: $isShowingSearch) { SearchSampleSheet() }
      }
    }
  }

  private func removeLabel(_ token: String) -> Text {
    Text("Remove \(token)")
  }
}

private struct TokenRow<Field: View>: View {
  let title: LocalizedStringKey
  var help: LocalizedStringKey?
  @ViewBuilder let field: Field

  var body: some View {
    #if os(macOS)
      LabeledContent {
        VStack(alignment: .leading, spacing: Spacing.space1) {
          field
          if let help {
            Text(help).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
          }
        }
      } label: {
        Text(title).foregroundStyle(ShadowColor.textSecondary)
      }
    #else
      FieldRow(title: title, help: help) { field }
    #endif
  }
}

private enum AuditEvent {
  static let all = [
    "user.created", "user.deleted", "user.role.changed", "session.created", "session.revoked", "role.granted", "role.revoked", "role.created",
  ]
}

private enum Tag {
  static let all = ["fantasy", "found family", "slow burn", "enemies to lovers", "magic academy", "political intrigue", "morally grey", "archives"]
}

nonisolated private enum Genre: String, CaseIterable, Hashable, Sendable {
  case fantasy
  case mystery
  case romance
  case scienceFiction
  case horror
  case literary

  var title: String {
    switch self {
    case .fantasy: "Fantasy"
    case .mystery: "Mystery"
    case .romance: "Romance"
    case .scienceFiction: "Science fiction"
    case .horror: "Horror"
    case .literary: "Literary"
    }
  }

  static let rules = ShadowTokenRules<Genre>(
    label: \.title,
    parse: { text in Genre.allCases.first { $0.title.localizedCaseInsensitiveCompare(text) == .orderedSame } },
    maximumCount: 3
  )
}
