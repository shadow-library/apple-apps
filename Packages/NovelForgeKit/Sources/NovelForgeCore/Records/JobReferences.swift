import Foundation
import ShadowCore
import ShadowJobs
import ShadowStore

extension EntityKey: JSONRepresentable {
  public init?(json: JSONValue) {
    guard let text = json.stringValue else { return nil }
    self.init(text)
  }

  public var json: JSONValue { .string(rawValue) }
}

extension AttemptID: JSONRepresentable {
  public init?(json: JSONValue) {
    guard let id = UUID(json: json), let attempt = try? AttemptID(id) else { return nil }
    self = attempt
  }

  public var json: JSONValue { uuid.json }
}
