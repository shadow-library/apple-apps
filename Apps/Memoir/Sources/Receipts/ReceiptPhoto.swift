import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ReceiptPhotoError: Error, Equatable {
  case unreadable
  case tooLarge
}

/// A receipt image as it is kept: re-encoded as JPEG, turned upright, no longer than `longestSide` and stripped of its metadata (the place it was taken
/// included), so every device shows the same bytes and a photo library's location never reaches the vault.
nonisolated struct ReceiptPhoto: Sendable, Equatable {
  static let contentType = "image/jpeg"
  /// memoir-web `RECEIPT_MAX_BYTES`, far under the sync kernel's blob limit.
  static let maximumBytes = 8 * 1024 * 1024
  /// What a picked file may be before it is read at all; the image is shrunk afterwards.
  static let maximumSourceBytes = 64 * 1024 * 1024
  static let longestSide = 3000

  let data: Data
  let pixelWidth: Int
  let pixelHeight: Int

  var contentType: String { Self.contentType }

  static func normalised(_ source: Data, longestSide: Int = longestSide, maximumBytes: Int = maximumBytes) throws(ReceiptPhotoError) -> ReceiptPhoto {
    guard !source.isEmpty else { throw .unreadable }
    guard source.count <= maximumSourceBytes else { throw .tooLarge }
    guard let image = CGImageSourceCreateWithData(source as CFData, nil), CGImageSourceGetCount(image) > 0 else { throw .unreadable }
    var side = longestSide
    for quality in [0.8, 0.7, 0.6, 0.5] {
      guard let upright = thumbnail(image, longestSide: side) else { throw .unreadable }
      guard let data = jpeg(upright, quality: quality) else { throw .unreadable }
      if data.count <= maximumBytes { return ReceiptPhoto(data: data, pixelWidth: upright.width, pixelHeight: upright.height) }
      side = side * 3 / 4
    }
    throw .tooLarge
  }

  private static func thumbnail(_ source: CGImageSource, longestSide: Int) -> CGImage? {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: longestSide,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
  }
}
