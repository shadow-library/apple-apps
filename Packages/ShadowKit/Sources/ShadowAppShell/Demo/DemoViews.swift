import ShadowDesignSystem
import SwiftUI

/// How a screen enters the demo; nil while the demo runs, so nothing offers it again.
public struct DemoEntry {
  public let isEntering: Bool
  public let enter: @MainActor () -> Void

  public init(isEntering: Bool, enter: @escaping @MainActor () -> Void) {
    self.isEntering = isEntering
    self.enter = enter
  }
}

extension EnvironmentValues {
  @Entry public var demoEntry: DemoEntry?
}

/// "Try the Demo", shown only where `demoSession(_:identity:)` offers the demo.
public struct TryDemoButton: View {
  @Environment(\.demoEntry) private var entry

  public init() {}

  public var body: some View {
    if let entry {
      Button {
        entry.enter()
      } label: {
        Label {
          Text("Try the Demo", tableName: "Demo", bundle: .module)
        } icon: {
          Image(systemName: "play.circle")
        }
      }
      .disabled(entry.isEntering)
    }
  }
}

/// The demo's offer as a section of its own, for a settings screen.
public struct TryDemoSection: View {
  private let identity: AppIdentity
  @Environment(\.demoEntry) private var entry

  public init(identity: AppIdentity) {
    self.identity = identity
  }

  public var body: some View {
    if entry != nil {
      ShadowGroupedSection {
        VStack(alignment: .leading, spacing: Spacing.space2) {
          Text(
            "See \(identity.displayName) at work on sample content, with answers scripted on this device. No key is used, and your own data and keys are not touched.",
            tableName: "Demo", bundle: .module
          )
          .shadowFont(.footnote)
          .foregroundStyle(ShadowColor.textSecondary)
          TryDemoButton()
        }
        .padding(Spacing.space3)
      } header: {
        Text("Try without a key", tableName: "Demo", bundle: .module).shadowFont(.headline)
      }
      .appIdentity(identity)
    }
  }
}

/// The bar shown above everything while the demo runs, with the way out of it; stacked at accessibility text sizes.
public struct DemoBanner: View {
  private let identity: AppIdentity
  private let leave: () -> Void
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var isConfirming = false

  public init(identity: AppIdentity, leave: @escaping () -> Void) {
    self.identity = identity
    self.leave = leave
  }

  public var body: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: Spacing.space2) {
          badge
          note
          leaveButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        HStack(spacing: Spacing.space3) {
          badge
          note.lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
          leaveButton
        }
      }
    }
    .padding(.horizontal, Spacing.space4)
    .padding(.vertical, Spacing.space2)
    .background(ShadowColor.surfaceRaised)
    .overlay(alignment: .bottom) { ShadowColor.borderSubtle.frame(height: 1) }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("demo-banner")
    .confirmationDialog(Text("Leave the demo?", tableName: "Demo", bundle: .module), isPresented: $isConfirming, titleVisibility: .visible) {
      Button(role: .destructive, action: leave) {
        Text("Leave Demo", tableName: "Demo", bundle: .module)
      }
    } message: {
      Text("Everything made in the demo is deleted, and \(identity.displayName) opens your own data as you left it.", tableName: "Demo", bundle: .module)
    }
    .appIdentity(identity)
  }

  private var badge: some View {
    ShadowBadge(Text("Demo", tableName: "Demo", bundle: .module), intent: .accent, systemImage: "play.circle")
  }

  private var note: some View {
    Text("Sample content with scripted answers. Nothing here is kept.", tableName: "Demo", bundle: .module)
      .shadowFont(.footnote)
      .foregroundStyle(ShadowColor.textSecondary)
  }

  private var leaveButton: some View {
    Button {
      isConfirming = true
    } label: {
      Text("Leave Demo", tableName: "Demo", bundle: .module)
    }
    .buttonStyle(ShadowButtonStyle(.bordered))
    .controlSize(.small)
  }
}

extension View {
  /// Offers the demo to the screens inside (`TryDemoButton`, `TryDemoSection`) while it is off, and shows `DemoBanner` above them while it runs.
  public func demoSession<Demo>(_ session: DemoSession<Demo>, identity: AppIdentity) -> some View {
    modifier(DemoSessionChrome(session: session, identity: identity))
  }

  /// Only offers the demo to the screens inside, as a Settings window does beside the window that shows the banner.
  public func demoOffer<Demo>(_ session: DemoSession<Demo>) -> some View {
    environment(\.demoEntry, session.entry)
  }
}

extension DemoSession {
  var entry: DemoEntry? {
    switch state {
    case .off: DemoEntry(isEntering: false) { Task { await self.enter() } }
    case .entering: DemoEntry(isEntering: true) {}
    case .on, .leaving: nil
    }
  }
}

private struct DemoSessionChrome<Demo>: ViewModifier {
  let session: DemoSession<Demo>
  let identity: AppIdentity

  /// A stack rather than a top safe-area inset: a navigation stack's bar ignores the inset on iOS 26 and draws its buttons under the banner.
  func body(content: Content) -> some View {
    VStack(spacing: 0) {
      if session.active != nil {
        DemoBanner(identity: identity) { Task { await session.leave() } }
      }
      content.demoOffer(session)
    }
    .alert(
      Text("The demo could not start", tableName: "Demo", bundle: .module), isPresented: Binding(get: { session.failure != nil }, set: { if !$0 { session.failure = nil } })
    ) {
      Button {
        session.failure = nil
      } label: {
        Text("OK", tableName: "Demo", bundle: .module)
      }
    } message: {
      Text(verbatim: session.failure?.localizedDescription ?? "")
    }
  }
}
