import SwiftUI

// iPadOS reports `.increased` prominence only to the cells of the keyboard-focused row, not to rows selected in code or further rows of a multiple selection.
nonisolated struct ShadowTableSelectionBand: Equatable {
  let selection: AnyHashable
  let isAccent: Bool

  init<ID: Hashable>(selection: Set<ID>, isFocused: Bool, appearsActive: Bool) {
    self.selection = AnyHashable(selection)
    isAccent = isFocused && appearsActive
  }

  func isOnBand<ID: Hashable>(row id: ID) -> Bool {
    guard isAccent, let selection = selection.base as? Set<ID> else { return false }
    return selection.contains(id)
  }
}

nonisolated extension EnvironmentValues {
  @Entry var shadowTableSelectionBand: ShadowTableSelectionBand?
  @Entry var shadowTableRowIsOnSelectionBand = false

  var shadowSelectionProminence: BackgroundProminence {
    shadowTableRowIsOnSelectionBand ? .increased : backgroundProminence
  }
}

struct ShadowTableSelectionTracking<ID: Hashable>: ViewModifier {
  let selection: Binding<Set<ID>>

  @FocusState private var isFocused: Bool
  @Environment(\.appearsActive) private var appearsActive

  func body(content: Content) -> some View {
    #if os(macOS)
      content
    #else
      content
        .focused($isFocused)
        .environment(
          \.shadowTableSelectionBand, ShadowTableSelectionBand(selection: selection.wrappedValue, isFocused: isFocused, appearsActive: appearsActive))
    #endif
  }
}

struct ShadowTableRowCell<ID: Hashable>: ViewModifier {
  let id: ID

  @Environment(\.shadowTableSelectionBand) private var band

  func body(content: Content) -> some View {
    content.environment(\.shadowTableRowIsOnSelectionBand, band?.isOnBand(row: id) ?? false)
  }
}
