import ShadowDesignSystem
import SwiftUI

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

extension View {
  /// Hides a secret while the scene is not in front (so the app switcher's snapshot never shows it) and, on iPhone and iPad, while the screen is
  /// being recorded or mirrored. The view stays alive underneath, so nothing typed is lost.
  func concealedWhileInactive() -> some View {
    modifier(ConcealedWhileInactive())
  }
}

private struct ConcealedWhileInactive: ViewModifier {
  @Environment(\.appIdentity) private var app
  @Environment(\.scenePhase) private var scenePhase
  #if os(iOS)
    @Environment(\.isSceneCaptured) private var isCaptured
  #else
    private let isCaptured = false
  #endif

  private var isConcealed: Bool { scenePhase != .active || isCaptured }

  func body(content: Content) -> some View {
    content
      .privacySensitive()
      .opacity(isConcealed ? 0 : 1)
      .accessibilityHidden(isConcealed)
      .overlay {
        if isConcealed {
          Label {
            Text("Hidden while \(app.displayName) is not in front", tableName: "SyncKeys", bundle: .module)
          } icon: {
            Image(systemName: "eye.slash")
          }
          .shadowFont(.footnote)
          .foregroundStyle(ShadowColor.textSecondary)
        }
      }
  }
}

/// Copies an exchange code's text, for a device that cannot scan; the text carries a one-time public key or keys sealed to one, never a key in the clear.
struct KeyCodeCopyButton: View {
  let payload: String
  @State private var isCopied = false

  var body: some View {
    Button {
      #if os(iOS)
        UIPasteboard.general.string = payload
      #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
      #endif
      isCopied = true
    } label: {
      Label {
        isCopied ? Text("Copied", tableName: "SyncKeys", bundle: .module) : Text("Copy Code as Text", tableName: "SyncKeys", bundle: .module)
      } icon: {
        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
      }
    }
    .buttonStyle(.shadowBordered)
  }
}

struct KeyFlowSection<Content: View, Footer: View>: View {
  let title: Text
  let failure: PresentedError?
  @ViewBuilder let content: Content
  @ViewBuilder let footer: Footer

  var body: some View {
    ShadowGroupedSection {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        if let failure { ShadowValidationMessage(failure.text) }
        content
        HStack(spacing: Spacing.space2) { footer }
      }
      .padding(Spacing.space3)
    } header: {
      title.shadowFont(.headline)
    }
  }
}

struct KeyFlowProgress: View {
  let text: Text

  var body: some View {
    HStack(spacing: Spacing.space2) {
      ProgressView().controlSize(.small)
      text.shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
    }
  }
}
