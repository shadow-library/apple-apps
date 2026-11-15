import XCTest

nonisolated final class TableLoadingAccessibilityTests: XCTestCase {
  private let placeholderStrings = ["welcome-email", "Delivered"]
  private let loadingLabel = "Loading deliveries"

  @MainActor
  func testShouldExposeTheLoadingTableAsOneLabelledElementWithoutPlaceholderText() throws {
    let app = XCUIApplication()
    app.launchArguments = ["-component", "table", "-appearance", "light", "-scroll", "1"]
    app.launch()
    XCTAssertTrue(app.staticTexts["Loading"].waitForExistence(timeout: 10))

    let elements = flatten(try app.snapshot())
    let sectionTop = try XCTUnwrap(elements.first { $0.elementType == .staticText && $0.label == "Loading" }).frame.maxY
    let sectionBottom = elements.first { $0.elementType == .staticText && $0.label == "Empty" }?.frame.minY ?? .infinity
    let section = elements.filter { $0.frame.midY > sectionTop && $0.frame.midY < sectionBottom }

    let leaks = section.filter { element in placeholderStrings.contains { element.label.contains($0) || "\(element.value ?? "")".contains($0) } }
    XCTAssertTrue(leaks.isEmpty, "Placeholder text is exposed: \(leaks.map(\.label))")
    XCTAssertEqual(elements.filter { $0.label == loadingLabel }.count, 1)
    let rowEdges = Set(section.filter { $0.elementType == .cell }.map(\.frame.minY))
    XCTAssertLessThanOrEqual(rowEdges.count, 1, "Only the native header row may expose cells")
  }

  private func flatten(_ snapshot: any XCUIElementSnapshot) -> [any XCUIElementSnapshot] {
    [snapshot] + snapshot.children.flatMap(flatten)
  }
}
