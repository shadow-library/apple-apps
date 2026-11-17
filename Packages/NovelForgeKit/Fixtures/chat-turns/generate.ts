import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { FakeDb, drizzle, schema } from './fake-db';
import * as R from './reference';

// Run as: PLATFORM_REPO=<checkout> bun --tsconfig-override "$PLATFORM_REPO/apps/novel-forge-server/tsconfig.json" generate.ts
// Each scenario's turns run through the reference's own chat-turn pieces over a fake database: the turn's guards as chat.service.ts:268-406
// composes them, then ChatTurnStagingService, ProposalService and ProposalApplyService themselves, their handlers writing the fake's rows.
const outDir = dirname(fileURLToPath(import.meta.url));
const input = JSON.parse(readFileSync(join(outDir, 'scenarios.json'), 'utf8')) as { world: World; scenarios: Scenario[] };

type Row = Record<string, unknown>;
type Op = Record<string, unknown>;

interface World {
  premise: string | null;
  storyCursor: number;
  finalBody: string;
  draft: string;
  entities: Row[];
  milestones: Row[];
}

interface Notes {
  text: string;
  times: number;
}

interface Vault {
  mode?: 'auto' | 'manual';
  entities?: Row[];
  notes?: Notes;
}

interface Passage {
  chapter: number;
  quote: string;
  comment: string;
}

interface Call {
  reply?: string;
  changeSet?: Op[];
  lookups?: { tool: string; args?: Row }[];
  question?: unknown;
  failure?: string;
}

interface TurnStep {
  message: string;
  choices?: { justDiscussing?: boolean; proseEdits?: boolean; contentMode?: 'standard' | 'unrestricted' };
  passages?: Passage[];
  calls: Call[];
}

interface Step {
  turn?: TurnStep;
  apply?: { proposal: string; selection?: number[] };
  discard?: { proposal: string };
  reject?: { proposal: string; op: number; scope: string };
  edit?: { entity?: Row; newEntity?: Row; draft?: { chapter: number; replace: [string, string] } };
}

interface Scenario {
  name: string;
  vault?: Vault;
  watch: string[];
  steps: Step[];
}

const PROJECT = 7n;
const SESSION = 'session-1';
const MAX_LOOKUP_ROUNDS = 3; // chat.service.ts:119

class ScriptEnded extends Error {}

const notesText = (notes: Notes | undefined): string => (notes ? notes.text.repeat(notes.times) : '');

function seed(world: World, vault: Vault): FakeDb {
  const db = new FakeDb();
  const premise = { premise: world.premise, brief: null, themes: null, instructions: null, theme: null, readerPromise: null, protagonistKey: null, opposition: null, endingQuestion: null, ending: null };
  db.seed('projects', { ...premise, id: PROJECT, storyCurrentChapter: world.storyCursor, contentMode: 'standard', costTier: 'balanced' });
  const entities = new Map(world.entities.map(entity => [entity['entityKey'], entity]));
  for (const entity of vault.entities ?? []) entities.set(entity['entityKey'], { ...entities.get(entity['entityKey']), ...entity });
  for (const entity of entities.values()) db.seed('entities', { projectId: PROJECT, status: null, motivation: null, notes: null, body: null, origin: 'manual', ...entity });
  for (const milestone of world.milestones) db.seed('milestones', { projectId: PROJECT, subjectEntityKey: null, kind: 'custom', ...milestone });
  const draft = { projectId: PROJECT, title: null, summary: 'It turns.', revision: 1, saveSeq: 0, isolated: false, generator: 'standard' };
  for (let chapter = 1; chapter <= world.storyCursor; chapter++) db.seed('drafts', { ...draft, chapter, body: world.finalBody, status: 'final', reviewStatus: 'approved' });
  db.seed('drafts', { ...draft, chapter: world.storyCursor + 1, body: world.draft, status: 'draft', reviewStatus: 'needs_review' });
  db.seed('chatSessions', { id: SESSION, projectId: PROJECT, mode: vault.mode ?? 'auto', scopeType: 'project', scopeRef: null, status: 'active' });
  return db;
}

const table = (name: string) => schema[name] as Record<string, never>;
const row = async (db: FakeDb, name: string, predicate: unknown): Promise<Row | undefined> => db.query[name]?.findFirst({ where: predicate });

class Run {
  readonly db: FakeDb;
  readonly staging: InstanceType<typeof R.stagingService.ChatTurnStagingService>;
  readonly proposals: InstanceType<typeof R.proposalService.ProposalService>;
  readonly apply: InstanceType<typeof R.applyService.ProposalApplyService>;
  readonly labels = new Map<string, bigint>();
  readonly notes: string;
  ordinal = 0;

  constructor(world: World, vault: Vault) {
    this.db = seed(world, vault);
    this.notes = notesText(vault.notes);
    const database = { getPostgresClient: () => this.db };
    const registry = new R.actionRegistry.ActionExecutorRegistry();
    // Stand-ins for the executors HubActionsModule registers: approval keeps hub-action.registrar.ts:69-78 and generation.service.ts:463's revision check.
    registry.register('action.approve_draft', async (_project: bigint, op: Op) => {
      const draft = (await row(this.db, 'drafts', drizzle.eq(table('drafts')['chapter'], op['chapter']))) as Row;
      const stamped = typeof op['draftId'] === 'string' && /^\d+$/.test(op['draftId']) && op['revision'] !== undefined && op['saveSeq'] !== undefined;
      if (!stamped || String(draft['id']) !== op['draftId'] || draft['revision'] !== op['revision'] || draft['saveSeq'] !== op['saveSeq']) throw R.classes.AppErrorCode.DRF_013.create();
      await this.db.update(table('drafts')).set({ approvedRevision: draft['revision'], reviewStatus: 'approved' }).where(drizzle.eq(table('drafts')['id'], draft['id']));
      return { summary: `Approved chapter ${String(op['chapter'])}` };
    });
    // The organise job does not run before phase 7 (orchestrator decision 3): its stand-in refuses, as the native registry does, with the native message.
    const organiseUnavailable = new R.ErrorCode('organise_unavailable', 'Applying action.organise_notes is not yet available', 409);
    registry.register('action.organise_notes', async () => ({ summary: 'Organising your notes' }), async () => organiseUnavailable.create());
    this.proposals = new R.proposalService.ProposalService(database);
    this.apply = new R.applyService.ProposalApplyService(database, registry, undefined);
    this.staging = new R.stagingService.ChatTurnStagingService(database, this.proposals, this.apply, registry);
  }

  async session(): Promise<Row> {
    return (await row(this.db, 'chatSessions', drizzle.eq(table('chatSessions')['id'], SESSION))) as Row;
  }

  async message(role: string, content: string, extra: Row = {}): Promise<Row> {
    this.ordinal += 1;
    const [stored] = (await this.db.insert(table('chatMessages')).values({ sessionId: SESSION, projectId: PROJECT, ordinal: this.ordinal, role, content, ...extra }).returning()) as Row[];
    return stored as Row;
  }

  async contexts(passages: Passage[]): Promise<Row[]> {
    const inputs: Row[] = [];
    for (const passage of passages) {
      const draft = (await row(this.db, 'drafts', drizzle.eq(table('drafts')['chapter'], passage.chapter))) as Row;
      const body = draft['body'] as string;
      const start = body.indexOf(passage.quote);
      inputs.push({
        kind: 'passage',
        chapter: passage.chapter,
        draftId: String(draft['id']),
        revision: draft['revision'],
        saveSeq: draft['saveSeq'],
        start,
        end: start + passage.quote.length,
        passageHash: R.anchor.passageHash(passage.quote),
        quote: passage.quote,
        comment: passage.comment,
      });
    }
    return R.passageContext.resolvePassageContexts(this.db, PROJECT, inputs);
  }

  // chat.service.ts:506-514
  async negationWarnings(output: Call, exempt: Set<string>): Promise<string[]> {
    if (!output.changeSet?.length) return [];
    try {
      return await R.warnings.findNegationEchoWarnings(this.db, PROJECT, R.changeSet.parseChangeSet(output.changeSet, R.playbooks.HUB_ALLOWED_OPS), { exempt });
    } catch {
      return [];
    }
  }

  async turn(step: TurnStep, index: number): Promise<Row> {
    const choices = step.choices ?? {};
    const contentMode = choices.contentMode ?? 'standard';
    const justDiscussing = choices.justDiscussing === true;
    const proseEdits = choices.proseEdits === true;
    let contexts: Row[];
    try {
      contexts = await this.contexts(step.passages ?? []);
    } catch (error) {
      return { outcome: `refused:${(error as { code: string }).code}` };
    }
    if (!step.message.trim() && contexts.length === 0) return { outcome: `refused:${R.classes.AppErrorCode.CHT_012.code}` };
    const refused = contentMode === 'unrestricted' ? R.hardLine.screenTexts(R.passageContext.turnScreens(step.message, contexts)) : null;
    if (refused) return { outcome: `refused:${R.hardLine.hardLineError(refused).code}` };

    const session = await this.session();
    const mode = session['mode'] as string;
    const organiseRequest = R.laterPlans.isNotesOrganiseRequest(step.message) && R.metrics.countWords(this.notes) >= R.organisePlan.ORGANISE_MIN_WORDS;
    const organise = R.laterPlans.organiseRouting(organiseRequest, mode, justDiscussing);
    // chat.service.ts:121-130 and :296
    const withheld = (output: Call): Call => {
      if (proseEdits || !output.changeSet?.length) return output;
      const { kept, withheld: count } = R.proseIntent.withoutProseEditOps(output.changeSet);
      if (count === 0) return output;
      return {
        reply: `${output.reply}\n\n${R.proseIntent.proseWithheldNote(output.changeSet)}`,
        ...(kept.length > 0 ? { changeSet: kept } : {}),
        ...(output.question ? { question: output.question } : {}),
      };
    };
    const guarded = (output: Call): Call => R.laterPlans.withLaterPlansRouted(withheld(output), organise);

    const user = await this.message('user', step.message, { contexts: contexts.length > 0 ? contexts : null });
    let consumed = 0;
    const next = (): Call => {
      const call = step.calls[consumed];
      consumed += 1;
      if (!call) throw new ScriptEnded(`scenario turn ${index} ran out of scripted calls`);
      if (call.failure) throw new Error(call.failure);
      return call;
    };
    // model-router.service.ts parseFirstAttempt and acceptOutput: an advisory issue on the first attempt costs one repair call, and what is accepted is screened
    const prompt = R.chatRefine.buildChatRefinePrompt('project', { proseEdits, organiseNotes: organiseRequest });
    const invoke = async (): Promise<Call> => {
      const first = next();
      const call = prompt.advise(first).length > 0 ? next() : first;
      const hit = contentMode === 'unrestricted' ? R.hardLine.screenTexts(R.hardLine.outputScreens(call, 'chat')) : null;
      if (hit) throw R.hardLine.hardLineError(hit);
      return call;
    };

    let output: Call;
    // chat-lookup.service.ts:51-118 for the trace and the planner-only flag; every scripted lookup stays within its tool's budget, so each one settles ok
    const trace = new R.trace.TurnTraceCollector(() => 0);
    let readPlannerOnly = false;
    try {
      output = await invoke();
      for (let round = 0; round < MAX_LOOKUP_ROUNDS && (output.lookups?.length ?? 0) > 0; round++) {
        for (const lookup of output.lookups ?? []) {
          trace.lookupStarted();
          trace.lookupSettled(lookup.tool, lookup.args ?? {}, 'ok');
          if (R.plannerOnly.readsPlannerOnlyPage(lookup.tool, lookup.args ?? {})) readPlannerOnly = true;
        }
        output = await invoke();
      }
    } catch (error) {
      if (error instanceof ScriptEnded) throw error;
      return { outcome: `failed:${(error as { code?: string }).code ?? 'provider'}`, calls: consumed, transcript: await this.transcript() };
    }
    if ((output.lookups?.length ?? 0) > 0) output = { reply: output.reply };

    const exempt = R.negationEcho.requestedNegations(R.passageContext.authorWords(step.message, contexts));
    output = guarded(output);
    let warnings = await this.negationWarnings(output, exempt);
    if (warnings.length > 0) {
      const revised = await invoke().catch((error: unknown) => {
        if (error instanceof ScriptEnded) throw error;
        return null;
      });
      if (revised && (revised.lookups?.length ?? 0) === 0) {
        output = guarded(revised);
        warnings = await this.negationWarnings(output, exempt);
      }
    }

    const turnWarnings = R.plannerOnly.chatTurnWarnings(warnings, readPlannerOnly);
    const question = R.chatQuestion.sanitizeChatQuestion(output.question, R.progress.PROGRESS_ITEM_KEYS) ?? null;
    const reply = await this.message('assistant', output.reply ?? '', { question });
    const authored = R.passageContext.authorWords(user['content'] as string, user['contexts'] as Row[] | null);
    const staging = { justDiscussing, organise, contexts };
    const { replyNote, ...staged } = await this.staging.stageChangeSet(PROJECT, session, reply, authored, output, `run-${index}`, turnWarnings, staging);
    const content = replyNote ? `${output.reply}\n\n${replyNote}` : (output.reply ?? '');
    if (staged.appliedProposal) this.labels.set(`s${index}.applied`, staged.appliedProposal.id);
    if (staged.cardProposal) this.labels.set(`s${index}.card`, staged.cardProposal.id);
    return {
      outcome: 'answered',
      calls: consumed,
      lookups: trace.finish().sources,
      reply: content,
      applyNote: staged.applyNote ?? null,
      held: staged.held ?? null,
      question,
      applied: staged.appliedProposal ? `s${index}.applied` : null,
      card: staged.cardProposal ? `s${index}.card` : null,
    };
  }

  id(label: string): bigint {
    const id = this.labels.get(label);
    if (id === undefined) throw new Error(`no proposal ${label}`);
    return id;
  }

  async applyStep(step: NonNullable<Step['apply']>): Promise<Row> {
    try {
      const result = await this.apply.apply(PROJECT, this.id(step.proposal), step.selection ? { opIndexes: step.selection } : undefined);
      return { outcome: 'applied', results: results(result.opResults) };
    } catch (error) {
      const code = (error as { code?: string }).code;
      if (!code) throw error;
      return { outcome: code === R.classes.AppErrorCode.RFN_003.code ? 'conflicted' : `error:${code}` };
    }
  }

  async discardStep(step: NonNullable<Step['discard']>): Promise<Row> {
    try {
      await this.proposals.discard(PROJECT, this.id(step.proposal));
      return { outcome: 'discarded' };
    } catch (error) {
      const code = (error as { code?: string }).code;
      if (!code) throw error;
      return { outcome: `error:${code}` };
    }
  }

  // idea-rejection.service.ts:36-65, recorded straight into the ledger rows loadRejectedIdeas reads
  async rejectStep(step: NonNullable<Step['reject']>): Promise<Row> {
    const proposal = (await row(this.db, 'refinementProposals', drizzle.eq(table('refinementProposals')['id'], this.id(step.proposal)))) as Row;
    const op = (proposal['changeSet'] as Op[])[step.op] as Op;
    const refs = R.changeSet.changeSetRefs([op]);
    const scope = step.scope;
    const context = scope === 'never' ? null : await R.ideaRejections.loadRejectionContext(this.db, PROJECT, [], scope === 'not_this_version' ? refs : []);
    const anchor = context ? R.ideaRejections.rejectionAnchor(scope, context, refs) : null;
    this.db.seed('decisionLedgerEntries', { projectId: PROJECT, ideaId: R.ideaId.ideaIdOf(op), rejectionScope: scope, rejectionAnchor: anchor, supersededAt: null });
    return { outcome: 'rejected' };
  }

  async editStep(step: NonNullable<Step['edit']>): Promise<Row> {
    if (step.entity) {
      const { entityKey, ...fields } = step.entity;
      await this.db.update(table('entities')).set(fields).where(drizzle.eq(table('entities')['entityKey'], entityKey));
    }
    if (step.newEntity) this.db.seed('entities', { projectId: PROJECT, status: null, motivation: null, notes: null, body: null, origin: 'manual', ...step.newEntity });
    if (step.draft) {
      const [from, to] = step.draft.replace;
      const draft = (await row(this.db, 'drafts', drizzle.eq(table('drafts')['chapter'], step.draft.chapter))) as Row;
      const body = draft['body'] as string;
      if (!body.includes(from)) throw new Error(`edit: chapter ${step.draft.chapter} has no "${from}"`);
      await this.db
        .update(table('drafts'))
        .set({ body: body.replace(from, () => to), revision: (draft['revision'] as number) + 1, saveSeq: 0 })
        .where(drizzle.eq(table('drafts')['id'], draft['id']));
    }
    return { outcome: 'edited' };
  }

  async transcript(): Promise<string[]> {
    const messages = await this.db.query['chatMessages']?.findMany({ orderBy: drizzle.asc(table('chatMessages')['ordinal']) });
    return (messages ?? []).map(message => message['role'] as string);
  }

  async snapshot(watch: string[]): Promise<Row> {
    const proposals: Row = {};
    for (const [label, id] of [...this.labels].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))) {
      const proposal = (await row(this.db, 'refinementProposals', drizzle.eq(table('refinementProposals')['id'], id))) as Row;
      proposals[label] = {
        decision: proposal['status'],
        ops: (proposal['changeSet'] as Op[]).map(normalisedOp),
        warnings: (proposal['warnings'] as string[] | null) ?? [],
        results: proposal['status'] === 'applied' ? results(proposal['opResults'] as Row[]) : null,
      };
    }
    const current = await R.artifactState.loadCurrentRecords(this.db, PROJECT, watch);
    const records: Row = {};
    for (const ref of watch) {
      if (ref.startsWith('draft:')) {
        const draft = await row(this.db, 'drafts', drizzle.eq(table('drafts')['chapter'], Number(ref.slice(6))));
        records[ref] = draft ? { body: draft['body'], approved: draft['approvedRevision'] === draft['revision'] } : null;
      } else {
        records[ref] = current.get(ref) ?? null;
      }
    }
    const decisions: Record<string, number> = {};
    for (const proposal of await this.db.query['refinementProposals']?.findMany() ?? []) decisions[proposal['status'] as string] = (decisions[proposal['status'] as string] ?? 0) + 1;
    return { transcript: await this.transcript(), proposals, decisions, records };
  }
}

// The stamps that name a draft by this reference's row ids and counters; a native vault names drafts its own way.
function normalisedOp(op: Op): Op {
  const copy = JSON.parse(JSON.stringify(op)) as Op;
  const anchor = copy['anchor'] as Op | undefined;
  if (anchor) {
    delete anchor['draftId'];
    delete anchor['revision'];
    delete anchor['saveSeq'];
  }
  if (copy['op'] === 'action.approve_draft') {
    delete copy['draftId'];
    delete copy['revision'];
    delete copy['saveSeq'];
  }
  return copy;
}

const results = (opResults: Row[]): Row[] =>
  opResults.map(entry => ({ index: entry['index'], status: entry['status'], ...(entry['source'] ? { source: entry['source'] } : {}) }));

// A scripted reply the reference's own output checks refuse would cost repair calls this driver does not model, so the script is refused instead.
const checks = R.chatRefine.buildChatRefinePrompt('project');
for (const scenario of input.scenarios) {
  for (const [index, step] of scenario.steps.entries()) {
    for (const call of step.turn?.calls ?? []) {
      if (call.failure) continue;
      const issues = [...(call.changeSet?.length ? R.changeSet.validateChangeSet(call.changeSet, R.playbooks.HUB_ALLOWED_OPS) : []), ...checks.postValidate(call)];
      if (issues.length > 0) throw new Error(`${scenario.name} step ${index}: an invalid scripted reply: ${issues.join('; ')}`);
    }
  }
}

const scenarios: unknown[] = [];
for (const scenario of input.scenarios) {
  const run = new Run(input.world, scenario.vault ?? {});
  const expected: unknown[] = [];
  for (const [index, step] of scenario.steps.entries()) {
    let outcome: Row;
    if (step.turn) outcome = await run.turn(step.turn, index);
    else if (step.apply) outcome = await run.applyStep(step.apply);
    else if (step.discard) outcome = await run.discardStep(step.discard);
    else if (step.reject) outcome = await run.rejectStep(step.reject);
    else if (step.edit) outcome = await run.editStep(step.edit);
    else throw new Error(`${scenario.name}: step ${index} does nothing`);
    expected.push({ ...outcome, ...(await run.snapshot(scenario.watch)) });
  }
  scenarios.push({ ...scenario, expected });
}

const json = JSON.stringify({ world: input.world, scenarios }, (_, value: unknown) => (typeof value === 'bigint' ? String(value) : value));
writeFileSync(join(outDir, 'chat-turns.json'), `${json}\n`);
