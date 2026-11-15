import ShadowDesignSystem
import SwiftUI

struct ToastPage: View {
  @State private var center = ShadowToastCenter()

  var body: some View {
    ComponentPage(component: .toast) {
      StateSection(
        "Over content",
        note: "iPhone and iPad: a glass capsule under the status bar for about four seconds. Mac: a smaller capsule at the bottom centre of the window."
      ) {
        PresentationBackdrop(alignment: ShadowDensity.current == .touch ? .top : .bottom) {
          ShadowToastView(DemoToast.saved)
        }
      }
      StateSection(
        "Try it",
        note:
          "One toast at a time; the next waits until the current one leaves. The time grows with the text, doubles with VoiceOver, and pauses while the toast is hovered or focused. Swipe toward the edge to dismiss."
      ) {
        ShadowFlowLayout(spacing: Spacing.space2, lineSpacing: Spacing.space2) {
          Button("Save to library") { center.show(DemoToast.saved) }
          Button("Delete chapter") { center.show(DemoToast.deleted(center: center)) }
          Button("Go offline") { center.show(DemoToast.offline) }
          Button("Back online") { center.dismiss(id: DemoToast.offline.id) }
          Button("Queue three") {
            center.show(DemoToast.saved)
            center.show(DemoToast.deleted(center: center))
            center.show(DemoToast.published)
          }
        }
        .buttonStyle(.shadowBordered)
      }
      StateSection("Undo", note: "Offer Undo whenever the action can be reversed; the toast stays longer so people can reach it.") {
        ShadowToastView(DemoToast.deleted(center: center), onDismiss: {})
      }
      StateSection("Persistent state", note: "Offline stays as a capsule until the connection comes back.") {
        ShadowToastView(DemoToast.offline)
      }
      StateSection("Dismiss button", note: "Long-lived toasts get an explicit close button; all toasts can be swiped away.") {
        ShadowToastView(DemoToast.published, onDismiss: {})
      }
      StateSection("Long text", note: "Long messages wrap instead of truncating; the capsule turns into a rounded panel.") {
        ShadowToastView(DemoToast.long, onDismiss: {})
      }
      StateSection("Light and dark") {
        SchemePair {
          VStack(alignment: .leading, spacing: Spacing.space2) {
            ShadowToastView(DemoToast.saved)
            ShadowToastView(DemoToast.offline)
          }
        }
      }
    }
    .shadowToastPresenter(center)
    .catalogAutoPresent {
      center.show(ShadowToast("Saved to your library", systemImage: "checkmark.circle", intent: .success, duration: .persistent, id: "presented"))
    }
  }
}

private enum DemoToast {
  static let saved = ShadowToast("Saved to your library", systemImage: "checkmark.circle", intent: .success)

  static let offline = ShadowToast("Offline · changes sync later", systemImage: "clock", duration: .persistent, id: "offline")

  static let published = ShadowToast("Chapter 42 is scheduled for Friday", systemImage: "calendar", dismissLabel: "Dismiss")

  static let long = ShadowToast(
    "Chapter 42 was published to Web Novel. Readers who follow The Ninth Archive get a notification within the next few minutes.",
    systemImage: "paperplane", intent: .success, dismissLabel: "Dismiss")

  static func deleted(center: ShadowToastCenter) -> ShadowToast {
    ShadowToast(
      "Chapter deleted", systemImage: "trash",
      action: ShadowToastButton("Undo") { center.show(ShadowToast("Chapter restored", systemImage: "arrow.uturn.backward", intent: .success)) })
  }
}
