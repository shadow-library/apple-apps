public enum CredentialStatus: Sendable, Equatable {
  case valid(label: String?)
  case invalid
  case unverified(ModelError)
}

public struct RemoteModel: Sendable, Equatable, Codable {
  public var id: String
  public var name: String?
  public var contextLength: Int?
  public var maxOutputTokens: Int?
  public var supportsJSONSchema: Bool?
  /// Per million input tokens.
  public var inputPrice: Cost?
  /// Per million output tokens.
  public var outputPrice: Cost?

  public init(
    id: String,
    name: String? = nil,
    contextLength: Int? = nil,
    maxOutputTokens: Int? = nil,
    supportsJSONSchema: Bool? = nil,
    inputPrice: Cost? = nil,
    outputPrice: Cost? = nil
  ) {
    self.id = id
    self.name = name
    self.contextLength = contextLength
    self.maxOutputTokens = maxOutputTokens
    self.supportsJSONSchema = supportsJSONSchema
    self.inputPrice = inputPrice
    self.outputPrice = outputPrice
  }
}

public protocol ModelProvider: Sendable {
  /// The request is sent on the stream's first iteration; a stream that is never iterated costs nothing.
  func stream(_ request: ModelRequest) -> ModelStream
  func validate(_ credential: ProviderCredential) async throws(ModelError) -> CredentialStatus
  func models() async throws(ModelError) -> [RemoteModel]
}
