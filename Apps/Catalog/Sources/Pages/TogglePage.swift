import ShadowDesignSystem
import SwiftUI

struct TogglePage: View {
  @State private var chapterUpdates = true
  @State private var questReminder = false
  @State private var spoilerWikis = true
  @State private var longLabel = true
  @State private var grantsRole = true
  @State private var requireStepUp = false
  @State private var events = [
    EventType(name: "session.revoked", isOn: true), EventType(name: "session.refreshed", isOn: true), EventType(name: "template.sent", isOn: true),
    EventType(name: "invite.accepted", isOn: false),
  ]

  struct EventType: Identifiable {
    let name: String
    var isOn: Bool
    var id: String { name }
  }

  var body: some View {
    ComponentPage(component: .toggle) {
      StateSection("Switch", note: "The system switch, tinted with accent instead of green. The knob moves, so state never depends on colour alone.") {
        FormBlock {
          FormSection {
            Toggle(isOn: $chapterUpdates) { ShadowRowLabel("Chapter updates", subtitle: "When a novel in your library gets a new chapter") }
            Toggle(isOn: $questReminder) { ShadowRowLabel("Daily quest reminder") }
            Toggle(isOn: $spoilerWikis) { ShadowRowLabel("Spoiler wikis", subtitle: "Locked while you read") }
              .disabled(true)
            Toggle(isOn: .constant(false)) { ShadowRowLabel("Offline downloads", subtitle: "Needs a Library Plus subscription") }
              .disabled(true)
          } footer: {
            Text("Notifications are sent through Pulse.")
          }
        }
        #if os(macOS)
          .toggleStyle(.switch)
        #endif
      }
      StateSection("Long label", note: "Labels wrap onto as many lines as they need. The switch stays vertically centred in the row, as it does in Settings.") {
        FormBlock {
          FormSection {
            Toggle(isOn: $longLabel) {
              ShadowRowLabel("Notify me about every new chapter, wiki edit and author’s note from the novels I follow", subtitle: "You can mute a single novel from its page")
            }
          }
        }
        #if os(macOS)
          .toggleStyle(.switch)
        #endif
      }
      #if os(macOS)
        StateSection("Checkbox", note: "Options in forms and lists use checkboxes, including the mixed state when a group is partly on.") {
          VStack(alignment: .leading, spacing: Spacing.space3) {
            Toggle("Grants the role to every member of the organization", isOn: $grantsRole)
            Toggle("Require step-up for admin actions", isOn: $requireStepUp)
            Toggle("Disabled option", isOn: .constant(true)).disabled(true)
            Toggle(sources: $events, isOn: \.isOn) { Text("All event types (3 of 4)") }
            VStack(alignment: .leading, spacing: Spacing.space2) {
              ForEach($events) { $event in
                Toggle(event.name, isOn: $event.isOn)
              }
            }
            .padding(.leading, Spacing.space5)
          }
          .toggleStyle(.checkbox)
          .shadowCard()
        }
      #endif
    }
  }
}
