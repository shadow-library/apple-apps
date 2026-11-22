import Foundation
import NovelForgeCore
import ShadowAI
import ShadowAppShell

extension AIServices {
  /// The system's sentence embeddings, one per language for the life of the app, shared by the retrieval upkeep and the searches of every job.
  private static let sentenceEmbedders: any EmbedderProvider = NLSentenceEmbedders()

  static func novelForge(defaults: UserDefaults = .standard) -> AIServices {
    live(identity: .novelForge, disclosures: ConsentDisclosure.novelForge, requestGuard: { ModelRequestGuard.hardLine(for: $0) }, defaults: defaults)
  }

  var embedders: any EmbedderProvider { Self.sentenceEmbedders }
}
