import SwiftUI

nonisolated public enum ShadowRowActionKind: Hashable, Sendable, CaseIterable {
  case accent
  case warning
  case neutral
  case destructive

  public var token: ShadowColorToken {
    switch self {
    case .accent: .accent
    case .warning: .warningSolidStrong
    case .neutral: .neutralSolidStrong
    case .destructive: .dangerSolid
    }
  }
}

public struct ShadowRowAction: Identifiable {
  public let id: String
  public let title: LocalizedStringKey
  public let systemImage: String
  public let kind: ShadowRowActionKind
  public let shortcut: KeyboardShortcut?
  public let perform: @MainActor () -> Void

  public init(
    id: String, title: LocalizedStringKey, systemImage: String, kind: ShadowRowActionKind = .accent, shortcut: KeyboardShortcut? = nil,
    perform: @escaping @MainActor () -> Void
  ) {
    self.id = id
    self.title = title
    self.systemImage = systemImage
    self.kind = kind
    self.shortcut = shortcut
    self.perform = perform
  }
}

nonisolated public enum ShadowRowActionLayout {
  public static let maximumLeading = 1
  public static let maximumTrailing = 3

  public static func leading<Action>(_ actions: [Action], kind: (Action) -> ShadowRowActionKind) -> [Action] {
    Array(actions.filter { kind($0) != .destructive }.prefix(maximumLeading))
  }

  public static func trailing<Action>(_ actions: [Action], kind: (Action) -> ShadowRowActionKind) -> [Action] {
    let destructive = actions.filter { kind($0) == .destructive }
    let others = actions.filter { kind($0) != .destructive }
    return Array((destructive + others).prefix(maximumTrailing))
  }

  public static func menu<Action>(leading: [Action], trailing: [Action], kind: (Action) -> ShadowRowActionKind) -> (safe: [Action], destructive: [Action]) {
    let all = leading + trailing
    return (all.filter { kind($0) != .destructive }, all.filter { kind($0) == .destructive })
  }
}

private struct ShadowRowActionsModifier: ViewModifier {
  let leading: [ShadowRowAction]
  let trailing: [ShadowRowAction]
  let allowsFullSwipe: Bool

  func body(content: Content) -> some View {
    let menu = ShadowRowActionLayout.menu(leading: leading, trailing: trailing, kind: \.kind)
    content
      .swipeActions(edge: .leading, allowsFullSwipe: allowsFullSwipe) { buttons(leading) }
      .swipeActions(edge: .trailing, allowsFullSwipe: allowsFullSwipe) { buttons(trailing) }
      .contextMenu {
        ForEach(menu.safe) { button(for: $0) }
        if !menu.destructive.isEmpty && !menu.safe.isEmpty { Divider() }
        ForEach(menu.destructive) { button(for: $0) }
      }
  }

  private func buttons(_ actions: [ShadowRowAction]) -> some View {
    ForEach(actions) { action in
      Button(role: action.kind == .destructive ? .destructive : nil) {
        action.perform()
      } label: {
        Label(action.title, systemImage: action.systemImage)
      }
      .tint(action.kind.token.color)
    }
  }

  @ViewBuilder
  private func button(for action: ShadowRowAction) -> some View {
    let base = Button(role: action.kind == .destructive ? .destructive : nil) {
      action.perform()
    } label: {
      Label(action.title, systemImage: action.systemImage)
    }
    if let shortcut = action.shortcut {
      base.keyboardShortcut(shortcut)
    } else {
      base
    }
  }
}

extension View {
  public func shadowRowActions(leading: [ShadowRowAction] = [], trailing: [ShadowRowAction] = [], allowsFullSwipe: Bool = true) -> some View {
    modifier(
      ShadowRowActionsModifier(
        leading: ShadowRowActionLayout.leading(leading, kind: \.kind),
        trailing: ShadowRowActionLayout.trailing(trailing, kind: \.kind),
        allowsFullSwipe: allowsFullSwipe
      )
    )
  }
}
