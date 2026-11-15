import ShadowDesignSystem
import SwiftUI

struct SegmentedControlPage: View {
  enum Shelf: String, CaseIterable, Identifiable {
    case reading = "Reading"
    case saved = "Saved"
    case finished = "Finished"
    var id: Self { self }
  }

  enum Layout: String, CaseIterable, Identifiable {
    case list
    case grid
    var id: Self { self }
    var symbol: String { self == .list ? "list.bullet" : "square.grid.2x2" }
    var label: LocalizedStringKey { self == .list ? "List" : "Grid" }
  }

  enum Range: String, CaseIterable, Identifiable {
    case day = "Day"
    case week = "Week"
    case month = "Month"
    case year = "Year"
    var id: Self { self }
  }

  enum Channel: String, CaseIterable, Identifiable {
    case outcome = "Outcome"
    case channel = "Channel"
    var id: Self { self }
  }

  @State private var shelf = Shelf.reading
  @State private var savedShelf = Shelf.saved
  @State private var layout = Layout.grid
  @State private var range = Range.week
  @State private var channel = Channel.outcome
  @State private var long = Shelf.reading

  var body: some View {
    ComponentPage(component: .segmentedControl) {
      StateSection("Labels", note: "Two to five mutually exclusive views of the same content. The system draws the track and the selected thumb.") {
        VStack(alignment: .leading, spacing: Spacing.space4) {
          Picker("Shelf", selection: $shelf) {
            ForEach(Shelf.allCases) { Text($0.rawValue).tag($0) }
          }
          Picker("Shelf", selection: $savedShelf) {
            ForEach(Shelf.allCases) { Text($0.rawValue).tag($0) }
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .catalogSegmentedWidth()
        .shadowCard()
      }
      StateSection("Symbols only", note: "Icon-only segments still carry an accessibility label.") {
        Picker("Layout", selection: $layout) {
          ForEach(Layout.allCases) { item in
            Image(systemName: item.symbol).accessibilityLabel(item.label).tag(item)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .catalogSegmentedWidth()
        .shadowCard()
      }
      #if os(macOS)
        StateSection("Toolbar and table headers", note: "Mac segmented controls sit in toolbars and above tables, at home with two to four short labels.") {
          VStack(alignment: .leading, spacing: Spacing.space3) {
            Picker("Range", selection: $range) {
              ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Group by", selection: $channel) {
              ForEach(Channel.allCases) { Text($0.rawValue).tag($0) }
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .fixedSize()
          .shadowCard()
        }
      #endif
      StateSection("Long labels", note: "Labels truncate rather than wrap; keep them to one or two words of similar length.") {
        Picker("Notification level", selection: $long) {
          Text("Everything new").tag(Shelf.reading)
          Text("Only chapters from followed novels").tag(Shelf.saved)
          Text("Nothing").tag(Shelf.finished)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .shadowCard()
      }
      StateSection("Disabled") {
        Picker("Shelf", selection: $shelf) {
          ForEach(Shelf.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(true)
        .catalogSegmentedWidth()
        .shadowCard()
      }
    }
  }
}

extension View {
  fileprivate func catalogSegmentedWidth() -> some View {
    frame(maxWidth: 400, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
  }
}
