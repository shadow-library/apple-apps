/// The pipeline each job kind runs (apps/novel-forge-server/src/modules/jobs/job.executor.ts:135-139 dispatches by kind the same way); each kind's file
/// replaces its own definition.
enum PipelineCatalog {
  static func definition(for kind: NovelJobKind) -> NovelPipelineDefinition {
    switch kind {
    case .generate: GenerationPipeline.definition
    case .plan: PlanPipeline.definition
    case .review: ReviewPipeline.definition
    case .finalizeReview: FinalizeReviewPipeline.definition
    case .canonRefresh: RefreshPipeline.definition
    }
  }
}
