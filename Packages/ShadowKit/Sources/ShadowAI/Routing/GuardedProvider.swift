import OSLog
import ShadowCore

/// Screens each request before its base sees it; wrapped around the ledgered provider, so a refused request is never ledgered.
struct GuardedProvider: ModelProvider {
  let base: any ModelProvider
  let requestGuard: ModelRequestGuard

  func stream(_ request: ModelRequest) -> ModelStream {
    switch requestGuard.screen(request) {
    case .allow:
      return base.stream(requestGuard.framing(request))
    case .refuse(let reason):
      TaskRouter.logger.notice("The request guard refused a request before it was sent model=\(request.model, privacy: .public) code=\(reason.code, privacy: .public)")
      return ModelStream { _ throws(ModelError) in throw .requestRefused(ModelRequestRefusal(reason)) }
    }
  }

  func validate(_ credential: ProviderCredential) async throws(ModelError) -> CredentialStatus {
    try await base.validate(credential)
  }

  func models() async throws(ModelError) -> [RemoteModel] {
    try await base.models()
  }
}
