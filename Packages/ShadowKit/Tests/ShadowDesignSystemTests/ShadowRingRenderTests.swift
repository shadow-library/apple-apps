import CoreGraphics
import SwiftUI
import Testing

@testable import ShadowDesignSystem

@MainActor
@Suite("Ring render")
struct ShadowRingRenderTests {
  private func pixels(_ fraction: Double) -> (right: [UInt8], left: [UInt8])? {
    let view = ShadowRing(fraction: fraction, diameter: 44).tint(Color(red: 1, green: 0, blue: 0)).background(Color.white)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    guard let image = renderer.cgImage else { return nil }
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return true
    }
    guard drawn else { return nil }
    let middle = image.height / 2
    func pixel(_ x: Int) -> [UInt8] { Array(data[(middle * image.width + x) * 4..<(middle * image.width + x) * 4 + 3]) }
    return (pixel(image.width - 3), pixel(2))
  }

  @Test("should fill the right half of the ring at one half on first render")
  func halfFilled() throws {
    let sample = try #require(pixels(0.5))
    #expect(sample.right[0] > 200 && sample.right[1] < 80)
    #expect(!(sample.left[0] > 200 && sample.left[1] < 80))
  }

  @Test("should draw no accent at zero")
  func empty() throws {
    let sample = try #require(pixels(0))
    #expect(!(sample.right[0] > 200 && sample.right[1] < 80))
  }
}
