import Foundation

public struct RoutedCall: Sendable {
  public let route: ModelRoute
  public let host: String
  /// Sends only requests for the route's model and records each stream in the ledger.
  public let provider: any ModelProvider
  private let journal: CallJournal

  init(route: ModelRoute, host: String, provider: any ModelProvider, journal: CallJournal) {
    self.route = route
    self.host = host
    self.provider = provider
    self.journal = journal
  }

  /// The ledger id of each stream begun so far, in order; a reply stores these for its cost.
  public var callIDs: [UUID] { journal.ids }

  /// What each closed stream wrote: its call, then one child entry per abandoned attempt; a cancelled stream's call is still begun. Complete only after
  /// `settled()`, since a stream is closed after its consumer stops listening.
  public var entries: [ModelCallEntry] { journal.entries }

  /// Returns once every stream begun so far has been closed or left pending.
  public func settled() async {
    await journal.settled()
  }

  public func request(system: [ContextSegment], messages: [ModelMessage], format: ResponseFormat = .text, cachesConversation: Bool = false) -> ModelRequest {
    ModelRequest(
      model: route.model, system: system, messages: messages, maxOutputTokens: route.maxOutputTokens, effort: route.effort, format: format,
      cachesConversation: cachesConversation)
  }
}
