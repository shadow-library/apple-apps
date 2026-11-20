/// Turns texts into vectors of one model. Vectors are only ever compared with vectors of the same `model`, so the identity changes whenever two vectors would
/// not be comparable: another framework model, language, revision, dimension or way of preparing the input.
public protocol Embedder: Sendable {
  var model: String { get }
  var dimension: Int { get }

  /// One element per text, in order; nil when this text could not be embedded, which is recorded and not retried until the text or the model changes.
  func embed(_ texts: [String]) async -> [[Float]?]
}

/// Chooses the embedder for a novel from a sample of its indexed text, or none when the system has no model for it, in which case search is FTS only.
public protocol EmbedderProvider: Sendable {
  func embedder(forSample sample: String) async -> (any Embedder)?

  /// The embedder whose `model` is exactly `model`, so a search can embed its query without reading the novel's text again; nil when the system's model
  /// is no longer that one (another revision or dimension) or the identity is not this provider's.
  func embedder(forModel model: String) async -> (any Embedder)?
}
