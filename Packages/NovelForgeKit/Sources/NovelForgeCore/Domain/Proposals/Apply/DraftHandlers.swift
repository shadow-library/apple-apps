import ShadowStore

// apps/novel-forge-server/src/modules/refinement/apply/draft.handler.ts, passage-rewrite.ts
enum DraftHandlers: ContentOpHandler {
  static func apply(_ operation: ChangeOperation, context: ApplyContext, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    throw .notYetAvailable(operation.type)
  }

  // draft.handler.ts:114: a chapter's selected rewrites land as one revision
  static func rewritePassages(chapter: Int, _ rewrites: [DraftRewritePassage], context: ApplyContext, in transaction: inout WriteTransaction) throws(ApplyError)
    -> HandlerOutcome
  {
    throw .notYetAvailable(.draftRewritePassage)
  }
}
