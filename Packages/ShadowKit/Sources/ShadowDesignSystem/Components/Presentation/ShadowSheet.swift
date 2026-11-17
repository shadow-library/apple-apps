import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

nonisolated public enum ShadowSheetStyle: Hashable, Sendable, CaseIterable {
  case partial
  case form
  case full
}

nonisolated public struct ShadowDismissGuard: Hashable, Sendable {
  public var hasUnsavedChanges: Bool
  public var isConfirmingDiscard: Bool
  public var isBusy: Bool

  public init(hasUnsavedChanges: Bool = false, isBusy: Bool = false) {
    self.hasUnsavedChanges = hasUnsavedChanges
    isConfirmingDiscard = false
    self.isBusy = isBusy
  }

  public var allowsInteractiveDismiss: Bool { !hasUnsavedChanges && !isBusy }

  public mutating func requestDismiss() -> Bool {
    guard !isBusy else { return false }
    guard hasUnsavedChanges else { return true }
    isConfirmingDiscard = true
    return false
  }

  public mutating func discard() {
    hasUnsavedChanges = false
    isConfirmingDiscard = false
  }

  public mutating func keepEditing() {
    isConfirmingDiscard = false
  }
}

public struct ShadowSheetCancel {
  let title: Text
  let isDisabled: Bool
  let systemImage: String
  let perform: () -> Void

  public init(_ title: LocalizedStringKey, systemImage: String = "xmark", isDisabled: Bool = false, action: @escaping () -> Void) {
    self.title = Text(title)
    self.isDisabled = isDisabled
    self.systemImage = systemImage
    perform = action
  }

  public init(_ title: Text, systemImage: String = "xmark", isDisabled: Bool = false, action: @escaping () -> Void) {
    self.title = title
    self.isDisabled = isDisabled
    self.systemImage = systemImage
    perform = action
  }
}

public struct ShadowSheetConfirm {
  let title: Text
  let systemImage: String
  let isDisabled: Bool
  let submitShortcut: Bool
  let perform: () -> Void

  public init(_ title: LocalizedStringKey, systemImage: String = "checkmark", isDisabled: Bool = false, submitShortcut: Bool = false, action: @escaping () -> Void) {
    self.init(Text(title), systemImage: systemImage, isDisabled: isDisabled, submitShortcut: submitShortcut, action: action)
  }

  public init(_ title: Text, systemImage: String = "checkmark", isDisabled: Bool = false, submitShortcut: Bool = false, action: @escaping () -> Void) {
    self.title = title
    self.systemImage = systemImage
    self.isDisabled = isDisabled
    self.submitShortcut = submitShortcut
    perform = action
  }
}

extension View {
  /// Supplies its own scroll view, so pass content that does not scroll by itself; a List or ScrollView inside would collapse.
  /// On iPad it also sizes `.form` sheets to their content, and that sizing takes precedence over an outer `.shadowSheetStyle(.form)`.
  public func shadowFittedDetents() -> some View {
    modifier(ShadowFittedDetentsModifier())
  }

  public func shadowSheetStyle(_ style: ShadowSheetStyle) -> some View {
    modifier(ShadowSheetStyleModifier(style: style))
  }

  public func shadowSheetHeader(_ title: Text, subtitle: Text? = nil, cancel: ShadowSheetCancel, confirm: ShadowSheetConfirm? = nil) -> some View {
    modifier(ShadowSheetHeaderModifier(title: title, subtitle: subtitle, cancel: cancel, confirm: confirm))
  }

  public func shadowDismissGuard(
    _ guardState: Binding<ShadowDismissGuard>,
    title: Text,
    message: Text? = nil,
    discardTitle: LocalizedStringKey,
    keepEditingTitle: LocalizedStringKey,
    onDiscard: @escaping () -> Void
  ) -> some View {
    shadowDismissGuard(guardState, title: title, message: message, discardTitle: Text(discardTitle), keepEditingTitle: Text(keepEditingTitle), onDiscard: onDiscard)
  }

  public func shadowDismissGuard(
    _ guardState: Binding<ShadowDismissGuard>,
    title: Text,
    message: Text? = nil,
    discardTitle: Text,
    keepEditingTitle: Text,
    onDiscard: @escaping () -> Void
  ) -> some View {
    interactiveDismissDisabled(!guardState.wrappedValue.allowsInteractiveDismiss)
      .confirmationDialog(title, isPresented: guardState.isConfirmingDiscard, titleVisibility: .visible) {
        Button(role: .destructive) {
          guardState.wrappedValue.discard()
          onDiscard()
        } label: {
          discardTitle
        }
        .shadowDestructiveDialogAction()
        Button(role: .cancel) {
          guardState.wrappedValue.keepEditing()
        } label: {
          keepEditingTitle
        }
        .shadowDialogCancelAction()
      } message: {
        if let message { message }
      }
  }
}

nonisolated enum ShadowFittedDetents {
  static func detents(contentHeight: CGFloat?, barHeight: CGFloat = 0) -> Set<PresentationDetent> {
    [contentHeight.map { .height(($0 + barHeight).rounded(.up)) } ?? .medium]
  }

  static func formHeight(content: CGFloat?, form: CGFloat?) -> CGFloat? {
    guard let content else { return form }
    guard let form else { return content.rounded(.up) }
    return min(content.rounded(.up), form)
  }
}

private struct ShadowFittedDetentsModifier: ViewModifier {
  @State private var contentHeight: CGFloat?
  @State private var barHeight: CGFloat = 0

  func body(content: Content) -> some View {
    ScrollView {
      content.onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { contentHeight = $0 })
    }
    .scrollBounceBehavior(.basedOnSize)
    .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.top }, action: { barHeight = $0 })
    .presentationDetents(ShadowFittedDetents.detents(contentHeight: contentHeight, barHeight: barHeight))
    #if os(iOS)
      .presentationSizing(ShadowFittedFormSizing(height: contentHeight.map { $0 + barHeight }))
    #endif
  }
}

#if os(iOS)
  struct ShadowFittedFormSizing: PresentationSizing {
    let height: CGFloat?

    func proposedSize(for root: PresentationSizingRoot, context: PresentationSizingContext) -> ProposedViewSize {
      let form = FormPresentationSizing.form.proposedSize(for: root, context: context)
      return ProposedViewSize(width: form.width, height: ShadowFittedDetents.formHeight(content: height, form: form.height))
    }
  }
#endif

private struct ShadowSheetStyleModifier: ViewModifier {
  let style: ShadowSheetStyle

  func body(content: Content) -> some View {
    #if os(macOS)
      if style == .partial {
        content
          .presentationSizing(.fitted)
          .presentationBackground(ShadowColor.surfaceRaised)
      } else {
        content
          .presentationSizing(.form)
          .presentationBackground(ShadowColor.surfaceRaised)
      }
    #elseif os(visionOS)
      content.presentationDetents(style == .partial ? [.medium, .large] : [.large])
    #else
      switch style {
      case .partial:
        content
          .presentationDetents([.medium, .large])
          .presentationDragIndicator(.visible)
      case .form:
        content
          .presentationSizing(.form)
          .presentationBackground(ShadowColor.surfaceRaised)
      case .full:
        content
          .presentationDetents([.large])
          .presentationDragIndicator(.visible)
          .presentationBackground(ShadowColor.surfaceRaised)
      }
    #endif
  }
}

private struct ShadowSheetHeaderModifier: ViewModifier {
  let title: Text
  let subtitle: Text?
  let cancel: ShadowSheetCancel
  let confirm: ShadowSheetConfirm?

  func body(content: Content) -> some View {
    #if os(macOS)
      VStack(alignment: .leading, spacing: Spacing.space4) {
        VStack(alignment: .leading, spacing: Spacing.space05) {
          title
            .shadowFont(.headline)
            .foregroundStyle(ShadowColor.textPrimary)
            .accessibilityAddTraits(.isHeader)
          if let subtitle {
            subtitle
              .shadowFont(.footnote)
              .foregroundStyle(ShadowColor.textSecondary)
          }
        }
        content
      }
      .padding(Spacing.space5)
      .background { submitShortcut }
      .toolbar { toolbar }
    #else
      NavigationStack {
        content
          .background { submitShortcut }
          .navigationTitle(title)
          #if os(iOS)
            .modifier(SubtitleModifier(subtitle: subtitle))
            .navigationBarTitleDisplayMode(.inline)
          #endif
          .toolbar { toolbar }
      }
    #endif
  }

  @ViewBuilder
  private var submitShortcut: some View {
    if let confirm, confirm.submitShortcut {
      Button(action: confirm.perform) { confirm.title }
        .keyboardShortcut(.return, modifiers: .command)
        .focusable(false)
        .disabled(confirm.isDisabled)
        .opacity(0)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItem(placement: .cancellationAction) {
      Button(role: .cancel, action: cancel.perform) { ShadowSheetActionLabel(title: cancel.title, systemImage: cancel.systemImage) }
        .disabled(cancel.isDisabled)
        .shadowBarItem()
    }
    if let confirm {
      ToolbarItem(placement: .confirmationAction) {
        #if os(macOS)
          Button(action: confirm.perform) { ShadowSheetActionLabel(title: confirm.title, systemImage: confirm.systemImage) }
            .keyboardShortcut(.defaultAction)
            .disabled(confirm.isDisabled)
        #else
          Button(action: confirm.perform) { ShadowSheetActionLabel(title: confirm.title, systemImage: confirm.systemImage) }
            .shadowToolbarProminent()
            .keyboardShortcut(.defaultAction)
            .disabled(confirm.isDisabled)
        #endif
      }
    }
  }
}

#if os(iOS)
  private struct SubtitleModifier: ViewModifier {
    let subtitle: Text?

    func body(content: Content) -> some View {
      if let subtitle {
        content.navigationSubtitle(subtitle)
      } else {
        content
      }
    }
  }
#endif

private struct ShadowSheetActionLabel: View {
  let title: Text
  let systemImage: String

  private var showsSymbol: Bool {
    #if os(iOS)
      UIDevice.current.userInterfaceIdiom == .phone
    #else
      false
    #endif
  }

  var body: some View {
    if showsSymbol {
      Label {
        title
      } icon: {
        Image(systemName: systemImage)
      }.labelStyle(.iconOnly)
    } else {
      title
    }
  }
}
