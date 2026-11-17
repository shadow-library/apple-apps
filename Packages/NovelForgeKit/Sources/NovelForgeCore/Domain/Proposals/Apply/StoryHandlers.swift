import ShadowStore

// apps/novel-forge-server/src/modules/refinement/apply/{premise,volume,milestone,fact,promise}.handler.ts
enum StoryHandlers: ContentOpHandler {
  static func apply(_ operation: ChangeOperation, context: ApplyContext, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    throw .notYetAvailable(operation.type)
  }
}
