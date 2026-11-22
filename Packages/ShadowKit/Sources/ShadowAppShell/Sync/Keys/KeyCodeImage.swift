import CoreImage
import CoreImage.CIFilterBuiltins
import ShadowDesignSystem
import SwiftUI

/// A QR code of an exchange payload, dark modules on a light quiet zone drawn into the image itself, since scanners need that contrast in either theme.
struct KeyCodeImage: View {
  let payload: String

  var body: some View {
    if let image = KeyCodeRenderer.image(for: payload) {
      Image(decorative: image, scale: 1)
        .resizable()
        .interpolation(.none)
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 300)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel(Text("QR code for your other device", tableName: "SyncKeys", bundle: .module))
        .frame(maxWidth: .infinity)
    } else {
      ShadowValidationMessage(Text("The code could not be drawn. Copy its text instead.", tableName: "SyncKeys", bundle: .module))
    }
  }
}

nonisolated enum KeyCodeRenderer {
  static let quietZoneModules: CGFloat = 4
  static let pointsPerModule: CGFloat = 10

  static func image(for payload: String) -> CGImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(payload.utf8)
    filter.correctionLevel = "M"
    guard let code = filter.outputImage else { return nil }
    let scaled = code.transformed(by: CGAffineTransform(scaleX: pointsPerModule, y: pointsPerModule))
    let margin = quietZoneModules * pointsPerModule
    let canvas = scaled.extent.insetBy(dx: -margin, dy: -margin)
    let framed = scaled.composited(over: CIImage(color: .white).cropped(to: canvas))
    return CIContext().createCGImage(framed, from: canvas)
  }
}
