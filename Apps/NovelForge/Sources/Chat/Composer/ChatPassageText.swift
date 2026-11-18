import ShadowDesignSystem
import SwiftUI

#if os(macOS)
  import AppKit

  /// Read-only and selectable: SwiftUI's `Text` keeps its selection to itself, so the platform view reports it in UTF-16 code units of `text`.
  struct ChatPassageText: NSViewRepresentable {
    let text: String
    @Binding var selection: NSRange

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSScrollView {
      let scroll = NSTextView.scrollableTextView()
      scroll.drawsBackground = false
      guard let view = scroll.documentView as? NSTextView else { return scroll }
      view.isEditable = false
      view.isSelectable = true
      view.drawsBackground = false
      view.isRichText = false
      view.font = .preferredFont(forTextStyle: .body)
      view.textColor = NSColor(ShadowColor.textPrimary)
      view.textContainerInset = NSSize(width: Spacing.space2, height: Spacing.space2)
      view.string = text
      view.delegate = context.coordinator
      return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
      context.coordinator.selection = $selection
      guard let view = scroll.documentView as? NSTextView, !view.string.utf16.elementsEqual(text.utf16) else { return }
      view.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
      var selection: Binding<NSRange>

      init(selection: Binding<NSRange>) {
        self.selection = selection
      }

      /// Setting the text inside a view update moves the selection; the state write waits until the update is over.
      private func report(_ range: NSRange) {
        let selection = selection
        Task { @MainActor in selection.wrappedValue = range }
      }

      func textViewDidChangeSelection(_ notification: Notification) {
        guard let view = notification.object as? NSTextView else { return }
        report(view.selectedRange())
      }
    }
  }
#else
  import UIKit

  struct ChatPassageText: UIViewRepresentable {
    let text: String
    @Binding var selection: NSRange

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeUIView(context: Context) -> UITextView {
      let view = UITextView()
      view.isEditable = false
      view.isSelectable = true
      view.backgroundColor = .clear
      view.font = .preferredFont(forTextStyle: .body)
      view.adjustsFontForContentSizeCategory = true
      view.textColor = UIColor(ShadowColor.textPrimary)
      view.text = text
      view.delegate = context.coordinator
      return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
      context.coordinator.selection = $selection
      guard !view.text.utf16.elementsEqual(text.utf16) else { return }
      view.text = text
    }

    final class Coordinator: NSObject, UITextViewDelegate {
      var selection: Binding<NSRange>

      init(selection: Binding<NSRange>) {
        self.selection = selection
      }

      /// Setting the text inside a view update moves the selection; the state write waits until the update is over.
      private func report(_ range: NSRange) {
        let selection = selection
        Task { @MainActor in selection.wrappedValue = range }
      }

      func textViewDidChangeSelection(_ textView: UITextView) {
        report(textView.selectedRange)
      }
    }
  }
#endif
