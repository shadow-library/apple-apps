import ShadowDesignSystem
import SwiftUI

struct PickerPage: View {
  enum Mode: String, CaseIterable, Identifiable {
    case reader = "Reader"
    case listener = "Listener"
    case author = "Author"
    var id: Self { self }
  }

  enum Channel: String, CaseIterable, Identifiable {
    case email = "Email"
    case push = "Push"
    case sms = "SMS"
    var id: Self { self }
  }

  enum Expiry: String, CaseIterable, Identifiable {
    case hour = "1 hour"
    case day = "1 day"
    case week = "7 days"
    case never = "Never"
    var id: Self { self }
  }

  enum Zone: String, CaseIterable, Identifiable {
    case london = "London"
    case lisbon = "Lisbon"
    case berlin = "Berlin"
    case cairo = "Cairo"
    var id: Self { self }
  }

  @State private var mode = Mode.reader
  @State private var channel = Channel.email
  @State private var expiry = Expiry.hour
  @State private var zone = Zone.london
  @State private var disabledChannel = Channel.push

  var body: some View {
    ComponentPage(component: .picker) {
      StateSection("Menu", note: "For up to about ten options where the current value matters more than the alternatives. The value is accent text with the up-down chevrons.") {
        FormBlock {
          FormSection {
            Picker("Content mode", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
            Picker("Channel", selection: $channel) { ForEach(Channel.allCases) { Text($0.rawValue).tag($0) } }
          }
        }
        .pickerStyle(.menu)
      }
      StateSection("Inline and radio group", note: "Two to five options people should compare: checkmark rows on iPhone and iPad, a radio group on Mac.") {
        FormBlock {
          FormSection {
            #if os(macOS)
              Picker("Expires after", selection: $expiry) { ForEach(Expiry.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.radioGroup)
            #else
              Picker("Expires after", selection: $expiry) { ForEach(Expiry.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.inline)
                .labelsHidden()
            #endif
          } header: {
            #if !os(macOS)
              Text("Expires after")
            #endif
          } footer: {
            Text("Shared links stop working after this.")
          }
        }
      }
      StateSection("Navigation link", note: "Long lists such as countries and time zones push a screen of checkmarks.") {
        FormBlock {
          FormSection {
            Picker("Time zone", selection: $zone) { ForEach(Zone.allCases) { Text($0.rawValue).tag($0) } }
              #if !os(macOS)
                .pickerStyle(.navigationLink)
              #endif
          }
        }
      }
      StateSection("Disabled") {
        FormBlock {
          FormSection {
            Picker("Channel", selection: $disabledChannel) { ForEach(Channel.allCases) { Text($0.rawValue).tag($0) } }
              .disabled(true)
          }
        }
      }
      StateSection("Long label", note: "The title wraps; the value keeps its place.") {
        FormBlock {
          FormSection {
            Picker("Where should we send a summary of everything new in your library", selection: $channel) {
              ForEach(Channel.allCases) { Text($0.rawValue).tag($0) }
            }
          }
        }
      }
    }
  }
}
