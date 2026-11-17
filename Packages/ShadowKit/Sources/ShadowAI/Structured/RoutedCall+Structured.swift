import ShadowCore

extension RoutedCall {
  /// `streamStructured` without an observer.
  public func structured(_ request: ModelRequest, name: String, schema: JSONValue, review: StructuredReview = .none) async throws(StructuredError) -> StructuredResult {
    do throws(StructuredStreamFailure) {
      return try await streamStructured(request, name: name, schema: schema, review: review)
    } catch {
      throw error.error
    }
  }

  /// A `StructuredCall` in native mode when the route's model lists it. The outcome's `callIDs` are exactly the ledger ids of this call's requests,
  /// also when other calls share the `RoutedCall`; a cancelled request's id is included once its ledger write has ended. The route's request guard screens
  /// each attempt before it is counted, so a refused attempt is neither shown nor ledgered.
  public func streamStructured(
    _ request: ModelRequest, name: String, schema: JSONValue, review: StructuredReview = .none, observer: (StructuredStreamEvent) -> Void = { _ in }
  ) async throws(StructuredStreamFailure) -> StructuredResult {
    let collector = CallJournal()
    let call = StructuredCall(provider: ledgered, supportsNativeSchema: route.supportsNativeSchema, providerName: route.provider.rawValue)
    let outcome = await CallJournal.$collector.withValue(collector) { () async -> Result<StructuredResult, StructuredStreamFailure> in
      do throws(StructuredStreamFailure) {
        return .success(
          try await call.stream(
            request, name: name, schema: schema, review: review, requestGuard: requestGuard, observer: observer,
            callIDs: {
              await collector.settled()
              return collector.ids
            }))
      } catch {
        return .failure(error)
      }
    }
    return try outcome.get()
  }
}
