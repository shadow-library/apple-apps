import ShadowCore

enum EvalError: ShadowError {
  case usage(String)
  case liveRunNotConfirmed
  case providerNotConfigured
  case unsupportedProvider(String)
  case writeVaultNotConfirmed
  case consentMissing(String)
  case vault(String)
  case setup(String)

  var code: String {
    switch self {
    case .usage: "eval.usage"
    case .liveRunNotConfirmed: "eval.live_run_not_confirmed"
    case .providerNotConfigured: "eval.provider_not_configured"
    case .unsupportedProvider: "eval.unsupported_provider"
    case .writeVaultNotConfirmed: "eval.write_vault_not_confirmed"
    case .consentMissing: "eval.consent_missing"
    case .vault: "eval.vault"
    case .setup: "eval.setup"
    }
  }

  var errorDescription: String? {
    switch self {
    case .usage(let message): message
    case .liveRunNotConfirmed:
      "Running the chapter pipelines calls a model and spends money: pass --live to confirm, or --metrics-only to measure the chapters already in the vault."
    case .providerNotConfigured: "A live run needs \(EvalEnvironment.provider) and \(EvalEnvironment.apiKey) in the environment."
    case .unsupportedProvider(let name): "\(EvalEnvironment.provider)=\(name) is not supported; use anthropic."
    case .writeVaultNotConfirmed: "A pipeline run writes into the real vault, finalizes real chapters and cannot be undone: pass --write-vault to confirm."
    case .consentMissing(let host): "This vault holds no AI consent for \(host) covering this run. nf-eval never records consent in a real vault: grant it in the app first."
    case .vault(let message): "The vault could not be opened: \(message)"
    case .setup(let message): message
    }
  }
}

enum EvalEnvironment {
  static let provider = "NF_EVAL_PROVIDER"
  static let apiKey = "NF_EVAL_API_KEY"
}
