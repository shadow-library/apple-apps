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

  public init(hasUnsavedChanges: Bool = false) {
    self.hasUnsavedChanges = hasUnsavedChanges
    isConfirmingDiscard = false
  }

  public var allowsInteractiveDismiss: Bool { !hasUnsavedChanges }

  public mutating func requestDismiss() -> Bool {
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
  let title: LocalizedStringKey
  let systemImage: String
  let perform: () -> Void

  public init(_ title: LocalizedStringKey, systemImage: String = "xmark", action: @escaping () -> Void) {
    self.title = title
    self.systemImage = systemImage
    perform = action
  }
}

public struct ShadowSheetConfirm {
  let title: LocalizedStringKey
  let systemImage: String
  let isDisabled: Bool
  let perform: () -> Void

  public init(_ title: LocalizedStringKey, systemImage: String = "checkmark", isDisabled: Bool = false, action: @escaping () -> Void) {
    self.title = title
    self.systemImage = systemImage
    self.isDisabled = isDisabled
    perform = action
  }
}

extension View {
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
    interactiveDismissDisabled(!guardState.wrappedValue.allowsInteractiveDismiss)
      .confirmationDialog(title, isPresented: guardState.isConfirmingDiscard, titleVisibility: .visible) {
        Button(discardTitle, role: .destructive) {
          guardState.wrappedValue.discard()
          onDiscard()
        }
        .shadowDestructiveDialogAction()
        Button(keepEditingTitle, role: .cancel) { guardState.wrappedValue.keepEditing() }
          .shadowDialogCancelAction()
      } message: {
        if let message { message }
      }
  }
}

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
      .toolbar { toolbar }
    #else
      NavigationStack {
        content
          .navigationTitle(title)
          #if os(iOS)
            .modifier(SubtitleModifier(subtitle: subtitle))
            .navigationBarTitleDisplayMode(.inline)
          #endif
          .toolbar { toolbar }
      }
    #endif
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItem(placement: .cancellationAction) {
      Button(role: .cancel, action: cancel.perform) { ShadowSheetActionLabel(title: cancel.title, systemImage: cancel.systemImage) }
        #if !os(macOS)
          .shadowBarItem()
        #endif
    }
    if let confirm {
      ToolbarItem(placement: .confirmationAction) {
        #if os(macOS)
          Button(action: confirm.perform) { ShadowSheetActionLabel(title: confirm.title, systemImage: confirm.systemImage) }
            .disabled(confirm.isDisabled)
        #else
          Button(action: confirm.perform) { ShadowSheetActionLabel(title: confirm.title, systemImage: confirm.systemImage) }
            .shadowToolbarProminent()
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
  let title: LocalizedStringKey
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
      Label(title, systemImage: systemImage).labelStyle(.iconOnly)
    } else {
      Text(title)
    }
  }
}
