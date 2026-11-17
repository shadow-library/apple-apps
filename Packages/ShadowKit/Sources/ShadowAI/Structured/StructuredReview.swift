import Foundation

/// The rules a JSON schema cannot express, run on a candidate only after it fits the schema, as the reference's prompt modules do
/// (novel-forge-server/src/modules/ai/prompts/types.ts:53-58).
public struct StructuredReview: Sendable {
  struct Judgement {
    let blocking: [JSONSchemaIssue]
    let advisory: [JSONSchemaIssue]
  }

  public static let none = StructuredReview { _, _ in Judgement(blocking: [], advisory: []) }

  /// The candidate's issues; advisory ones only when asked, since only the first reply is advised.
  let judge: @Sendable (_ json: Data, _ advises: Bool) -> Judgement

  /// `postValidate` blocks: its issues send the output to the repair, and every accepted output passes it. `advise` is worth one repair but never a
  /// failure: it is judged on the first reply only, and a first reply with only advisory issues is kept when the repair is unusable.
  public init(postValidate: @escaping @Sendable (Data) -> [String] = { _ in [] }, advise: @escaping @Sendable (Data) -> [String] = { _ in [] }) {
    self.init { json, advises in
      Judgement(blocking: postValidate(json).map(Self.rootIssue), advisory: advises ? advise(json).map(Self.rootIssue) : [])
    }
  }

  /// Decodes each candidate once; one that fits the schema but does not decode as `Output` is a blocking issue, so it is repaired like any other.
  public static func decoding<Output: Decodable & SendableMetatype>(
    _ type: Output.Type, decoder: JSONDecoder = JSONDecoder(), postValidate: @escaping @Sendable (Output) -> [String] = { _ in [] },
    advise: @escaping @Sendable (Output) -> [String] = { _ in [] }
  ) -> StructuredReview {
    StructuredReview { json, advises in
      switch decode(type, from: json, with: decoder) {
      case .output(let output):
        Judgement(blocking: postValidate(output).map(rootIssue), advisory: advises ? advise(output).map(rootIssue) : [])
      case .unreadable(let issue):
        Judgement(blocking: [issue], advisory: [])
      }
    }
  }

  private init(judge: @escaping @Sendable (_ json: Data, _ advises: Bool) -> Judgement) {
    self.judge = judge
  }

  private static func rootIssue(_ message: String) -> JSONSchemaIssue {
    JSONSchemaIssue(path: "$", message: message)
  }

  private static func decode<Output: Decodable>(_ type: Output.Type, from json: Data, with decoder: JSONDecoder) -> Decoded<Output> {
    do {
      return .output(try decoder.decode(type, from: json))
    } catch let error as DecodingError {
      return .unreadable(issue(for: error))
    } catch {
      return .unreadable(rootIssue("could not be read: \(error.localizedDescription)"))
    }
  }

  private static func issue(for error: DecodingError) -> JSONSchemaIssue {
    let context: DecodingError.Context
    switch error {
    case .typeMismatch(_, let found), .valueNotFound(_, let found), .keyNotFound(_, let found), .dataCorrupted(let found): context = found
    @unknown default: return rootIssue("could not be read")
    }
    let path = StructuredPathComponent.render(context.codingPath.map { $0.intValue.map(StructuredPathComponent.index) ?? .key($0.stringValue) })
    return JSONSchemaIssue(path: path, message: "could not be read: \(context.debugDescription)")
  }
}

private enum Decoded<Output> {
  case output(Output)
  case unreadable(JSONSchemaIssue)
}
