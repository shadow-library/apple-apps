import ShadowCore
import ShadowText

func pipelineText(minLength: Int? = nil, maxLength: Int? = nil, description: String? = nil) -> OrderedJSON {
  var fields: [(String, OrderedJSON)] = [("type", .string("string"))]
  if let minLength { fields.append(("minLength", .int(Int64(minLength)))) }
  if let maxLength { fields.append(("maxLength", .int(Int64(maxLength)))) }
  if let description { fields.append(("description", .string(description))) }
  return jsonObject(fields)
}

func pipelineChoice(_ values: [String]) -> OrderedJSON {
  jsonObject([("type", .string("string")), ("enum", .array(values.map { .string($0) }))])
}

func pipelineFlag(_ description: String? = nil) -> OrderedJSON {
  jsonObject([("type", .string("boolean"))] + (description.map { [("description", OrderedJSON.string($0))] } ?? []))
}

func pipelineWhole(minimum: Int, description: String) -> OrderedJSON {
  jsonObject([("type", .string("integer")), ("minimum", .int(Int64(minimum))), ("description", .string(description))])
}

func pipelineList(_ items: OrderedJSON, minItems: Int? = nil, description: String? = nil) -> OrderedJSON {
  var fields: [(String, OrderedJSON)] = [("type", .string("array")), ("items", items)]
  if let minItems { fields.append(("minItems", .int(Int64(minItems)))) }
  if let description { fields.append(("description", .string(description))) }
  return jsonObject(fields)
}

func pipelineShape(_ properties: [(String, OrderedJSON)], required: [String]) -> OrderedJSON {
  jsonObject([
    ("type", .string("object")), ("additionalProperties", .bool(false)), ("properties", jsonObject(properties)), ("required", .array(required.map { .string($0) })),
  ])
}
