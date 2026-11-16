import Foundation

public struct OpenRouterAssignments: Sendable, Equatable, Codable {
  public var models: [Pace: String]
  public var unrestricted: String?

  public init(models: [Pace: String] = [:], unrestricted: String? = nil) {
    self.models = models
    self.unrestricted = unrestricted
  }

  public func route(for pace: Pace, maxOutputTokens: Int) -> CatalogRoute? {
    guard maxOutputTokens >= 1, let model = models[pace]?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else { return nil }
    return CatalogRoute(model: model, effort: nil, maxOutputTokens: maxOutputTokens)
  }

  private enum CodingKeys: String, CodingKey {
    case models
    case unrestricted
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let named = try container.decodeIfPresent([String: String].self, forKey: .models) ?? [:]
    models = Dictionary(uniqueKeysWithValues: named.compactMap { name, model in Pace(rawValue: name).map { ($0, model) } })
    unrestricted = try container.decodeIfPresent(String.self, forKey: .unrestricted)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Dictionary(uniqueKeysWithValues: models.map { ($0.key.rawValue, $0.value) }), forKey: .models)
    try container.encodeIfPresent(unrestricted, forKey: .unrestricted)
  }
}
