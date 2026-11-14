import SwiftUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

nonisolated extension ShadowColorToken {
  public var color: Color {
    light == dark ? Color(light) : Color(light: light, dark: dark)
  }

  public func rgba(for colorScheme: ColorScheme) -> ShadowRGBA {
    colorScheme == .dark ? dark : light
  }
}

nonisolated extension Color {
  init(_ rgba: ShadowRGBA) {
    self.init(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
  }

  init(light: ShadowRGBA, dark: ShadowRGBA) {
    #if os(watchOS)
      // watchOS has no light appearance and no dynamic UIColor provider.
      self.init(dark)
    #elseif canImport(UIKit)
      self.init(uiColor: UIColor { traits in UIColor(traits.userInterfaceStyle == .dark ? dark : light) })
    #elseif canImport(AppKit)
      self.init(nsColor: NSColor(name: nil) { appearance in NSColor(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light) })
    #endif
  }
}

#if canImport(UIKit) && !os(watchOS)
  nonisolated extension UIColor {
    fileprivate convenience init(_ rgba: ShadowRGBA) {
      self.init(red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
    }
  }
#elseif canImport(AppKit)
  nonisolated extension NSColor {
    fileprivate convenience init(_ rgba: ShadowRGBA) {
      self.init(srgbRed: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
    }
  }
#endif
