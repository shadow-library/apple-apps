import Foundation
import ShadowText

func optionalText(_ value: String?) -> OrderedJSON { value.map(OrderedJSON.string) ?? .null }

func optionalList(_ value: [String]?) -> OrderedJSON { value.map { .array($0.map(OrderedJSON.string)) } ?? .null }

func optionalNumber(_ value: Int?) -> OrderedJSON { value.map { .int(Int64($0)) } ?? .null }

func jsonRecord(_ pairs: [(String, OrderedJSON)]) -> OrderedJSONObject {
  guard case .object(let record) = jsonObject(pairs) else { return OrderedJSONObject([]) }
  return record
}
