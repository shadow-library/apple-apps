import Foundation
import JavaScriptCore

enum JSOracleArgument {
  case string(String)
  case number(Double)
  case strings([String])
  case undefined

  fileprivate var encoded: String {
    switch self {
    case .string(let text): "{\"s\":[\(text.utf16.map(String.init).joined(separator: ","))]}"
    case .number(let value): "{\"n\":\"\(JSOracleArgument.numberText(value))\"}"
    case .strings(let texts): "{\"a\":[\(texts.map { JSOracleArgument.string($0).encoded }.joined(separator: ","))]}"
    case .undefined: "{\"u\":1}"
    }
  }

  private static func numberText(_ value: Double) -> String {
    if value.isNaN { return "NaN" }
    if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
    return value == 0 && value.sign == .minus ? "-0" : "\(value)"
  }
}

/// Strings stay UTF-16 code units so a lone surrogate stays visible.
indirect enum JSOracleValue: Equatable, CustomStringConvertible {
  case string([UInt16])
  case number(Double)
  case boolean(Bool)
  case array([JSOracleValue])
  case null
  case undefined

  static func == (left: JSOracleValue, right: JSOracleValue) -> Bool {
    switch (left, right) {
    case (.string(let a), .string(let b)): a == b
    case (.number(let a), .number(let b)): (a.isNaN && b.isNaN) || a.bitPattern == b.bitPattern
    case (.boolean(let a), .boolean(let b)): a == b
    case (.array(let a), .array(let b)): a == b
    case (.null, .null), (.undefined, .undefined): true
    default: false
    }
  }

  var description: String {
    switch self {
    case .string(let units): "\"\(units.map { String($0, radix: 16) }.joined(separator: " "))\""
    case .number(let value): "\(value)"
    case .boolean(let flag): "\(flag)"
    case .array(let values): "[\(values.map(\.description).joined(separator: ", "))]"
    case .null: "null"
    case .undefined: "undefined"
    }
  }
}

struct JSOracleError: Error, CustomStringConvertible {
  let description: String
}

final class JSOracle {
  private static let prelude = """
    globalThis.__decode = function decode(value) {
      if ('s' in value) { let text = ''; for (const unit of value.s) text += String.fromCharCode(unit); return text; }
      if ('n' in value) return Number(value.n);
      if ('a' in value) return value.a.map(decode);
      return undefined;
    };
    globalThis.__encode = function encode(value) {
      if (typeof value === 'string') { const units = []; for (let i = 0; i < value.length; i++) units.push(value.charCodeAt(i)); return { s: units }; }
      if (typeof value === 'number') return { n: Object.is(value, -0) ? '-0' : String(value) };
      if (typeof value === 'boolean') return { b: value };
      if (Array.isArray(value)) return { a: value.map(encode) };
      if (value === null) return { z: 1 };
      if (value === undefined) return { u: 1 };
      throw new TypeError('the oracle cannot return a ' + typeof value);
    };
    globalThis.__run = function run(fn, json) { return JSON.stringify(__encode(fn(...JSON.parse(json).map(__decode)))); };
    """

  private let context: JSContext
  private let runner: JSValue
  private var functions: [String: JSValue] = [:]

  init() throws {
    guard let context = JSContext() else { throw JSOracleError(description: "JavaScriptCore gave no context") }
    context.evaluateScript(Self.prelude)
    guard let runner = context.objectForKeyedSubscript("__run"), runner.isObject else { throw JSOracleError(description: "the oracle prelude did not load") }
    self.context = context
    self.runner = runner
  }

  func call(_ function: String, _ arguments: JSOracleArgument...) throws -> JSOracleValue {
    let compiled = try compile(function)
    context.exception = nil
    let json = "[\(arguments.map(\.encoded).joined(separator: ","))]"
    let output = runner.call(withArguments: [compiled, json])
    if let exception = context.exception { throw JSOracleError(description: "JavaScript threw: \(exception)") }
    guard let text = output?.toString(), let data = text.data(using: .utf8) else { throw JSOracleError(description: "the oracle returned nothing") }
    return try Self.decode(JSONSerialization.jsonObject(with: data))
  }

  private func compile(_ function: String) throws -> JSValue {
    if let known = functions[function] { return known }
    context.exception = nil
    let value = context.evaluateScript("(\(function))")
    if let exception = context.exception { throw JSOracleError(description: "JavaScript did not compile: \(exception)") }
    guard let value, value.isObject else { throw JSOracleError(description: "not a function: \(function)") }
    functions[function] = value
    return value
  }

  private static func decode(_ object: Any) throws -> JSOracleValue {
    guard let tagged = object as? [String: Any] else { throw JSOracleError(description: "unexpected oracle payload \(object)") }
    if let units = tagged["s"] as? [NSNumber] { return .string(units.map(\.uint16Value)) }
    if let number = tagged["n"] as? String { return .number(try decodeNumber(number)) }
    if let flag = tagged["b"] as? Bool { return .boolean(flag) }
    if let values = tagged["a"] as? [Any] { return .array(try values.map(decode)) }
    if tagged["z"] != nil { return .null }
    return .undefined
  }

  private static func decodeNumber(_ text: String) throws -> Double {
    switch text {
    case "NaN": return .nan
    case "Infinity": return .infinity
    case "-Infinity": return -.infinity
    case "-0": return -0.0
    default:
      guard let value = Double(text) else { throw JSOracleError(description: "unreadable number \(text)") }
      return value
    }
  }
}
