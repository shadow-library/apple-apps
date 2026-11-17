import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

struct StatTile: View {
  enum Reading {
    case value(Text, caption: Text?)
    case unavailable(String)
  }

  let title: Text
  let reading: Reading
  let destination: NovelSection?
  @Environment(NovelNavigator.self) private var navigator: NovelNavigator?

  var body: some View {
    if let destination {
      Button {
        navigator?.show(destination)
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
    _ title: Text, _ derived: Derived<Value>, opens destination: NovelSection? = nil, value: (Value) -> Text, caption: (Value) -> Text? = { _ in nil }
  ) {
    self.title = title
    self.destination = destination
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
