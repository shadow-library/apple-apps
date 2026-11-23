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
    tap(app, app.staticTexts["The Salt Clock"].firstMatch)
    tap(app, app.buttons["Chapters"].firstMatch)
    tap(app, app.buttons["chapter-1"])
    tap(app, app.buttons["generate-chapter"])
    tap(app, Self.sheetConfirm(in: app, titled: "Generate Chapter"))
    tap(app, Self.sheetConfirm(in: app, titled: "Let the demo use this?"))

    let approve = app.buttons["approve-chapter"]
    XCTAssertTrue(approve.waitForExistence(timeout: Self.generationTimeout), "The draft did not arrive")
    XCTAssertTrue(app.staticTexts["Eleven Minutes Slow"].exists)
    tap(app, approve)
    XCTAssertTrue(app.otherElements["chapter-approved"].waitForExistence(timeout: 30))
  }

  /// A sheet's confirm button sits in its navigation bar on most iPhones but not on every device, so it is found by identifier under the sheet's title.
  @MainActor
  private static func sheetConfirm(in app: XCUIApplication, titled title: String) -> XCUIElement {
    _ = app.navigationBars[title].waitForExistence(timeout: 30)
    return app.buttons.matching(identifier: "shadow-sheet-confirm").firstMatch
  }

  @MainActor
  private func tap(_ app: XCUIApplication, _ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(element.waitForExistence(timeout: 30), "\(element) did not appear in \(app.debugDescription)", file: file, line: line)
    element.tap()
  }
}
