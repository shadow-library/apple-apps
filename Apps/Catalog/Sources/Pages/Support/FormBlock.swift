import ShadowDesignSystem
import SwiftUI

struct FormBlock<Content: View>: View {
  @ViewBuilder let content: Content
  @State private var height: CGFloat?

  var body: some View {
    Form { content }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      .scrollDisabled(true)
      .contentMargins(.horizontal, Self.margin, for: .scrollContent)
      .contentMargins(.vertical, 0, for: .scrollContent)
      .onScrollGeometryChange(for: CGFloat.self) {
        $0.contentSize.height
      } action: { _, newValue in
        if newValue > 0 { height = newValue }
      }
      .modifier(MeasuredHeight(height: height))
      .padding(.horizontal, -Self.inset)
      #if os(macOS)
        .padding(.vertical, -Spacing.space5)
      #endif
  }

  private static var margin: CGFloat {
    #if os(macOS)
      0
    #else
      Spacing.space4
    #endif
  }

  private static var inset: CGFloat {
    #if os(macOS)
      Spacing.space5
    #else
      Spacing.space4
    #endif
  }
}

struct MeasuredHeight: ViewModifier {
  let height: CGFloat?

  func body(content: Content) -> some View {
    if let height {
      content.frame(height: height)
    } else {
      content.containerRelativeFrame(.vertical).opacity(0)
    }
  }
}

struct FormSection<Content: View, Header: View, Footer: View>: View {
  @ViewBuilder let content: Content
  @ViewBuilder let header: Header
  @ViewBuilder let footer: Footer

  var body: some View {
    Section {
      content
        #if !os(macOS)
          .listRowBackground(ShadowColor.surfaceCard)
        #endif
    } header: {
      header
    } footer: {
      footer
    }
  }
}

extension FormSection where Header == EmptyView {
  init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
    self.init(content: content, header: { EmptyView() }, footer: footer)
  }
}

extension FormSection where Footer == EmptyView {
  init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
    self.init(content: content, header: header, footer: { EmptyView() })
  }
}

extension FormSection where Header == EmptyView, Footer == EmptyView {
  init(@ViewBuilder content: () -> Content) {
    self.init(content: content, header: { EmptyView() }, footer: { EmptyView() })
  }
}

struct FieldRow<Field: View>: View {
  let title: LocalizedStringKey
  var help: LocalizedStringKey?
  var isWide = false
  @ViewBuilder let field: Field

  var body: some View {
    #if os(macOS)
      LabeledContent {
        VStack(alignment: .leading, spacing: Spacing.space1) {
          field
            .labelsHidden()
            .frame(maxWidth: isWide ? .infinity : FieldMetrics.macFieldWidth, alignment: .leading)
          if let help {
            Text(help).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
          }
        }
      } label: {
        Text(title)
          .foregroundStyle(ShadowColor.textSecondary)
          .frame(minWidth: FieldMetrics.macLabelWidth, alignment: .trailing)
      }
    #else
      VStack(alignment: .leading, spacing: Spacing.space2) {
        Text(title).shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
        field
        if let help {
          Text(help).shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
        }
      }
    #endif
  }
}

struct FieldStack<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    #if os(macOS)
      Form { content }
        .formStyle(.columns)
        .shadowCard()
    #else
      VStack(alignment: .leading, spacing: Spacing.space4) { content }
        .shadowCard()
    #endif
  }
}

enum FieldMetrics {
  static let macFieldWidth: CGFloat = 360
  static let macLabelWidth: CGFloat = 140
}

// iOS 26 ColorPicker and DatePicker draw no disabled state, so on touch the control dims and its label stays; Mac dims them natively.
struct DisabledControlRow<Control: View>: View {
  let title: LocalizedStringKey
  @ViewBuilder let control: Control

  init(_ title: LocalizedStringKey, @ViewBuilder control: () -> Control) {
    self.title = title
    self.control = control()
  }

  var body: some View {
    #if os(macOS)
      control.disabled(true)
    #else
      LabeledContent(title) {
        control
          .labelsHidden()
          .opacity(ShadowOpacity.disabled)
      }
      .disabled(true)
      .accessibilityElement(children: .combine)
    #endif
  }
}
