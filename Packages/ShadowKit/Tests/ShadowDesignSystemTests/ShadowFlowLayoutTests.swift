import CoreGraphics
import SwiftUI
import Testing

@testable import ShadowDesignSystem

@MainActor
@Suite("Flow layout")
struct ShadowFlowLayoutTests {
  private enum Swatch: CaseIterable {
    case red
    case green
    case blue

    var color: Color {
      switch self {
      case .red: Color(red: 1, green: 0, blue: 0)
      case .green: Color(red: 0, green: 1, blue: 0)
      case .blue: Color(red: 0, green: 0, blue: 1)
      }
    }
  }

  private func render(_ direction: LayoutDirection, width: CGFloat, height: CGFloat) -> Bitmap? {
    let view = ShadowFlowLayout(spacing: 0, lineSpacing: 0) {
      ForEach(Swatch.allCases, id: \.self) { swatch in
        swatch.color.frame(width: 10, height: 10)
      }
    }
    .frame(width: width, height: height, alignment: .topLeading)
    .background(Color.white)
    .environment(\.layoutDirection, direction)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    return renderer.cgImage.flatMap(Bitmap.init)
  }

  @Test("should place items left to right and wrap onto the next line")
  func leftToRight() throws {
    let bitmap = try #require(render(.leftToRight, width: 25, height: 20))
    #expect(bitmap.swatch(x: 5, y: 5) == .red)
    #expect(bitmap.swatch(x: 15, y: 5) == .green)
    #expect(bitmap.swatch(x: 5, y: 15) == .blue)
  }

  @Test("should mirror placement right to left")
  func rightToLeft() throws {
    let bitmap = try #require(render(.rightToLeft, width: 25, height: 20))
    #expect(bitmap.swatch(x: 20, y: 5) == .red)
    #expect(bitmap.swatch(x: 10, y: 5) == .green)
    #expect(bitmap.swatch(x: 20, y: 15) == .blue)
  }

  @Test("should keep a line whose items overflow by less than half a point, absorbing rounding")
  func toleratesRounding() throws {
    let bitmap = try #require(render(.leftToRight, width: 29.6, height: 20))
    #expect(bitmap.swatch(x: 25, y: 5) == .blue)
    #expect(bitmap.swatch(x: 5, y: 15) == nil)
  }

  @Test("should wrap once the items overflow by more than half a point")
  func wrapsBeyondTolerance() throws {
    let bitmap = try #require(render(.leftToRight, width: 29.4, height: 20))
    #expect(bitmap.swatch(x: 5, y: 15) == .blue)
    #expect(bitmap.swatch(x: 25, y: 5) == nil)
  }

  private struct Bitmap {
    let width: Int
    let pixels: [UInt8]

    init?(_ image: CGImage) {
      width = image.width
      var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
      let drawn = pixels.withUnsafeMutableBytes { buffer in
        guard
          let context = CGContext(
            data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
      }
      guard drawn else { return nil }
      self.pixels = pixels
    }

    func swatch(x: Int, y: Int) -> Swatch? {
      let offset = (y * width + x) * 4
      let (red, green, blue) = (pixels[offset], pixels[offset + 1], pixels[offset + 2])
      switch (red > 200, green > 200, blue > 200) {
      case (true, false, false): return .red
      case (false, true, false): return .green
      case (false, false, true): return .blue
      default: return nil
      }
    }
  }
}
