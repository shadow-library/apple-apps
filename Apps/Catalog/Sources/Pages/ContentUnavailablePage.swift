import ShadowDesignSystem
import SwiftUI

struct ContentUnavailablePage: View {
  var body: some View {
    ComponentPage(component: .contentUnavailable) {
      StateSection("Empty", note: "A large text-tertiary symbol, the fact as the title, the next step as the description and at most one action.") {
        Region {
          ShadowContentUnavailable("No quests yet", kind: .empty, message: "Create your first quest and it will show up here.") {
            Button {
            } label: {
              Label("New quest", systemImage: "plus")
            }
          }
        }
      }
      StateSection("Access denied", note: "A secondary action is bordered, so the one filled action on a screen stays the primary one.") {
        Region {
          ShadowContentUnavailable("You don’t have access", kind: .accessDenied, message: "Ask an admin of Shadow Library to give you the editor role.") {
            Button("Request access") {}.buttonStyle(.shadowBordered)
          }
        }
      }
      StateSection("Error", note: "Say what failed, then what to do. Reassure where the choice is reversible.") {
        Region {
          ShadowContentUnavailable("That page doesn’t exist or has moved", kind: .error, message: "Go back to your library, or search for the chapter you were reading.") {
            Button("Go to your library") {}.buttonStyle(.shadowTinted)
          }
        }
      }
      StateSection("Search with the system view", note: "`ContentUnavailableView.search(text:)` supplies the system wording; its title is the system’s own capitalisation.") {
        Region {
          ContentUnavailableView.search(text: "glass st")
        }
      }
      StateSection("No results with Shadow copy", note: "The wrapper keeps sentence case and names the next step.") {
        Region {
          ShadowContentUnavailable("No results for “glass st”", kind: .noResults, message: "Check the spelling or try a new search.")
        }
      }
      StateSection("Compact", note: "In a small region the view shrinks to its content and centres.") {
        ShadowContentUnavailable("No notifications", kind: .empty, systemImage: "bell", message: "You’re all caught up.")
          .frame(maxWidth: .infinity, minHeight: 160)
          .shadowCard()
      }
      StateSection("Long text", note: "The description wraps inside a readable width; nothing truncates.") {
        Region {
          ShadowContentUnavailable(
            "No chapters match these filters", kind: .noResults,
            message:
              "Remove a filter, widen the date range or switch to All genres to see every chapter you have access to in Shadow Library, including drafts you shared with your team."
          ) {
            Button("Clear filters") {}.buttonStyle(.shadowTinted)
          }
        }
      }
      StateSection("Light and dark") {
        SchemePair {
          ShadowContentUnavailable("No quests yet", kind: .empty, message: "Create your first quest and it will show up here.") {
            Button {
            } label: {
              Label("New quest", systemImage: "plus")
            }
          }
        }
      }
    }
  }
}

private struct Region<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    content
      .frame(maxWidth: .infinity, minHeight: 240)
      .shadowCard()
  }
}
