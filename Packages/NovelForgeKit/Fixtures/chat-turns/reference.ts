import { plugin } from 'bun';
import { mock } from 'bun:test';
import { readdirSync } from 'node:fs';
import { join } from 'node:path';

import { drizzle, schema } from './fake-db';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');

const server = join(platformRepo, 'apps/novel-forge-server/src');
const refinement = join(server, 'modules/refinement');
const resolve = (specifier: string): string => Bun.resolveSync(specifier, server);

export const classes = await import(join(server, 'classes/index.ts'));
const shadowCommon = await import(resolve('@shadow-library/common'));
const sdk = await import(join(platformRepo, 'packages/sdk/src/index.ts'));
const publishing = await import(join(platformRepo, 'packages/sdk/src/publishing/index.ts'));

const silent = { debug: () => undefined, info: () => undefined, warn: () => undefined, error: () => undefined };
const Logger = { getLogger: () => silent };
const Injectable = () => (target: unknown) => target;
const noop = async (): Promise<void> => undefined;

const common: Record<string, unknown> = {};

plugin({
  name: 'chat-turns-fixture-stubs',
  setup(build) {
    build.module('@server/classes', () => ({ exports: classes, loader: 'object' }));
    build.module('@server/common', () => ({ exports: common, loader: 'object' }));
    build.module('@server/constants', () => ({ exports: { APP_NAME: 'novel-forge' }, loader: 'object' }));
    build.module('@server/database', () => ({ exports: { schema }, loader: 'object' }));
    build.module('@server/database/schemas', () => ({ exports: { bibleSection: { enumValues: [] } }, loader: 'object' }));
    build.module('drizzle-orm', () => ({ exports: drizzle, loader: 'object' }));
    build.module('@shadow-library/app', () => ({ exports: { Injectable }, loader: 'object' }));
    build.module('@shadow-library/common', () => ({ exports: { ...shadowCommon, Logger }, loader: 'object' }));
    build.module('@shadow-library/modules', () => ({ exports: { DatabaseService: class {} }, loader: 'object' }));
    build.module('@shadow-library/sdk', () => ({ exports: sdk, loader: 'object' }));
    build.module('@shadow-library/sdk/publishing', () => ({ exports: publishing, loader: 'object' }));
  },
});

for (const file of readdirSync(join(server, 'common'))
  .filter(name => name.endsWith('.ts') && !name.endsWith('.spec.ts') && !name.endsWith('.dto.ts') && name !== 'index.ts')
  .sort()) {
  try {
    Object.assign(common, await import(join(server, 'common', file)));
  } catch {
    continue;
  }
}
// No scenario applies an op the plan guard reads or writes a final chapter, so the plan locks, staleness marks and draft history stay out.
Object.assign(common, {
  enforcePlanWrite: noop,
  lockProjectPlan: noop,
  markDescendantDraftsStale: noop,
  pruneDraftHistory: noop,
  revokeProvisionalReveals: noop,
  findMilestoneReferences: async () => [],
  assertMilestoneSubject: noop,
  findAuditReportForCard: async () => undefined,
  auditCardSelection: async () => undefined,
});

const playbooks = await import(join(server, 'modules/ai/prompts/scope-playbooks.ts'));
mock.module(join(server, 'modules/ai/prompts/index.ts'), () => ({ HUB_ALLOWED_OPS: playbooks.HUB_ALLOWED_OPS }));
mock.module(join(server, 'modules/ai/novel-forge-catalog.service.ts'), () => ({ NovelForgeCatalogService: class {}, requireUnrestricted: noop }));
mock.module(join(server, 'modules/notes/organise-record.ts'), () => ({ recordOrganiseDecision: noop, wholeOrganiseSelection: () => undefined }));
mock.module(join(server, 'modules/generation/passage-leaks.ts'), () => ({ holdNewLeaks: async (_tx: unknown, saved: unknown) => saved }));

type Row = Record<string, unknown>;
interface Tx {
  select(): { from(table: unknown): { where(predicate: unknown): { for(mode: string): PromiseLike<Row[]> } } };
  update(table: unknown): { set(values: Row): { where(predicate: unknown): { returning(): PromiseLike<Row[]> } } };
}

// generation/draft-save.ts reduced to the row a hand save leaves: the body written, the revision and save counted on.
mock.module(join(server, 'modules/generation/draft-save.ts'), () => ({
  baseOfDraft: (draft: Row) => ({ draftId: draft['id'], revision: draft['revision'], saveSeq: draft['saveSeq'] }),
  lockDraft: async (tx: Tx, projectId: bigint, chapter: number) => {
    const [draft] = await tx
      .select()
      .from(schema['drafts'])
      .where(drizzle.and(drizzle.eq(schema['drafts']?.['projectId'], projectId), drizzle.eq(schema['drafts']?.['chapter'], chapter)))
      .for('update');
    if (!draft) throw classes.AppErrorCode.DRF_001.create();
    return draft;
  },
  saveHandWrittenDraft: async (tx: Tx, save: { projectId: bigint; chapter: number; fields: { body: string } }) => {
    const drafts = schema['drafts'] as Record<string, never>;
    const [current] = await tx
      .select()
      .from(drafts)
      .where(drizzle.and(drizzle.eq(drafts['projectId'], save.projectId), drizzle.eq(drafts['chapter'], save.chapter)))
      .for('update');
    if (!current) throw classes.AppErrorCode.DRF_001.create();
    const [draft] = await tx
      .update(drafts)
      .set({ body: save.fields.body, revision: (current['revision'] as number) + 1, saveSeq: (current['saveSeq'] as number) + 1, reviewStatus: 'needs_review' })
      .where(drizzle.eq(drafts['id'], current['id']))
      .returning();
    return draft;
  },
}));

export const changeSet = await import(join(refinement, 'change-set/index.ts'));
export const proposalService = await import(join(refinement, 'proposal.service.ts'));
export const applyService = await import(join(refinement, 'proposal-apply.service.ts'));
export const stagingService = await import(join(refinement, 'chat-turn-staging.service.ts'));
export const actionRegistry = await import(join(refinement, 'action-registry.ts'));
export const proseIntent = await import(join(refinement, 'prose-intent.ts'));
export const laterPlans = await import(join(refinement, 'later-plans-guard.ts'));
export const plannerOnly = await import(join(refinement, 'planner-only-guard.ts'));
export const negationEcho = await import(join(refinement, 'negation-echo.ts'));
export const warnings = await import(join(refinement, 'proposal-warnings.ts'));
export const passageContext = await import(join(refinement, 'passage-context.ts'));
export const chatQuestion = await import(join(refinement, 'chat-question.ts'));
export const ideaRejections = await import(join(refinement, 'idea-rejections.ts'));
export const ideaId = await import(join(refinement, 'idea-id.ts'));
export const artifactState = await import(join(refinement, 'artifact-state.ts'));
export const trace = await import(join(refinement, 'chat-turn-trace.ts'));
export const hardLine = await import(join(server, 'modules/ai/hard-line.ts'));
export const anchor = await import(join(server, 'modules/generation/passage-anchor.ts'));
export const progress = await import(join(server, 'common/progress.ts'));
export const organisePlan = await import(join(server, 'modules/notes/organise-plan.ts'));
export const metrics = await import(join(server, 'modules/eval/deterministic-metrics.ts'));
// The checks and advice of the model router's repair ladder; this file holds uncommitted edits in the reference checkout (its template, not these).
export const chatRefine = await import(join(server, 'modules/ai/prompts/chat-refine.prompt.ts'));
export const chatRefineSchema = await import(join(server, 'modules/ai/schemas/chat-refine.schema.ts'));
export const schemaValidate = await import(join(server, 'modules/ai/schemas/validate.ts'));
export const ErrorCode = shadowCommon.ErrorCode;
export { playbooks };
