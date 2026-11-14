import SwiftUI

extension EnvironmentValues {
  @Entry var shadowPreviewDropTarget: Bool?
}

extension View {
  @_spi(Preview) public func shadowPreviewDropTarget(_ isTargeted: Bool?) -> some View {
    environment(\.shadowPreviewDropTarget, isTargeted)
  }
}

public struct ShadowFileDropZone<Content: View>: View {
  private let onDrop: ([URL]) -> Bool
  private let content: (Bool) -> Content

  @State private var isDropTargeted = false
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.shadowPreviewDropTarget) private var previewTarget
  @Environment(\.colorSchemeContrast) private var contrast

  public init(onDrop: @escaping ([URL]) -> Bool, @ViewBuilder content: @escaping (_ isTargeted: Bool) -> Content) {
    self.onDrop = onDrop
    self.content = content
  }

  private var isTargeted: Bool { previewTarget ?? isDropTargeted }
  private var cornerRadius: CGFloat { ShadowDensity.current == .touch ? Radius.xxl : Radius.lg }

  public var body: some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    content(isTargeted)
      .padding(Spacing.space6)
      .frame(maxWidth: .infinity)
      .background(isTargeted ? ShadowColor.accentSoft : Color.clear, in: shape)
      .overlay {
        shape.strokeBorder(
          isTargeted ? ShadowColor.accent : (contrast == .increased ? ShadowColor.borderStrong : ShadowColor.borderInteractive),
          style: StrokeStyle(lineWidth: isTargeted ? 1.5 : 1, dash: [6, 4])
        )
      }
      .contentShape(shape)
      .dropDestination(for: URL.self) { urls, _ in
        onDrop(urls)
      } isTargeted: {
        isDropTargeted = $0
      }
      .opacity(isEnabled ? 1 : ShadowOpacity.disabled)
      .shadowAnimation(.fast, value: isTargeted)
  }
}
