import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

struct StatTile: View {
  enum Reading {
    case value(Text, caption: Text?)
    case unavailable(String)
  }

  struct Opening {
    let perform: @MainActor (NovelNavigator) -> Void

    static func section(_ section: NovelSection) -> Opening {
      Opening { $0.show(section) }
    }

    static func route(_ section: NovelSection, _ route: some Hashable) -> Opening {
      Opening { $0.open(section, route) }
    }
  }

  let title: Text
  let reading: Reading
  let opening: Opening?
  @Environment(NovelNavigator.self) private var navigator: NovelNavigator?

  var body: some View {
    if let opening {
      Button {
        if let navigator { opening.perform(navigator) }
      } label: {
        tile
      }.buttonStyle(.plain)
    } else {
      tile
    }
  }

  @ViewBuilder
  private var tile: some View {
    switch reading {
    case .value(let value, let caption):
      ShadowStatistic(title, value: value, caption: caption)
    case .unavailable(let reason):
      ShadowStatistic(
        title, value: Text("Unavailable", tableName: "Library").foregroundStyle(ShadowColor.warningText),
        caption: Text("Not up to date on this device", tableName: "Library").foregroundStyle(ShadowColor.warningText)
      )
      .help(Text(verbatim: reason))
    }
  }
}

extension StatTile {
  init<Value: Sendable & Equatable>(
    _ title: Text, _ derived: Derived<Value>, opens section: NovelSection, deepLink: (Value) -> Opening? = { _ in nil }, value: (Value) -> Text,
    caption: (Value) -> Text? = { _ in nil }
  ) {
    self.title = title
    opening = derived.value.flatMap(deepLink) ?? .section(section)
    reading = Reading(derived, value: value, caption: caption)
  }
}

extension StatTile.Reading {
  init<Value: Sendable & Equatable>(_ derived: Derived<Value>, value: (Value) -> Text, caption: (Value) -> Text? = { _ in nil }) {
    switch derived {
    case .available(let content): self = .value(value(content), caption: caption(content))
    case .unavailable(let faults): self = .unavailable(faults.first?.message ?? "")
    }
  }
}
