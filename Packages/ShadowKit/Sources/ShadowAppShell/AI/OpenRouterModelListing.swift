import ShadowAI
import SwiftUI

extension View {
  /// Lists OpenRouter's models for the router whenever `services` is shown or its chosen provider changes, and only while OpenRouter is chosen.
  public func loadsOpenRouterModels(_ services: AIServices) -> some View {
    task(id: OpenRouterListingTrigger(services: ObjectIdentifier(services), provider: services.settings.provider)) { await services.loadOpenRouterModelsIfChosen() }
  }
}

private struct OpenRouterListingTrigger: Hashable {
  let services: ObjectIdentifier
  let provider: ModelProviderKind
}
