import Foundation

enum ReferenceFixture {
  static func data(_ path: String) throws -> Data {
    try Data(contentsOf: packageRoot.appendingPathComponent("Fixtures").appendingPathComponent(path))
  }

  static func decode<Value: Decodable>(_ type: Value.Type = Value.self, from path: String) throws -> Value {
    try JSONDecoder().decode(type, from: data(path))
  }

  private static var packageRoot: URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 { url.deleteLastPathComponent() }
    return url
  }
}
