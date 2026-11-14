import SwiftUI

nonisolated public enum ShadowTransferState: Hashable, Sendable {
  case queued
  case uploading(progress: Double)
  case done
  case failed

  public var fraction: Double? {
    switch self {
    case .uploading(let progress): min(max(progress, 0), 1)
    case .done: 1
    case .queued, .failed: nil
    }
  }

  public var percent: Int? {
    fraction.map { Int(($0 * 100).rounded()) }
  }

  public var isActive: Bool {
    switch self {
    case .queued, .uploading: true
    case .done, .failed: false
    }
  }
}

public struct ShadowFileRow<Trailing: View>: View {
  private let title: Text
  private let detail: Text
  private let systemImage: String
  private let state: ShadowTransferState
  private let trailing: Trailing

  public init(title: Text, detail: Text, systemImage: String, state: ShadowTransferState, @ViewBuilder trailing: () -> Trailing) {
    self.title = title
    self.detail = detail
    self.systemImage = systemImage
    self.state = state
    self.trailing = trailing()
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space2) {
      HStack(spacing: Spacing.space3) {
        Image(systemName: systemImage)
          .foregroundStyle(ShadowColor.textPrimary)
          .frame(width: ShadowMetrics.controlTouchSm, height: ShadowMetrics.controlTouchSm)
          .background(ShadowColor.surfaceWell, in: .rect(cornerRadius: Radius.md, style: .continuous))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 0) {
          title
            .shadowFont(.body)
            .foregroundStyle(ShadowColor.textPrimary)
          detailLabel
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        stateAccessory
        trailing
      }
      if case .uploading(let progress) = state {
        ProgressView(value: min(max(progress, 0), 1))
          .tint(ShadowColor.accent)
          .accessibilityHidden(true)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityValue(state.fraction.map { Text($0, format: .percent.precision(.fractionLength(0))) } ?? Text(verbatim: ""))
  }

  @ViewBuilder
  private var detailLabel: some View {
    if state == .failed {
      ShadowValidationMessage(detail)
    } else {
      detail
        .shadowFont(.subheadline)
        .foregroundStyle(ShadowColor.textSecondary)
    }
  }

  @ViewBuilder
  private var stateAccessory: some View {
    if state == .done {
      Image(systemName: "checkmark.circle")
        .foregroundStyle(ShadowColor.accentText)
        .accessibilityHidden(true)
    }
  }
}

extension ShadowFileRow where Trailing == EmptyView {
  public init(title: Text, detail: Text, systemImage: String, state: ShadowTransferState) {
    self.init(title: title, detail: detail, systemImage: systemImage, state: state) { EmptyView() }
  }
}
