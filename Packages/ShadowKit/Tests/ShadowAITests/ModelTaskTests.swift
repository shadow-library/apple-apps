import Foundation
import Testing

@testable import ShadowAI

@Suite("ModelTask and Pace")
struct ModelTaskTests {
  @Test func shouldPinModelTaskRawValues() {
    #expect(ModelTask.allCases.map(\.rawValue) == ["writing", "planning", "review", "chat", "helper"])
  }

  @Test func shouldPinPaceRawValues() {
    #expect(Pace.allCases.map(\.rawValue) == ["swift", "steady", "meticulous"])
  }

  @Test func shouldOrderPaceFromSwiftToMeticulous() {
    #expect(Pace.swift < Pace.steady)
    #expect(Pace.steady < Pace.meticulous)
    #expect(Pace.allCases.sorted() == [.swift, .steady, .meticulous])
  }

  @Test func shouldRaisePaceOneLevelWhenGoingDeeper() {
    #expect(Pace.swift.deeper == .steady)
    #expect(Pace.steady.deeper == .meticulous)
  }

  @Test func shouldStayAtTopPaceWhenGoingDeeper() {
    #expect(Pace.meticulous.deeper == .meticulous)
  }

  @Test func shouldRoundTripThroughCodable() throws {
    let data = try JSONEncoder().encode(Pace.steady)
    #expect(String(decoding: data, as: UTF8.self) == "\"steady\"")
    #expect(try JSONDecoder().decode(ModelTask.self, from: Data("\"chat\"".utf8)) == .chat)
  }
}
