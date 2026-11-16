import ShadowCore

public enum StructuredPrompt {
  /// Appended to the last user message in prompt mode. The schema is canonical JSON, so the same schema always yields the same bytes.
  public static func schemaInstruction(name: String, schema: JSONValue) -> String {
    "Respond with ONLY one valid JSON \(shape(of: schema)) matching this JSON schema (\(name)) — all prose goes inside the JSON string fields, nothing outside the JSON, no markdown fences:\n"
      + StructuredSchema.jsonText(schema)
  }

  private static func shape(of schema: JSONValue) -> String {
    switch StructuredSchema.rootType(of: schema) {
    case "object": "object"
    case "array": "array"
    default: "value"
    }
  }

  /// The user turn of the repair re-ask; the previous output travels as the assistant turn before it, unless it was blank.
  public static func repairRequest(issues: [JSONSchemaIssue], previousOutput: String, schema: JSONValue) -> String {
    let opening = previousOutput.allSatisfy(\.isWhitespace) ? "That response was empty." : "That response could not be used."
    let listed = issues.map { "- \($0.path): \($0.message)" }.joined(separator: "\n")
    return
      "\(opening) Issues:\n\(listed)\n\n"
      + "Respond again with ONLY one valid JSON \(shape(of: schema)) matching the required schema — fix the listed issues, keep the content, no prose outside the JSON, no markdown fences."
  }
}
