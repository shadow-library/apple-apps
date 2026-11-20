import ShadowText

public struct Mismatch: Error, CustomStringConvertible {
  public let description: String

  public init(description: String) {
    self.description = description
  }
}

public protocol OracleComparable {
  var oracleValue: JSOracleValue { get }
}

extension String: OracleComparable {
  public var oracleValue: JSOracleValue { .string(Array(utf16)) }
}

extension Int: OracleComparable {
  public var oracleValue: JSOracleValue { .number(Double(self)) }
}

extension Double: OracleComparable {
  public var oracleValue: JSOracleValue { .number(self) }
}

extension Bool: OracleComparable {
  public var oracleValue: JSOracleValue { .boolean(self) }
}

extension UInt16: OracleComparable {
  public var oracleValue: JSOracleValue { .number(Double(self)) }
}

extension Optional: OracleComparable where Wrapped == UInt16 {
  public var oracleValue: JSOracleValue { map(\.oracleValue) ?? .number(.nan) }
}

extension JSOracleValue: OracleComparable {
  public var oracleValue: JSOracleValue { self }
}

extension Array: OracleComparable where Element: OracleComparable {
  public var oracleValue: JSOracleValue { .array(map(\.oracleValue)) }
}

extension JSOracleValue {
  public var droppingLoneSurrogates: JSOracleValue {
    switch self {
    case .string(let units): .string(Array(JSText.string(fromCodeUnits: units).utf16))
    case .array(let values): .array(values.map(\.droppingLoneSurrogates))
    default: self
    }
  }
}

public func expectSame(_ swift: some OracleComparable, _ javaScript: JSOracleValue, _ input: @autoclosure () -> String) throws {
  guard swift.oracleValue == javaScript.droppingLoneSurrogates else {
    throw Mismatch(description: "Swift \(swift.oracleValue) but JavaScript \(javaScript) for \(input())")
  }
}

public func expectExactlySame(_ swift: some OracleComparable, _ javaScript: JSOracleValue, _ input: @autoclosure () -> String) throws {
  guard swift.oracleValue == javaScript else { throw Mismatch(description: "Swift \(swift.oracleValue) but JavaScript \(javaScript) for \(input())") }
}

public func describe(_ text: String) -> String {
  "\"\(text.unicodeScalars.map { $0.isASCII && $0.value >= 0x20 ? String($0) : "\\u{\(String($0.value, radix: 16))}" }.joined())\""
}
