import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum IconError: Error, CustomStringConvertible {
  case unreadableTokens(reason: String)
  case unknownToken(String)
  case invalidColor(String, token: String)
  case renderFailed(app: String)
  case writeFailed(path: String)

  var description: String {
    switch self {
    case .unreadableTokens(let reason): "Cannot read Design/tokens.json: \(reason)"
    case .unknownToken(let name): "Design/tokens.json has no colour token \(name)"
    case .invalidColor(let value, let token): "\(token) resolves to \"\(value)\", which is not a #rrggbb colour"
    case .renderFailed(let app): "Could not draw the icon of \(app)"
    case .writeFailed(let path): "Could not write \(path)"
    }
  }
}

struct PlaceholderIcon {
  let app: String
  let glyph: String
  let top: String
  let bottom: String
  let ink: String
}

struct ColorTokens {
  private let values: [String: String]

  init(contentsOf url: URL) throws(IconError) {
    struct File: Decodable {
      struct Group: Decodable { let tokens: [Token] }
      struct Token: Decodable {
        let name: String
        let value: Value
      }
      enum Value: Decodable {
        case shared(String)
        case light(String)

        init(from decoder: any Decoder) throws {
          let container = try decoder.singleValueContainer()
          if let value = try? container.decode(String.self) {
            self = .shared(value)
            return
          }
          let themed = try container.decode([String: String].self)
          guard let light = themed["light"] else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Themed values need light") }
          self = .light(light)
        }

        var light: String {
          switch self {
          case .shared(let value), .light(let value): value
          }
        }
      }
      let color: Group
    }
    do {
      let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
      values = Dictionary(file.color.tokens.map { ($0.name, $0.value.light) }) { $1 }
    } catch {
      throw .unreadableTokens(reason: error.localizedDescription)
    }
  }

  func color(_ name: String) throws(IconError) -> CGColor {
    var current = name
    var seen: Set<String> = []
    while let value = values[current], seen.insert(current).inserted {
      guard value.hasPrefix("{"), value.hasSuffix("}") else { return try Self.parse(value, token: name) }
      current = String(value.dropFirst().dropLast())
    }
    throw .unknownToken(current)
  }

  private static func parse(_ hex: String, token: String) throws(IconError) -> CGColor {
    guard hex.count == 7, hex.hasPrefix("#"), let rgb = UInt32(hex.dropFirst(), radix: 16) else { throw .invalidColor(hex, token: token) }
    let channel = { (shift: UInt32) in CGFloat((rgb >> shift) & 0xff) / 255 }
    return CGColor(srgbRed: channel(16), green: channel(8), blue: channel(0), alpha: 1)
  }
}

enum Renderer {
  static func png(of icon: PlaceholderIcon, side: Int, tokens: ColorTokens) throws(IconError) -> Data {
    let gradientColors = [try tokens.color(icon.top), try tokens.color(icon.bottom)] as CFArray
    let size = CGFloat(side)
    guard
      let space = CGColorSpace(name: CGColorSpace.sRGB),
      let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, size * 0.56, nil),
      let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      ),
      let gradient = CGGradient(colorsSpace: space, colors: gradientColors, locations: [0, 1])
    else { throw .renderFailed(app: icon.app) }

    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

    let text = NSAttributedString(
      string: icon.glyph, attributes: [.init(kCTFontAttributeName as String): font, .init(kCTForegroundColorAttributeName as String): try tokens.color(icon.ink)])
    let line = CTLineCreateWithAttributedString(text)
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    context.textPosition = CGPoint(x: (size - bounds.width) / 2 - bounds.minX, y: (size - bounds.height) / 2 - bounds.minY)
    CTLineDraw(line, context)

    let data = NSMutableData()
    guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
      throw .renderFailed(app: icon.app)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw .renderFailed(app: icon.app) }
    return data as Data
  }
}

enum Catalog {
  static let info = #"  "info" : {\#n    "author" : "xcode",\#n    "version" : 1\#n  }"#

  static let root = "{\n\(info)\n}\n"

  static let appIconSet = """
    {
      "images" : [
        {
          "filename" : "AppIcon-1024.png",
          "idiom" : "universal",
          "platform" : "ios",
          "size" : "1024x1024"
        },
        {
          "filename" : "AppIcon-mac-512.png",
          "idiom" : "mac",
          "scale" : "1x",
          "size" : "512x512"
        },
        {
          "filename" : "AppIcon-1024.png",
          "idiom" : "mac",
          "scale" : "2x",
          "size" : "512x512"
        }
      ],
    \(info)
    }

    """
}

let icons = [
  PlaceholderIcon(app: "NovelForge", glyph: "N", top: "accent", bottom: "accent-active", ink: "on-accent"),
  PlaceholderIcon(app: "Memoir", glyph: "M", top: "success-solid", bottom: "green-800", ink: "success-on-solid"),
]

func write(_ data: Data, to url: URL) throws(IconError) {
  do {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
  } catch {
    throw .writeFailed(path: url.path)
  }
}

do {
  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  let tokens = try ColorTokens(contentsOf: root.appending(path: "Design/tokens.json"))
  for icon in icons {
    let catalog = root.appending(path: "Apps/\(icon.app)/Resources/Assets.xcassets")
    let set = catalog.appending(path: "AppIcon.appiconset")
    try write(Data(Catalog.root.utf8), to: catalog.appending(path: "Contents.json"))
    try write(Data(Catalog.appIconSet.utf8), to: set.appending(path: "Contents.json"))
    try write(try Renderer.png(of: icon, side: 1024, tokens: tokens), to: set.appending(path: "AppIcon-1024.png"))
    try write(try Renderer.png(of: icon, side: 512, tokens: tokens), to: set.appending(path: "AppIcon-mac-512.png"))
    print("Wrote \(set.path)")
  }
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(1)
}
