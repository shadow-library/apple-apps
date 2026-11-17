import ShadowStore

// apps/novel-forge-server/src/modules/refinement/apply/{bible-document,entity}.handler.ts
enum BibleHandlers: ContentOpHandler {
  static func apply(_ operation: ChangeOperation, context: ApplyContext, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    throw .notYetAvailable(operation.type)
  }
}
