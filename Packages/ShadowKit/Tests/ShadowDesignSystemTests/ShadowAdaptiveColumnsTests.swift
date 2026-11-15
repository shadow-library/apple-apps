import CoreGraphics
import SwiftUI
import Testing

@testable import ShadowDesignSystem

@Suite("Adaptive columns placement")
struct ShadowColumnGridTests {
  private func grid(width: CGFloat?, maxColumns: Int = 3) -> ShadowColumnGrid {
    ShadowColumnGrid(width: width, maxColumns: maxColumns, minColumnWidth: 440, maxColumnWidth: 672, spacing: 32)
  }

  private func item(_ height: CGFloat, span: ShadowColumnSpan = .single) -> ShadowColumnItem {
    ShadowColumnItem(span: span) { CGSize(width: $0, height: height) }
  }

  private func fixed(width: CGFloat, height: CGFloat) -> ShadowColumnItem {
    ShadowColumnItem(span: .single) { _ in CGSize(width: width, height: height) }
  }

  @Test(
    "should fit as many columns as the minimum width allows, up to the maximum",
    arguments: [
      (370.0, 1), (439.0, 1), (911.0, 1), (912.0, 2), (992.0, 2), (1336.0, 2), (1383.0, 2), (1384.0, 3), (2400.0, 3),
    ])
  func columnCount(width: CGFloat, expected: Int) {
    #expect(grid(width: width).columnCount == expected)
  }

  @Test("should stop at the maximum column count however wide the proposal is")
  func maximumCount() {
    #expect(grid(width: 2400, maxColumns: 2).columnCount == 2)
    #expect(grid(width: 2400, maxColumns: 1).columnCount == 1)
  }

  @Test("should share the width between the columns and cap each at the readable width")
  func columnWidth() {
    #expect(grid(width: 992).columnWidth == 480)
    #expect(grid(width: 2400).columnWidth == 672)
    #expect(grid(width: 2400).width == CGFloat(672 * 3 + 64))
    #expect(grid(width: 900, maxColumns: 1).columnWidth == 672)
    #expect(grid(width: 300).columnWidth == 300)
  }

  @Test("should resolve an unspecified or infinite width to the widest finite layout")
  func unspecifiedWidth() {
    for width in [nil, CGFloat.infinity] {
      let resolved = grid(width: width, maxColumns: 2)
      #expect(resolved.columnCount == 2)
      #expect(resolved.width == CGFloat(672 * 2 + 32))
    }
  }

  @Test("should lay out a single column for a zero or negative width")
  func degenerateWidth() {
    #expect(grid(width: 0).columnCount == 1)
    #expect(grid(width: 0).columnWidth == 0)
    #expect(grid(width: -10).columnWidth == 0)
  }

  @Test("should lay out nothing for zero items")
  func empty() {
    let arrangement = grid(width: 992).arrange([], rowSpacing: 32)
    #expect(arrangement.frames.isEmpty)
    #expect(arrangement.size == CGSize(width: 992, height: 0))
  }

  @Test("should put each item into the column that ends highest")
  func shortestColumn() {
    let arrangement = grid(width: 992).arrange([item(300), item(100), item(100), item(50)], rowSpacing: 20)
    #expect(arrangement.columns == [0, 1, 1, 1])
    #expect(arrangement.frames[2].origin == CGPoint(x: 512, y: 120))
    #expect(arrangement.frames[3].origin == CGPoint(x: 512, y: 240))
    #expect(arrangement.size.height == 300)
  }

  @Test("should break ties toward the leading column, within half a point")
  func ties() {
    let exact = grid(width: 992).arrange([item(100), item(100), item(10)], rowSpacing: 0)
    #expect(exact.columns == [0, 1, 0])
    let rounded = grid(width: 992).arrange([item(100.3), item(100), item(10)], rowSpacing: 0)
    #expect(rounded.columns == [0, 1, 0])
    let lower = grid(width: 992).arrange([item(101), item(100), item(10)], rowSpacing: 0)
    #expect(lower.columns == [0, 1, 1])
  }

  @Test("should start a full-span item below the tallest column and resume every column below it")
  func fullSpanBand() {
    let arrangement = grid(width: 992).arrange([item(300), item(100), item(200, span: .full), item(50), item(60)], rowSpacing: 20)
    #expect(arrangement.columns == [0, 1, nil, 0, 1])
    #expect(arrangement.frames[2] == CGRect(x: 0, y: 320, width: 992, height: 200))
    #expect(arrangement.frames[3].origin == CGPoint(x: 0, y: 540))
    #expect(arrangement.frames[4].origin == CGPoint(x: 512, y: 540))
    #expect(arrangement.size.height == 600)
  }

  @Test("should span every column with an item too wide for one")
  func itemWiderThanColumn() {
    let arrangement = grid(width: 992).arrange([item(100), fixed(width: 600, height: 80), item(40)], rowSpacing: 0)
    #expect(arrangement.columns == [0, nil, 0])
    #expect(arrangement.frames[1] == CGRect(x: 0, y: 100, width: 992, height: 80))
  }

  @Test("should stack everything in one column when only one fits")
  func singleColumn() {
    let arrangement = grid(width: 370).arrange([item(100), item(50, span: .full), item(30)], rowSpacing: 10)
    #expect(arrangement.frames.map(\.minY) == [0, 110, 170])
    #expect(arrangement.frames.allSatisfy { $0.minX == 0 && $0.width == 370 })
    #expect(arrangement.size == CGSize(width: 370, height: 200))
  }

  @Test("should place again from the current sizes, so a grown item can move the items after it")
  func reflowsOnGrowth() {
    let first = grid(width: 992).arrange([item(100), item(200), item(100)], rowSpacing: 0)
    #expect(first.columns == [0, 1, 0])
    let grown = grid(width: 992).arrange([item(400), item(200), item(100)], rowSpacing: 0)
    #expect(grown.columns == [0, 1, 1])
  }

  @Test("should not add spacing after an item with no height")
  func zeroHeight() {
    let arrangement = grid(width: 370).arrange([item(100), item(0), item(50)], rowSpacing: 10)
    #expect(arrangement.frames.map(\.minY) == [0, 110, 110])
    #expect(arrangement.size.height == 160)
  }
}

@MainActor
@Suite("Adaptive columns rendering")
struct ShadowAdaptiveColumnsRenderTests {
  private enum Swatch {
    case red
    case green
    case blue
  }

  private func render(_ direction: LayoutDirection, typeSize: DynamicTypeSize = .large) -> Bitmap? {
    let view = ShadowAdaptiveColumns(maxColumns: 2, minColumnWidth: 10, spacing: 0) {
      Color(red: 1, green: 0, blue: 0).frame(height: 10)
      Color(red: 0, green: 1, blue: 0).frame(height: 10)
      Color(red: 0, green: 0, blue: 1).frame(height: 10).shadowColumnSpan(.full)
    }
    .frame(width: 20, height: 40, alignment: .topLeading)
    .background(Color.white)
    .environment(\.layoutDirection, direction)
    .environment(\.dynamicTypeSize, typeSize)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    return renderer.cgImage.flatMap(Bitmap.init)
  }

  @Test("should place columns leading to trailing with a full span below")
  func leftToRight() throws {
    let bitmap = try #require(render(.leftToRight))
    #expect(bitmap.swatch(x: 5, y: 5) == .red)
    #expect(bitmap.swatch(x: 15, y: 5) == .green)
    #expect(bitmap.swatch(x: 5, y: 15) == .blue)
    #expect(bitmap.swatch(x: 15, y: 15) == .blue)
  }

  @Test("should stop the columns at the readable width when the proposal is wider than the cap")
  func capsWideProposal() throws {
    let width = Int(ShadowMetrics.readableWidth) * 2 + 40
    let view = ShadowAdaptiveColumns(maxColumns: 2, spacing: 0) {
      Color(red: 1, green: 0, blue: 0).frame(height: 10)
      Color(red: 0, green: 1, blue: 0).frame(height: 10)
    }
    .frame(width: CGFloat(width), height: 10, alignment: .topLeading)
    .background(Color.white)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    let bitmap = try #require(renderer.cgImage.flatMap(Bitmap.init))
    let readable = Int(ShadowMetrics.readableWidth)
    #expect(bitmap.swatch(x: readable - 1, y: 5) == .red)
    #expect(bitmap.swatch(x: readable + 1, y: 5) == .green)
    #expect(bitmap.swatch(x: readable * 2 + 1, y: 5) == nil)
  }

  @Test("should mirror the columns right to left")
  func rightToLeft() throws {
    let bitmap = try #require(render(.rightToLeft))
    #expect(bitmap.swatch(x: 15, y: 5) == .red)
    #expect(bitmap.swatch(x: 5, y: 5) == .green)
  }

  @Test("should stack a single column at accessibility text sizes")
  func accessibilitySize() throws {
    let bitmap = try #require(render(.leftToRight, typeSize: .accessibility1))
    #expect(bitmap.swatch(x: 5, y: 5) == .red)
    #expect(bitmap.swatch(x: 15, y: 5) == .red)
    #expect(bitmap.swatch(x: 5, y: 15) == .green)
    #expect(bitmap.swatch(x: 5, y: 25) == .blue)
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
