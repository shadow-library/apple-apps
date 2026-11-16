import Foundation
import Testing

@testable import ShadowAI

@Suite("ModelCatalog decoding")
struct CatalogFormatTests {
  static func json(format: Int = 1, extraRoot: String = "", extraModel: String = "", effort: String = "low", efforts: String = "[\"low\", \"turbo\"]", extraTask: String = "")
    -> Data
  {
    Data(
      """
      {
        "format": \(format), "revision": 7, \(extraRoot)
        "models": [{
          "id": "a", "contextTokens": 1000, "maxOutputTokens": 100, "efforts": \(efforts), "supportsJSONSchema": true, \(extraModel)
          "pricing": {"input": 1, "output": 2, "cacheRead": 3, "cacheWriteShort": 4, "cacheWriteLong": 5},
          "retiresOn": "2027-01-31", "successors": []
        }],
        "routes": { \(extraTask) "chat": { "swift": {"model": "a", "effort": "\(effort)", "maxOutputTokens": 50}, "warp": {"model": "a", "maxOutputTokens": 50} } }
      }
      """.utf8
    )
  }

  @Test func shouldRefuseAFormatAboveTheCurrentOne() {
    #expect(throws: CatalogError.unsupportedFormat(found: 2, supported: 1)) { try ModelCatalog(decoding: Self.json(format: 2)) }
  }

  @Test func shouldRefuseANewerFormatEvenWhenItsShapeChanged() {
    #expect(throws: CatalogError.unsupportedFormat(found: 3, supported: 1)) { try ModelCatalog(decoding: Data("{\"format\": 3, \"models\": 5}".utf8)) }
  }

  @Test func shouldIgnoreUnknownMembersLevelsTasksAndPaces() throws {
    let data = Self.json(extraRoot: "\"mirror\": \"x\",", extraModel: "\"vision\": true,", extraTask: "\"dreaming\": {\"swift\": {\"model\": \"a\", \"maxOutputTokens\": 1}},")
    let catalog = try ModelCatalog(decoding: data)
    #expect(catalog.revision == 7)
    #expect(catalog.models.first?.efforts == [.low])
    #expect(catalog.models.first?.retiresOn == CatalogFixtures.date("2027-01-31"))
    #expect(catalog.routes.keys.sorted { $0.rawValue < $1.rawValue } == [.chat])
    #expect(catalog.routes[.chat]?.keys.sorted() == [.swift])
  }

  @Test func shouldReportMalformedJSON() {
    #expect(throws: CatalogError.self) { try ModelCatalog(decoding: Data("nope".utf8)) }
  }

  @Test func shouldReportAnUnknownEffortOnARoute() {
    #expect(throws: CatalogError.self) { try ModelCatalog(decoding: Self.json(effort: "turbo")) }
  }

  @Test func shouldReportAnInvalidRetirementDate() {
    let data = Data(String(decoding: Self.json(), as: UTF8.self).replacingOccurrences(of: "2027-01-31", with: "2027-02-31").utf8)
    #expect(throws: CatalogError.self) { try ModelCatalog(decoding: data) }
  }

  @Test func shouldEncodeDeterministically() throws {
    let catalog = try ModelCatalog(decoding: Self.json())
    #expect(catalog.encoded() == catalog.encoded())
    #expect(try ModelCatalog(decoding: catalog.encoded()) == catalog)
  }

  @Test func shouldDescribeErrorsInWords() {
    #expect(CatalogError.unsupportedFormat(found: 2, supported: 1).errorDescription?.contains("format 2") == true)
    #expect(CatalogError.malformed("x").code == "catalog.malformed")
  }
}

@Suite("OpenRouterAssignments")
struct CatalogOpenRouterTests {
  static let assignments = OpenRouterAssignments(models: [.swift: "vendor/fast", .steady: "vendor/balanced"], unrestricted: "vendor/open")

  @Test func shouldRoundTripThroughJSON() throws {
    let data = try JSONEncoder().encode(Self.assignments)
    #expect(try JSONDecoder().decode(OpenRouterAssignments.self, from: data) == Self.assignments)
  }

  @Test func shouldEncodePacesAsNames() throws {
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.assignments))
    let models = (object as? [String: Any])?["models"] as? [String: String]
    #expect(models == ["swift": "vendor/fast", "steady": "vendor/balanced"])
  }

  @Test func shouldIgnoreUnknownPacesWhenDecoding() throws {
    let data = Data("{\"models\": {\"swift\": \"a\", \"warp\": \"b\"}}".utf8)
    #expect(try JSONDecoder().decode(OpenRouterAssignments.self, from: data) == OpenRouterAssignments(models: [.swift: "a"]))
  }

  @Test func shouldRouteAnAssignedPaceWithoutEffort() {
    #expect(Self.assignments.route(for: .swift, maxOutputTokens: 800) == CatalogRoute(model: "vendor/fast", effort: nil, maxOutputTokens: 800))
  }

  @Test func shouldNotRouteAnUnassignedPace() {
    #expect(Self.assignments.route(for: .meticulous, maxOutputTokens: 800) == nil)
  }

  @Test func shouldNotRouteABlankModelOrAnInvalidCap() {
    #expect(OpenRouterAssignments(models: [.swift: "  "]).route(for: .swift, maxOutputTokens: 800) == nil)
    #expect(Self.assignments.route(for: .swift, maxOutputTokens: 0) == nil)
  }
}
