import ShadowAI

extension RequestGuard {
  /// A standard model holds the line itself, so only an unrestricted route is screened, and on the wire only explicit terms refuse.
  // apps/novel-forge-server/src/modules/ai/model-router.service.ts:710-719
  static func hardLine(for route: ModelRoute, lexicon: HardLineLexicon = .standard) -> RequestGuard? {
    guard route.contentMode == .unrestricted else { return nil }
    return RequestGuard(
      screen: { messages throws(HardLineError) in
        let hit = screenTexts(wireMessageTexts(messages).map { ScreenedText(text: $0, scope: .background, source: "The request") }, lexicon: lexicon)
        if let hit { throw hardLineError(hit) }
      },
      systemLine: hardLineSystemLine)
  }

  var modelRequestGuard: ModelRequestGuard {
    let screen = screen
    return ModelRequestGuard(systemLine: systemLine) { request in
      do throws(HardLineError) {
        try screen(request.wireMessages)
        return .allow
      } catch {
        return .refuse(error)
      }
    }
  }
}

extension ModelRequestGuard {
  /// The `TaskRouter` policy: an unrestricted route screens every request at the background scope and sends the hard line's system line first.
  public static func hardLine(for route: ModelRoute) -> ModelRequestGuard? {
    RequestGuard.hardLine(for: route)?.modelRequestGuard
  }

  // Builds the lexicon on every call, so callers cache the guard per character snapshot; zero-width characters inside a name evade it, as they do every D10 term.
  public static func hardLine(for route: ModelRoute, characters: [EntityRecord]) -> ModelRequestGuard? {
    RequestGuard.hardLine(for: route, lexicon: .standard(withMinorsIn: characters))?.modelRequestGuard
  }
}

extension ModelRequest {
  /// The messages as OpenRouter sends them: the system segments as the parts of one message, then each turn.
  var wireMessages: [WireMessage] {
    let systemMessage = system.isEmpty ? [] : [WireMessage(content: .parts(system.map { HardLineContentPart(text: $0.text) }))]
    return systemMessage + messages.map { WireMessage(content: .text($0.text)) }
  }
}

extension ModelError {
  /// What the route's hard-line guard refused this request for.
  var hardLineHit: HardLineHit? {
    guard case .requestRefused(let refusal) = self, case .declined(let source, let rule, let sourceRefs)? = refusal.reason as? HardLineError else { return nil }
    return HardLineHit(rule: rule, source: source, sourceRefs: sourceRefs)
  }
}

extension StructuredError {
  var hardLineHit: HardLineHit? {
    guard case .model(let error, _) = self else { return nil }
    return error.hardLineHit
  }
}
