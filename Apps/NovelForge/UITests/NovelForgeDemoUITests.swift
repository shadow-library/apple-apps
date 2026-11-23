import XCTest

nonisolated final class NovelForgeDemoUITests: XCTestCase {
  private static let generationTimeout: TimeInterval = 180

  @MainActor
  func testShouldWriteAndApproveTheFirstChapterOfTheSampleNovelInTheDemo() throws {
    try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "The walk follows the compact layout of an iPhone")
    let app = XCUIApplication()
    app.launchArguments = ["-ShadowDemo", "-ShadowUITest"]
    app.launch()

    XCTAssertTrue(app.otherElements["demo-banner"].waitForExistence(timeout: 30))
    tap(app.staticTexts["The Salt Clock"].firstMatch)
    tap(app.buttons["Chapters"].firstMatch)
    tap(app.buttons["chapter-1"])
    tap(app.buttons["generate-chapter"])
    tap(app.navigationBars["Generate Chapter"].buttons["Generate"])
    tap(app.navigationBars["Let the demo use this?"].buttons["Allow"])

    let approve = app.buttons["approve-chapter"]
    XCTAssertTrue(approve.waitForExistence(timeout: Self.generationTimeout), "The draft did not arrive")
    XCTAssertTrue(app.staticTexts["Eleven Minutes Slow"].exists)
    tap(approve)
    XCTAssertTrue(app.otherElements["chapter-approved"].waitForExistence(timeout: 30))
  }

  @MainActor
  private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(element.waitForExistence(timeout: 30), "\(element) did not appear", file: file, line: line)
    element.tap()
  }
}
