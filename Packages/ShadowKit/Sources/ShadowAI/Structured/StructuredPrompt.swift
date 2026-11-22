import Foundation
import ShadowCore

public enum StructuredPrompt {
  private static let instructionOpening = "Respond with ONLY one valid JSON "
  private static let repairOpenings = (empty: "That response was empty.", unusable: "That response could not be used.")
  private static let instructionSchemaLead = " matching this JSON schema ("
  private static let instructionSchemaTail = ") — all prose goes inside the JSON string fields, nothing outside the JSON, no markdown fences:\n"

  /// Appended to the last user message in prompt mode. The schema is canonical JSON, so the same schema always yields the same bytes.
  public static func schemaInstruction(name: String, schema: JSONValue) -> String {
    instructionOpening + shape(of: schema) + instructionSchemaLead + name + instructionSchemaTail + StructuredSchema.jsonText(schema)
  }

  /// The name and schema of the `schemaInstruction` that ends `text`, and the text before it; nil when `text` does not end with one.
  static func schemaInstruction(ending text: String) -> (prompt: String, name: String, schema: JSONValue)? {
    guard
      let tail = text.range(of: instructionSchemaTail, options: .backwards),
      let schema = try? CanonicalJSON.decode(Data(text[tail.upperBound...].utf8)),
      let lead = text.range(of: instructionSchemaLead, options: .backwards, range: text.startIndex..<tail.lowerBound),
      let opening = text.range(of: instructionOpening, options: .backwards, range: text.startIndex..<lead.lowerBound)
    else { return nil }
    let prompt = text[..<opening.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    return (prompt, String(text[lead.upperBound..<tail.lowerBound]), schema)
  }

  private static func shape(of schema: JSONValue) -> String {
    switch StructuredSchema.rootType(of: schema) {
    case "object": "object"
    case "array": "array"
    default: "value"
    }
  }

  static func isRepairRequest(_ text: String) -> Bool {
    text.hasPrefix(repairOpenings.empty + " Issues:\n") || text.hasPrefix(repairOpenings.unusable + " Issues:\n")
  }

  /// The user turn of the repair re-ask; the previous output travels as the assistant turn before it, unless it was blank.
  public static func repairRequest(issues: [JSONSchemaIssue], previousOutput: String, schema: JSONValue) -> String {
    let opening = previousOutput.allSatisfy(\.isWhitespace) ? repairOpenings.empty : repairOpenings.unusable
    let listed = issues.map { "- \($0.path): \($0.message)" }.joined(separator: "\n")
    return
      "\(opening) Issues:\n\(listed)\n\n"
      + "Respond again with ONLY one valid JSON \(shape(of: schema)) matching the required schema — fix the listed issues, keep the content, no prose outside the JSON, no markdown fences."
  }
}
