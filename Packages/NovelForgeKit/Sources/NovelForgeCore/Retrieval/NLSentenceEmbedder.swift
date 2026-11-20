import Foundation
import NaturalLanguage

/// The system's sentence embedding for one language. `NLEmbedding` is not safe to use from two threads at once (one instance used concurrently traps), so
/// the actor owns it and embeds one text at a time. A batch hops onto the actor once per text, so a search's query embedding waits behind at most one text
/// of a running pass, not the whole batch.
public actor NLSentenceEmbedder: Embedder {
  /// The model pools over its whole input without cutting it, at a cost that grows with its length (about 50 ms per 1000 characters on an M-series Mac),
  /// so a long lore page is embedded from its head, cut at a word boundary: an entity's name and notes and a page's opening come first, and the full text is
  /// still found by FTS. A prose chunk (at most twice the chunker's target) fits whole.
  static let maximumInputLength = 2 * RetrievalChunker.defaultTargetChars

  /// Raised whenever the way inputs are prepared changes, which changes the model identity and so re-embeds every row.
  static let inputRecipe = 1

  private static let identityDomain = "com.shadow.library.novelforgekit.retrieval.nl-sentence-embedding"

  public nonisolated let language: NLLanguage
  public nonisolated let model: String
  public nonisolated let dimension: Int
  private let vectorize: (String) -> [Double]?

  /// Nil when the system has no sentence embedding for `language` (not supported, or its asset is not on this device).
  public init?(language: NLLanguage) {
    guard let embedding = NLEmbedding.sentenceEmbedding(for: language), embedding.dimension > 0 else { return nil }
    self.init(language: language, revision: embedding.revision, dimension: embedding.dimension) { embedding.vector(for: $0) }
  }

  init(language: NLLanguage, revision: Int, dimension: Int, vectorize: sending @escaping (String) -> [Double]?) {
    self.language = language
    self.dimension = dimension
    self.model = Self.identity(language: language, revision: revision, dimension: dimension)
    self.vectorize = vectorize
  }

  public nonisolated func embed(_ texts: [String]) async -> [[Float]?] {
    var vectors: [[Float]?] = []
    for text in texts { vectors.append(await vector(for: text)) }
    return vectors
  }

  static func identity(language: NLLanguage, revision: Int, dimension: Int) -> String {
    [identityDomain, language.rawValue, "r\(revision)", "d\(dimension)", "i\(inputRecipe)"].joined(separator: "/")
  }

  /// The language an identity names when it was made by this domain and input recipe and its revision is the system's current one for that language.
  static func currentLanguage(ofModel model: String) -> NLLanguage? {
    let parts = model.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 5, parts[0] == identityDomain, parts[4] == "i\(inputRecipe)", !parts[1].isEmpty else { return nil }
    let language = NLLanguage(rawValue: parts[1])
    guard parts[2] == "r\(NLEmbedding.currentSentenceEmbeddingRevision(for: language))" else { return nil }
    return language
  }

  private func vector(for text: String) -> [Float]? {
    vectorize(Self.input(text)).map { $0.map(Float.init) }
  }

  static func input(_ text: String) -> String {
    guard text.count > maximumInputLength else { return text }
    let head = text.prefix(maximumInputLength)
    guard let cut = head.lastIndex(where: \.isWhitespace), cut > head.startIndex else { return String(head) }
    return String(head[..<cut])
  }
}

/// Picks the novel's language from a sample of its text and hands out one `NLSentenceEmbedder` per language for the life of the provider. A language with no
/// model is asked again next time, since the system may download its asset meanwhile.
public actor NLSentenceEmbedders: EmbedderProvider {
  private var loaded: [NLLanguage: NLSentenceEmbedder] = [:]

  public init() {}

  public func embedder(forSample sample: String) async -> (any Embedder)? {
    guard let language = Self.language(of: sample) else { return nil }
    return embedder(for: language)
  }

  public func embedder(forModel model: String) async -> (any Embedder)? {
    guard let language = NLSentenceEmbedder.currentLanguage(ofModel: model), let embedder = embedder(for: language), embedder.model == model else { return nil }
    return embedder
  }

  private func embedder(for language: NLLanguage) -> NLSentenceEmbedder? {
    if let embedder = loaded[language] { return embedder }
    guard let embedder = NLSentenceEmbedder(language: language) else { return nil }
    loaded[language] = embedder
    return embedder
  }

  public static func language(of sample: String) -> NLLanguage? {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(sample)
    guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
    return language
  }
}
