import Foundation

public struct ModelPricing: Sendable, Equatable, Codable {
  public var input: Cost
  public var output: Cost
  public var cacheRead: Cost
  public var cacheWriteShort: Cost
  public var cacheWriteLong: Cost

  public init(input: Cost, output: Cost, cacheRead: Cost, cacheWriteShort: Cost, cacheWriteLong: Cost) {
    self.input = input
    self.output = output
    self.cacheRead = cacheRead
    self.cacheWriteShort = cacheWriteShort
    self.cacheWriteLong = cacheWriteLong
  }
}

/// A request whose prompt (input plus cache reads and writes) exceeds `aboveTokens` is priced entirely at `pricing`.
public struct CatalogLongPromptPricing: Sendable, Equatable, Codable {
  public var aboveTokens: Int
  public var pricing: ModelPricing

  public init(aboveTokens: Int, pricing: ModelPricing) {
    self.aboveTokens = aboveTokens
    self.pricing = pricing
  }
}

public struct CatalogModel: Sendable, Equatable, Codable {
  public var id: String
  public var contextTokens: Int
  public var maxOutputTokens: Int
  public var efforts: [Effort]
  public var supportsJSONSchema: Bool
  public var pricing: ModelPricing
  public var longPrompt: CatalogLongPromptPricing?
  public var retiresOn: CatalogDate?
  public var successors: [String]

  public init(
    id: String,
    contextTokens: Int,
    maxOutputTokens: Int,
    efforts: [Effort],
    supportsJSONSchema: Bool,
    pricing: ModelPricing,
    longPrompt: CatalogLongPromptPricing? = nil,
    retiresOn: CatalogDate? = nil,
    successors: [String] = []
  ) {
    self.id = id
    self.contextTokens = contextTokens
    self.maxOutputTokens = maxOutputTokens
    self.efforts = efforts
    self.supportsJSONSchema = supportsJSONSchema
    self.pricing = pricing
    self.longPrompt = longPrompt
    self.retiresOn = retiresOn
    self.successors = successors
  }

  private enum CodingKeys: String, CodingKey {
    case id, contextTokens, maxOutputTokens, efforts, supportsJSONSchema, pricing, longPrompt, retiresOn, successors
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    contextTokens = try container.decode(Int.self, forKey: .contextTokens)
    maxOutputTokens = try container.decode(Int.self, forKey: .maxOutputTokens)
    efforts = try (container.decodeIfPresent([String].self, forKey: .efforts) ?? []).compactMap(Effort.init(rawValue:))
    supportsJSONSchema = try container.decode(Bool.self, forKey: .supportsJSONSchema)
    pricing = try container.decode(ModelPricing.self, forKey: .pricing)
    longPrompt = try container.decodeIfPresent(CatalogLongPromptPricing.self, forKey: .longPrompt)
    retiresOn = try container.decodeIfPresent(CatalogDate.self, forKey: .retiresOn)
    successors = try container.decodeIfPresent([String].self, forKey: .successors) ?? []
  }

  func pricing(forPromptTokens tokens: Int) -> ModelPricing {
    guard let longPrompt, tokens > longPrompt.aboveTokens else { return pricing }
    return longPrompt.pricing
  }

  func accepts(_ effort: Effort) -> Bool {
    efforts.contains(effort)
  }

  func nearestEffort(to effort: Effort) -> Effort? {
    guard !accepts(effort) else { return effort }
    let sorted = efforts.sorted()
    return sorted.last { $0 < effort } ?? sorted.first
  }
}

public struct CatalogRoute: Sendable, Equatable, Codable {
  public var model: String
  public var effort: Effort?
  public var maxOutputTokens: Int

  public init(model: String, effort: Effort? = nil, maxOutputTokens: Int) {
    self.model = model
    self.effort = effort
    self.maxOutputTokens = maxOutputTokens
  }
}

public struct ModelCatalog: Sendable, Equatable, Codable {
  public static let currentFormat = 1

  public var format: Int
  public var revision: Int
  public var models: [CatalogModel]
  public var routes: [ModelTask: [Pace: CatalogRoute]]

  public init(format: Int = ModelCatalog.currentFormat, revision: Int, models: [CatalogModel], routes: [ModelTask: [Pace: CatalogRoute]]) {
    self.format = format
    self.revision = revision
    self.models = models
    self.routes = routes
  }

  public init(decoding data: Data) throws(CatalogError) {
    let decoder = JSONDecoder()
    do {
      let header = try decoder.decode(Header.self, from: data)
      guard header.format <= Self.currentFormat else { throw CatalogError.unsupportedFormat(found: header.format, supported: Self.currentFormat) }
      self = try decoder.decode(ModelCatalog.self, from: data)
    } catch let error as CatalogError {
      throw error
    } catch {
      throw CatalogError.malformed(String(describing: error))
    }
  }

  public func encoded() -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(self)) ?? Data()
  }

  public func model(_ id: String) -> CatalogModel? {
    models.first { $0.id == id }
  }

  public func route(for task: ModelTask, pace: Pace, deeper: Bool = false) -> CatalogRoute? {
    guard var route = routes[task]?[pace] else { return nil }
    guard deeper, let effort = route.effort, let model = model(route.model), model.accepts(effort.raised) else { return route }
    route.effort = effort.raised
    return route
  }

  public func cost(of usage: TokenUsage, model id: String) -> Cost? {
    guard let model = model(id) else { return nil }
    let counts = [usage.input, usage.cacheRead, usage.cacheWriteShort, usage.cacheWriteLong].map { max($0, 0) }
    let promptTokens = counts.reduce(0) { $0.addingReportingOverflow($1).overflow ? Int.max : $0 + $1 }
    let pricing = model.pricing(forPromptTokens: promptTokens)
    let parts = [
      (usage.input, pricing.input),
      (usage.output, pricing.output),
      (usage.cacheRead, pricing.cacheRead),
      (usage.cacheWriteShort, pricing.cacheWriteShort),
      (usage.cacheWriteLong, pricing.cacheWriteLong),
    ]
    let total = parts.reduce(Int64(0)) { sum, part in
      let (next, overflow) = sum.addingReportingOverflow(Self.nanoUSD(tokens: part.0, pricePerMillion: part.1))
      return overflow ? Int64.max : next
    }
    return Cost(nanoUSD: total)
  }

  private static let tokensPerPrice: UInt64 = 1_000_000

  private static func nanoUSD(tokens: Int, pricePerMillion: Cost) -> Int64 {
    let product = UInt64(max(tokens, 0)).multipliedFullWidth(by: UInt64(max(pricePerMillion.nanoUSD, 0)))
    guard product.high < tokensPerPrice else { return Int64.max }
    let division = tokensPerPrice.dividingFullWidth(product)
    let floor = Int64(clamping: division.quotient)
    return division.remainder >= tokensPerPrice / 2 && floor < Int64.max ? floor + 1 : floor
  }

  private struct Header: Decodable {
    let format: Int
  }

  private enum CodingKeys: String, CodingKey {
    case format, revision, models, routes
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    format = try container.decode(Int.self, forKey: .format)
    revision = try container.decode(Int.self, forKey: .revision)
    models = try container.decode([CatalogModel].self, forKey: .models)
    let named = try container.decode([String: [String: CatalogRoute]].self, forKey: .routes)
    var routes: [ModelTask: [Pace: CatalogRoute]] = [:]
    for (taskName, paces) in named {
      guard let task = ModelTask(rawValue: taskName) else { continue }
      routes[task] = Dictionary(uniqueKeysWithValues: paces.compactMap { name, route in Pace(rawValue: name).map { ($0, route) } })
    }
    self.routes = routes
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(format, forKey: .format)
    try container.encode(revision, forKey: .revision)
    try container.encode(models, forKey: .models)
    let named = Dictionary(
      uniqueKeysWithValues: routes.map { task, paces in (task.rawValue, Dictionary(uniqueKeysWithValues: paces.map { ($0.key.rawValue, $0.value) })) }
    )
    try container.encode(named, forKey: .routes)
  }
}
