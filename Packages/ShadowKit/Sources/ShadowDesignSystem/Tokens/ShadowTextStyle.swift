import SwiftUI

nonisolated public enum ShadowTextStyle: String, CaseIterable, Sendable {
  case iosLargeTitle = "ios-large-title"
  case iosTitle1 = "ios-title1"
  case iosTitle2 = "ios-title2"
  case iosTitle3 = "ios-title3"
  case iosHeadline = "ios-headline"
  case iosBody = "ios-body"
  case iosCallout = "ios-callout"
  case iosSubheadline = "ios-subheadline"
  case iosFootnote = "ios-footnote"
  case iosCaption = "ios-caption"
  case iosCaption2 = "ios-caption2"
  case macLargeTitle = "mac-large-title"
  case macTitle1 = "mac-title1"
  case macTitle2 = "mac-title2"
  case macTitle3 = "mac-title3"
  case macHeadline = "mac-headline"
  case macBody = "mac-body"
  case macCallout = "mac-callout"
  case macSubheadline = "mac-subheadline"
  case macFootnote = "mac-footnote"
  case macCaption = "mac-caption"
  case monoBody = "mono-body"
  case monoFigure = "mono-figure"

  public var textStyle: Font.TextStyle {
    switch self {
    case .iosLargeTitle, .macLargeTitle: .largeTitle
    case .iosTitle1, .macTitle1: .title
    case .iosTitle2, .macTitle2: .title2
    case .iosTitle3, .macTitle3: .title3
    case .iosHeadline, .macHeadline: .headline
    case .iosBody, .macBody: .body
    case .iosCallout, .macCallout: .callout
    // macOS sets footnote at 10pt; subheadline is the 11pt style that mac-footnote specifies.
    case .iosSubheadline, .macSubheadline, .macFootnote: .subheadline
    case .iosFootnote: .footnote
    case .iosCaption, .macCaption: .caption
    case .iosCaption2: .caption2
    case .monoBody: Self.platform(touch: .footnote, mac: .body)
    case .monoFigure: Self.platform(touch: .body, mac: .title2)
    }
  }

  public var weight: Font.Weight {
    switch self {
    case .iosLargeTitle, .macLargeTitle: .bold
    case .iosTitle1, .iosTitle2, .iosTitle3, .iosHeadline, .macTitle1, .macTitle2, .macTitle3, .macHeadline: .semibold
    case .iosCaption, .iosCaption2, .macSubheadline, .macCaption, .monoFigure: .medium
    case .iosBody, .iosCallout, .iosSubheadline, .iosFootnote, .macBody, .macCallout, .macFootnote, .monoBody: .regular
    }
  }

  public var design: Font.Design {
    self == .monoBody ? .monospaced : .default
  }

  public var font: Font {
    let font = Font.system(textStyle, design: design, weight: weight)
    return self == .monoFigure ? font.monospacedDigit() : font
  }

  var tracking: CGFloat {
    guard self == .macSubheadline else { return 0 }
    let letterSpacingEm: CGFloat = 0.06
    let pointSize: CGFloat = 11
    return letterSpacingEm * pointSize
  }

  private static func platform<Value>(touch: Value, mac: Value) -> Value {
    #if os(macOS)
      mac
    #else
      touch
    #endif
  }
}

nonisolated extension ShadowTextStyle {
  public static var largeTitle: Self { platform(touch: .iosLargeTitle, mac: .macLargeTitle) }
  public static var title: Self { platform(touch: .iosTitle1, mac: .macTitle1) }
  public static var title2: Self { platform(touch: .iosTitle2, mac: .macTitle2) }
  public static var title3: Self { platform(touch: .iosTitle3, mac: .macTitle3) }
  public static var headline: Self { platform(touch: .iosHeadline, mac: .macHeadline) }
  public static var body: Self { platform(touch: .iosBody, mac: .macBody) }
  public static var callout: Self { platform(touch: .iosCallout, mac: .macCallout) }
  public static var subheadline: Self { platform(touch: .iosSubheadline, mac: .macFootnote) }
  public static var sectionHeader: Self { platform(touch: .iosSubheadline, mac: .macSubheadline) }
  public static var footnote: Self { platform(touch: .iosFootnote, mac: .macFootnote) }
  public static var caption: Self { platform(touch: .iosCaption, mac: .macCaption) }
  public static var caption2: Self { platform(touch: .iosCaption2, mac: .macCaption) }
}

nonisolated extension Font {
  public static func shadow(_ style: ShadowTextStyle) -> Font {
    style.font
  }
}

private struct ShadowFontModifier: ViewModifier {
  let style: ShadowTextStyle
  @ScaledMetric private var tracking: CGFloat

  init(style: ShadowTextStyle) {
    self.style = style
    _tracking = ScaledMetric(wrappedValue: style.tracking, relativeTo: style.textStyle)
  }

  func body(content: Content) -> some View {
    content
      .font(style.font)
      .tracking(tracking)
  }
}

extension View {
  public func shadowFont(_ style: ShadowTextStyle) -> some View {
    modifier(ShadowFontModifier(style: style))
  }
}
