import Foundation
import Testing

@testable import ShadowAI

@Suite("OpenRouter decimal amounts")
struct OpenRouterDecimalTests {
  @Test(
    "should turn a USD amount into nano-USD exactly, rounding half away from zero past nine places",
    arguments: [
      ("0.000001234", 1_234 as Int64?), ("12.5", 12_500_000_000), ("0", 0), ("0.0", 0), ("-0", 0), ("1e-7", 100), ("1.5E+3", 1_500_000_000_000),
      ("2.5e0", 2_500_000_000), (" 0.5 ", 500_000_000), ("0.95", 950_000_000), ("0.123456789123", 123_456_789), ("0.1234567895", 123_456_790),
      ("0.0000000005", 1), ("0.0000000004999", 0), ("1e-999999999", 0), ("9223372036.854775807", .max), ("9223372036.854775808", nil),
      ("99999999999999999999", nil), ("1e999999999", nil), ("-1", nil), ("-0.000000001", nil), ("abc", nil), ("", nil), (".", nil), ("1e", nil),
      ("1.2.3", nil), ("NaN", nil), ("Infinity", nil), ("0x10", nil), ("1_000", nil), ("+3", 3_000_000_000),
    ]
  )
  func convertsUSD(text: String, nanoUSD: Int64?) {
    #expect(OpenRouterDecimal.scaledNonNegative(text, byPowerOfTen: 9) == nanoUSD)
  }

  @Test(
    "should turn a per-token price into nano-USD per million tokens exactly",
    arguments: [
      ("0.00003", 30_000_000_000 as Int64?), ("0.000000075", 75_000_000), ("0.0000000000000004", 0), ("0.0000000000000005", 1), ("0", 0), ("-1", nil),
      ("10000", nil), ("3e-6", 3_000_000_000),
    ]
  )
  func convertsPrices(text: String, perMillion: Int64?) {
    #expect(OpenRouterAmount(text: text).perMillionTokens == perMillion.map(Cost.init(nanoUSD:)))
  }

  @Test("should read a cost given as a JSON number without passing through a float", arguments: ["0.1", "0.000123456789", "3.0000000000000004", "1E-9"])
  func readsJSONNumbers(number: String) throws {
    let amount = try JSONDecoder().decode(OpenRouterAmount.self, from: Data(number.utf8))

    #expect(amount.nanoUSD == OpenRouterDecimal.scaledNonNegative(number, byPowerOfTen: 9).map(Cost.init(nanoUSD:)))
  }

  @Test("should read an out-of-range JSON number as no amount")
  func readsHugeNumberAsNothing() throws {
    let amount = try JSONDecoder().decode(OpenRouterAmount.self, from: Data("1e200".utf8))

    #expect(amount.nanoUSD == nil)
  }

  @Test(
    "should round a JSON-number cost by its digits past the seventeenth, which a binary float cannot hold",
    arguments: [("0.1234567894999999999", Cost(nanoUSD: 123_456_789)), ("0.1234567895000000001", Cost(nanoUSD: 123_456_790))]
  )
  func roundsCostBeyondFloatPrecision(number: String, cost: Cost) throws {
    let chunk = #"{"id":"gen-1","choices":[],"usage":{"prompt_tokens":1,"completion_tokens":1,"cost":"# + number + "}}"

    let usage = try #require(try JSONDecoder().decode(OpenRouterChunk.self, from: Data(chunk.utf8)).usage)

    #expect(usage.cost?.nanoUSD == cost)
  }

  @Test(
    "should round a JSON-number price by its digits past the seventeenth, which a binary float cannot hold",
    arguments: [("0.0000012345678914999999999", Cost(nanoUSD: 1_234_567_891)), ("0.0000012345678915000000001", Cost(nanoUSD: 1_234_567_892))]
  )
  func roundsPriceBeyondFloatPrecision(number: String, price: Cost) throws {
    let list = #"{"data":[{"id":"vendor/model","pricing":{"prompt":"# + number + #","completion":"# + number + "}}]}"

    let model = try #require(try JSONDecoder().decode(OpenRouterModelList.self, from: Data(list.utf8)).data.first?.model)

    #expect(model.inputPrice == price)
    #expect(model.outputPrice == price)
  }
}
