import Foundation
import MemoirCore
import Testing

struct FinanceDivergence: Decodable {
  let file: String
  let function: String
  let id: String
  let reason: String
  let reference: FixtureValue
  let exact: FixtureValue
}

struct FinanceDivergenceList: Decodable {
  let count: Int
  let cases: [FinanceDivergence]
}

struct CurrencyFixture: Decodable {
  let codes: [String]
  let exponents: [String: Int]
}

enum FinanceVectors {
  static func load<Value: Decodable>(_ type: Value.Type, _ file: String) throws -> Value {
    try JSONDecoder().decode(type, from: RuleVectors.data("finance/\(file)"))
  }

  static func cases(_ file: String, _ function: String) throws -> [RuleCase] {
    let groups = try load([String: [RuleCase]].self, file)
    guard let cases = groups[function], !cases.isEmpty else { throw FixtureError.malformed("\(file) has no \(function) cases") }
    return cases
  }

  static func divergences(_ file: String, _ function: String) throws -> [String: FinanceDivergence] {
    let list = try load(FinanceDivergenceList.self, "divergences.json")
    #expect(list.count == list.cases.count, "divergences.json miscounts its cases")
    return Dictionary(uniqueKeysWithValues: list.cases.filter { $0.file == file && $0.function == function }.map { ($0.id, $0) })
  }

  /// Every vector must equal the reference, except a listed divergence, which must equal the exact model and differ from the reference.
  static func check(
    _ file: String, _ function: String, sourceLocation: SourceLocation = #_sourceLocation, evaluate: (FixtureValue) async throws -> FixtureValue
  ) async throws {
    let listed = try divergences(file, function)
    var mismatches: [String] = []
    var visited = Set<String>()
    let vectors = try cases(file, function)
    for vector in vectors {
      let native: FixtureValue
      do {
        native = try await evaluate(vector.input)
      } catch let error as FinanceError {
        native = .string("error: \(error.code)")
      }
      guard let divergence = listed[vector.id] else {
        if native != vector.output { mismatches.append("\(vector.id): native \(native) reference \(vector.output)") }
        continue
      }
      visited.insert(vector.id)
      if native != divergence.exact { mismatches.append("\(vector.id): native \(native) exact \(divergence.exact)") }
      if native == vector.output { mismatches.append("\(vector.id): listed as divergent but native matches the reference \(vector.output)") }
    }
    #expect(visited == Set(listed.keys), "divergences name vectors that do not exist", sourceLocation: sourceLocation)
    #expect(mismatches.isEmpty, "\(mismatches.count) of \(vectors.count) mismatch, first: \(mismatches.prefix(10).joined(separator: "\n"))", sourceLocation: sourceLocation)
  }
}

extension FixtureValue {
  var currency: CurrencyCode {
    get throws {
      guard let code = CurrencyCode(try string) else { throw FixtureError.malformed("\(self) is not a currency code") }
      return code
    }
  }

  var decimal: DecimalText {
    get throws {
      guard let text = DecimalText(try string) else { throw FixtureError.malformed("\(self) is not a canonical decimal") }
      return text
    }
  }

  var optionalDecimal: DecimalText? {
    get throws {
      if case .null = self { return nil }
      return try decimal
    }
  }

  static func minor(_ value: Int64?) -> FixtureValue {
    value.map { .int(Int($0)) } ?? .null
  }
}
