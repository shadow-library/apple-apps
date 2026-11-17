import ShadowStore

// apps/novel-forge-server/src/modules/refinement/apply/brief.handler.ts, brief-merge.ts, staged-plan.ts
enum PlanHandlers: ContentOpHandler {
  static func apply(_ operation: ChangeOperation, context: ApplyContext, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    throw .notYetAvailable(operation.type)
  }
}
