import UIKit
import XCTest

nonisolated final class CatalogShotTests: XCTestCase {
  private struct Shot {
    let component: String
    let appearance: String
    let scroll: String
    let screen: String
    let file: URL

    init?(line: Substring) {
      let fields = line.split(separator: "\t")
      guard fields.count == 5 else { return nil }
      component = String(fields[0])
      appearance = String(fields[1])
      scroll = String(fields[2])
      screen = fields[3] == "-" ? "" : String(fields[3])
      file = URL(filePath: String(fields[4]))
    }

    var launchArguments: [String] {
      let base = ["-component", component, "-appearance", appearance, "-scroll", scroll, "-capture-poll", String(CatalogShotTests.pollInterval)]
      return screen.isEmpty ? base : base + ["-screen", screen]
    }
  }

  fileprivate static let pollInterval: TimeInterval = 0.3
  private let settlePolls = 10

  @MainActor
  func testShouldCaptureEveryShotInThePlanInLandscape() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["CATALOG_SHOT_PLAN"] != nil, "Set by scripts/catalog-screenshots.sh; not a regression test")
    let planPath = try XCTUnwrap(ProcessInfo.processInfo.environment["CATALOG_SHOT_PLAN"])
    let plan = try String(contentsOfFile: planPath, encoding: .utf8).split(separator: "\n").compactMap(Shot.init(line:))
    XCTAssertFalse(plan.isEmpty)
    addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
    XCUIDevice.shared.orientation = .landscapeLeft
    for shot in plan {
      let app = XCUIApplication()
      app.launchArguments = shot.launchArguments
      app.launch()
      XCUIDevice.shared.orientation = .landscapeLeft
      let upright = try XCTUnwrap(uprightPNG(UIImage(data: settledScreenshot())))
      try upright.write(to: shot.file)
    }
  }

  @MainActor
  private func settledScreenshot() -> Data {
    Thread.sleep(forTimeInterval: 1.5)
    var previous = XCUIScreen.main.screenshot().pngRepresentation
    for _ in 0..<settlePolls {
      Thread.sleep(forTimeInterval: Self.pollInterval)
      let current = XCUIScreen.main.screenshot().pngRepresentation
      if current == previous { return current }
      previous = current
    }
    return previous
  }

  private func uprightPNG(_ image: UIImage?) -> Data? {
    guard let image else { return nil }
    let format = UIGraphicsImageRendererFormat()
    format.scale = image.scale
    return UIGraphicsImageRenderer(size: image.size, format: format).pngData { _ in image.draw(at: .zero) }
  }
}
