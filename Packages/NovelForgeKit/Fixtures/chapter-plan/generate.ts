import { plugin } from 'bun';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');

const server = join(platformRepo, 'apps/novel-forge-server/src');
const outDir = dirname(fileURLToPath(import.meta.url));
const classes = await import(join(server, 'classes/app-error-code.ts'));
const noop = () => undefined;
const columns = (table: string): unknown => new Proxy({}, { get: (_, column) => `${table}.${String(column)}` });
const schema = new Proxy({}, { get: (_, table) => columns(String(table)) });
const condition = (t: string) => (...parts: unknown[]) => ({ t, parts: parts.filter(part => part !== undefined) });
const compare = (t: string) => (col: string, val: unknown) => ({ t, col, val });
const common: Record<string, unknown> = {};

plugin({
  name: 'chapter-plan-fixture-stubs',
  setup(build) {
    build.module('@server/classes', () => ({ exports: { AppErrorCode: classes.AppErrorCode }, loader: 'object' }));
    build.module('@server/common', () => ({ exports: common, loader: 'object' }));
    build.module('@server/database', () => ({ exports: { schema }, loader: 'object' }));
    build.module('@server/database/schemas', () => ({ exports: {}, loader: 'object' }));
    build.module('drizzle-orm', () => ({
      exports: {
        and: condition('and'),
        or: condition('or'),
        eq: compare('eq'),
        lt: compare('lt'),
        lte: compare('lte'),
        gt: compare('gt'),
        isNotNull: noop,
        inArray: noop,
        ne: noop,
        isNull: noop,
        asc: noop,
        desc: (col: string) => ({ t: 'desc', col }),
        sql: (strings: TemplateStringsArray) => ({ t: 'sql', text: strings.join('?') }),
      },
      loader: 'object',
    }));
    build.onResolve({ filter: /\/(artifact-state|token-budget)$/ }, args => ({ path: args.path, namespace: 'stub' }));
    build.onLoad({ filter: /.*/, namespace: 'stub' }, () => ({ contents: 'export const countTokens = (text) => text.length;', loader: 'js' }));
  },
});

const briefScenes = await import(join(server, 'common/brief-scenes.ts'));
const unlockCondition = await import(join(server, 'common/unlock-condition.ts'));
const docTitle = await import(join(server, 'common/bible-doc-title.ts'));
const briefBody = await import(join(server, 'common/brief-body.ts'));
const promise = await import(join(server, 'common/promise.ts'));
const reveal = await import(join(server, 'common/reveal-rule.ts'));
const revealTerm = await import(join(server, 'common/reveal-term.ts'));
Object.assign(common, {
  validateBriefScenes: briefScenes.validateBriefScenes,
  normalizeBriefScenes: briefScenes.normalizeBriefScenes,
  validateUnlockCondition: unlockCondition.validateUnlockCondition,
  describeUnlockTerm: unlockCondition.describeUnlockTerm,
  evaluateUnlock: unlockCondition.evaluateUnlock,
  shiftUnlockChapters: unlockCondition.shiftUnlockChapters,
  deriveBibleDocTitle: docTitle.deriveBibleDocTitle,
  composePlanBody: briefBody.composePlanBody,
  renderBriefBody: briefBody.renderBriefBody,
  resolvePromiseDueStanding: promise.resolvePromiseDueStanding,
  findPlanClaimProblems: reveal.findPlanClaimProblems,
  planUnlockContext: reveal.planUnlockContext,
  revealRequirements: reveal.revealRequirements,
  revealTermPattern: revealTerm.revealTermPattern,
  loadPlanState: noop,
  nearestVolumeKey: noop,
});

const chapterPlan = await import(join(server, 'modules/actions/chapter-plan.ts'));
const writePolicy = await import(join(server, 'modules/refinement/write-policy.ts'));
const passage = await import(join(server, 'modules/refinement/passage-context.ts'));

const planJob = ((): { authorMessagesFor: Function; intentStatedIn: Function; planSteer: Function } => {
  const source = readFileSync(join(server, 'modules/actions/plan-job.service.ts'), 'utf8');
  const from = source.indexOf('const INTENT_TURNS');
  const end = source.indexOf('/** One plan at a time');
  if (from === -1 || end === -1) throw new Error('plan-job.service.ts moved');
  const body = source.slice(from, end).replaceAll('export ', '');
  const script = new Bun.Transpiler({ loader: 'ts' }).transformSync(`${body}\nreturn { authorMessagesFor, intentStatedIn, planSteer };`);
  const names = ['and', 'desc', 'eq', 'gt', 'lt', 'lte', 'or', 'sql', 'schema', 'authorWords', 'contentTokens', 'normaliseForQuote', 'quoteIsTentative', 'splitSentences'];
  const drizzle = { and: condition('and'), or: condition('or'), eq: compare('eq'), lt: compare('lt'), lte: compare('lte'), gt: compare('gt'), desc: (col: string) => ({ t: 'desc', col }), sql: (strings: TemplateStringsArray) => ({ t: 'sql', text: strings.join('?') }) };
  const deps: Record<string, unknown> = { ...drizzle, schema, authorWords: passage.authorWords, contentTokens: writePolicy.contentTokens, normaliseForQuote: writePolicy.normaliseForQuote, quoteIsTentative: writePolicy.quoteIsTentative, splitSentences: writePolicy.splitSentences };
  return new Function(...names, script)(...names.map(name => deps[name]));
})();

interface Rng {
  next(): number;
  int(min: number, max: number): number;
  chance(p: number): boolean;
  pick<T>(items: readonly T[]): T;
  subset<T>(items: readonly T[], p?: number): T[];
}

function createRng(seed: number): Rng {
  let state = seed | 0;
  const next = (): number => {
    state = (state + 0x6d2b79f5) | 0;
    let t = Math.imul(state ^ (state >>> 15), 1 | state);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  return {
    next,
    int: (min, max) => min + Math.floor(next() * (max - min + 1)),
    chance: p => next() < p,
    pick: items => items[Math.floor(next() * items.length)] as never,
    subset: (items, p = 0.5) => items.filter(() => next() < p),
  };
}

type Json = Record<string, any>;

function promiseRow(p: Json): Json {
  const shared = { status: p.isOpen ? 'open' : 'closed', intentionallyOpen: p.intentionallyOpen, openedChapter: p.openedChapter, lastAdvancedChapter: p.lastAdvancedChapter, payoffWindow: p.payoffWindow, payoffMilestoneKey: p.payoffMilestoneKey, payoffVolumeKey: p.payoffVolumeKey };
  return p.kind === 'thread' ? { threadKey: p.key, summary: p.text, ...shared } : { mysteryKey: p.key, question: p.text ?? '', ...shared };
}

function promiseCase(key: string, kind: string, overrides: Json = {}): Json {
  return { kind, key, text: `The ${key} ${kind}`, isOpen: true, intentionallyOpen: false, openedChapter: 1, lastAdvancedChapter: 1, payoffWindow: null, payoffMilestoneKey: null, payoffVolumeKey: null, ...overrides };
}

const thread = (key: string, overrides: Json = {}) => promiseCase(key, 'thread', overrides);
const mystery = (key: string, overrides: Json = {}) => promiseCase(key, 'mystery', overrides);

function obligationCase(sources: Json): Json {
  const input = { previousEnding: null, threads: [], mysteries: [], volume: null, milestoneStates: {}, volumeStates: {}, ...sources };
  const obligations = chapterPlan.selectObligations({
    chapter: input.chapter,
    previousEnding: input.previousEnding,
    threads: input.threads.map(promiseRow),
    mysteries: input.mysteries.map(promiseRow),
    volume: input.volume,
    milestoneStates: new Map(Object.entries(input.milestoneStates)),
    volumeStates: new Map(Object.entries(input.volumeStates)),
  });
  const rationales = [undefined, 'Mara tests it', '  Mara tests it  ', '   '].map(moves => ({ moves: moves ?? null, result: chapterPlan.planRationale(obligations, moves) ?? null }));
  return { sources: input, obligations, rendered: chapterPlan.renderObligations(obligations), rationales };
}

const obligations: Json[] = [];
obligations.push(
  obligationCase({
    chapter: 5,
    previousEnding: { openQuestion: 'Who opened the gate?', handoffState: 'Mara in the flooded hall' },
    threads: [thread('debt', { lastAdvancedChapter: 1 }), thread('oath', { lastAdvancedChapter: 4, payoffWindow: 5 })],
    volume: { volumeKey: 'vol_01', title: 'The Mine', objective: 'Mara escapes the mine.' },
  }),
  obligationCase({ chapter: 12, threads: [thread('ghost', { lastAdvancedChapter: 1, intentionallyOpen: true }), thread('debt', { lastAdvancedChapter: 2 }), thread('oath', { lastAdvancedChapter: 9 })] }),
  obligationCase({ chapter: 1, previousEnding: { openQuestion: 'x' }, volume: { volumeKey: 'v', title: null, objective: ' ' } }),
  obligationCase({
    chapter: 12,
    threads: [thread('debt', { lastAdvancedChapter: 2 }), thread('oath', { lastAdvancedChapter: 9, payoffMilestoneKey: 'reveal_thief' })],
    milestoneStates: { reveal_thief: 'reached' },
  }),
  obligationCase({
    chapter: 12,
    threads: [thread('debt', { lastAdvancedChapter: 2 }), thread('oath', { lastAdvancedChapter: 9, payoffVolumeKey: 'vol_01' })],
    volumeStates: { vol_01: 'active' },
  }),
  obligationCase({
    chapter: 12,
    threads: [thread('debt', { lastAdvancedChapter: 2 }), thread('oath', { lastAdvancedChapter: 9, payoffVolumeKey: 'vol_01' })],
    volumeStates: { vol_01: 'goal_met' },
  }),
  obligationCase({
    chapter: 6,
    threads: [thread('oath', { lastAdvancedChapter: 5, payoffVolumeKey: 'vol_01' }), thread('debt', { lastAdvancedChapter: 1, payoffWindow: 6 })],
    volumeStates: { vol_01: 'goal_met' },
  }),
  obligationCase({
    chapter: 6,
    threads: [thread('oath', { lastAdvancedChapter: 5, payoffVolumeKey: 'vol_01' }), thread('debt', { lastAdvancedChapter: 1, payoffWindow: 6 })],
    volumeStates: { vol_01: 'active' },
  }),
  obligationCase({
    chapter: 12,
    threads: [thread('debt', { lastAdvancedChapter: 2 }), thread('oath', { lastAdvancedChapter: 9, payoffMilestoneKey: 'reveal_thief' })],
    milestoneStates: { reveal_thief: 'planned' },
  }),
  obligationCase({ chapter: 12, threads: [thread('debt', { isOpen: false, lastAdvancedChapter: 1 })] }),
  obligationCase({ chapter: 1 }),
  obligationCase({ chapter: 2, previousEnding: { openQuestion: '  ', handoffState: ' Mara waits ' } }),
  obligationCase({ chapter: 3, previousEnding: { openQuestion: ' Who? ', handoffState: null }, threads: [thread('lamp', { text: '  ', openedChapter: null, lastAdvancedChapter: null })] }),
  obligationCase({ chapter: 9, mysteries: [mystery('heir', { text: 'Who is the heir?', lastAdvancedChapter: 2, payoffWindow: 7 })], threads: [thread('debt', { lastAdvancedChapter: 8 })] }),
  obligationCase({ chapter: 9, mysteries: [mystery('heir', { text: 'Who is the heir?', lastAdvancedChapter: 8, payoffWindow: 3 })] }),
  obligationCase({ chapter: 20, threads: [thread('a', { lastAdvancedChapter: 9, payoffWindow: 3 }), thread('c', { lastAdvancedChapter: 1, payoffWindow: 5 }), thread('b', { lastAdvancedChapter: 5, payoffVolumeKey: 'v1' })], volumeStates: { v1: 'goal_met' } }),
  obligationCase({ chapter: 20, threads: [thread('b', { lastAdvancedChapter: 5, payoffVolumeKey: 'v1' }), thread('c', { lastAdvancedChapter: 1, payoffWindow: 5 }), thread('a', { lastAdvancedChapter: 9, payoffWindow: 3 })], volumeStates: { v1: 'goal_met' } }),
  obligationCase({ chapter: 20, threads: [thread('c', { lastAdvancedChapter: 1, payoffWindow: 5 }), thread('b', { lastAdvancedChapter: 5, payoffVolumeKey: 'v1' }), thread('a', { lastAdvancedChapter: 9, payoffWindow: 3 })], volumeStates: { v1: 'goal_met' } }),
  obligationCase({ chapter: 20, threads: [thread('same', { lastAdvancedChapter: 3 })], mysteries: [mystery('same', { lastAdvancedChapter: 3 })] }),
  obligationCase({ chapter: 20, threads: [thread('é', { lastAdvancedChapter: 3 }), thread('z', { lastAdvancedChapter: 3 }), thread('Z', { lastAdvancedChapter: 3 })] }),
);

const manyThreads = Array.from({ length: 70 }, (_, index) => thread(`t${index}`, { lastAdvancedChapter: 1 + ((index * 7) % 30), payoffWindow: index % 5 === 0 ? 4 + (index % 11) : null }));
obligations.push(obligationCase({ chapter: 40, threads: manyThreads }));

{
  const rng = createRng(7001);
  const keys = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'];
  for (let index = 0; index < 220; index++) {
    const count = rng.int(0, index < 40 ? 12 : 6);
    const threads: Json[] = [];
    const mysteries: Json[] = [];
    for (let slot = 0; slot < count; slot++) {
      const make = rng.chance(0.7) ? thread : mystery;
      const row = make(`${rng.pick(keys)}${slot}`, {
        isOpen: rng.chance(0.9),
        intentionallyOpen: rng.chance(0.1),
        openedChapter: rng.chance(0.9) ? rng.int(1, 8) : null,
        lastAdvancedChapter: rng.chance(0.8) ? rng.int(1, 25) : null,
        payoffWindow: rng.chance(0.4) ? rng.int(2, 30) : null,
        payoffMilestoneKey: rng.chance(0.2) ? rng.pick(['m1', 'm2']) : null,
        payoffVolumeKey: rng.chance(0.25) ? rng.pick(['v1', 'v2']) : null,
        text: rng.chance(0.85) ? `Row ${slot}` : null,
      });
      (row.kind === 'thread' ? threads : mysteries).push(row);
    }
    obligations.push(
      obligationCase({
        chapter: rng.int(1, 30),
        previousEnding: rng.chance(0.6) ? { openQuestion: rng.chance(0.7) ? 'What now?' : null, handoffState: rng.chance(0.5) ? 'At the gate' : null } : null,
        threads,
        mysteries,
        volume: rng.chance(0.5) ? { volumeKey: 'v1', title: rng.chance(0.5) ? 'Vol One' : null, objective: rng.chance(0.8) ? 'Reach the sea.' : null } : null,
        milestoneStates: { m1: rng.pick(['open', 'planned', 'reached']), m2: rng.pick(['open', 'reached']) },
        volumeStates: { v1: rng.pick(['not_started', 'active', 'goal_met']), v2: rng.pick(['not_started', 'active', 'goal_met']) },
      }),
    );
  }
}

const LAMP_UNLOCK = { all: [{ milestone: 'lamp_rank_3' }] };
const FACTS = [
  { factKey: 'lamp_origin', revealChapter: null, unlock: LAMP_UNLOCK, source: 'manual', terms: ['drowned king'], writerNote: null },
  { factKey: 'sealed_truth', revealChapter: null, unlock: null, source: 'manual', terms: ['sealed vault'], writerNote: null },
];
const PLAN = { chapter: 4, volumeKey: null, isEnding: false, claimedMilestones: [] };
const WORLD = { plans: [], milestones: [{ milestoneKey: 'lamp_rank_3', state: 'open', reachedChapter: null }], volumeOrdinals: {} };
const MILESTONES = [
  { milestoneKey: 'lamp_rank_3', label: 'Mara reaches Lamp rank 3', subjectEntityKey: 'mara', state: 'open' },
  { milestoneKey: 'old_rank', label: 'Reached long ago', subjectEntityKey: null, state: 'reached' },
];

function scene(pov: string | undefined, beats = ['She lifts the lamp.', 'It burns cold.']): Json {
  return { summary: `A scene for ${pov ?? 'nobody'}`, pov, goal: 'Reach the gate.', obstacle: 'The keeper bars it.', turn: 'The gate opens.', beats, estimatedWords: 900 };
}

function output(overrides: Json = {}): Json {
  return {
    title: 'The Cold Lamp',
    objective: 'Mara tests the lamp at the gate.',
    scenes: [scene('mara'), scene('mara'), scene('ren')],
    requiredContext: ['entity:mara'],
    endingContract: { hookType: 'turn', emotionalBeat: 'Unease', openQuestion: 'Who lit the lamp?', handoffState: 'Mara at the open gate' },
    chapterPurpose: 'Mara learns what the lamp is.',
    readerValue: ['new_information'],
    ...overrides,
  };
}

function worldFor(world: Json): Json {
  return { plans: (world.plans ?? []).map((plan: Json) => ({ knowledgeContract: null, ...plan })), milestones: world.milestones, volumeOrdinals: new Map(Object.entries(world.volumeOrdinals ?? {})) };
}

function vetCase(name: string, input: Json): Json {
  const c = { plan: PLAN, facts: FACTS, world: WORLD, milestones: MILESTONES, characterKeys: ['mara', 'ren'], existing: null, steer: null, rationale: null, contextRefs: ['entity:mara'], ...input };
  const world = worldFor(c.world);
  const facts = c.facts;
  const run = (fn: () => unknown) => fn();
  const advice = run(() => chapterPlan.planAdvice(c.output, c.plan, facts, world));
  const vetted = chapterPlan.vetPlan(c.output, c.plan, facts, world);
  const op = chapterPlan.chapterPlanOp({ chapter: c.plan.chapter, steer: c.steer, rationale: c.rationale ?? undefined, existing: c.existing, vetted, contextRefs: c.contextRefs });
  const empty = chapterPlan.emptyPlanOp({ chapter: c.plan.chapter, steer: c.steer, rationale: c.rationale ?? undefined });
  const resolved = chapterPlan.resolveScenePovs(c.output, new Set(c.characterKeys));
  return {
    name,
    input: { output: c.output, plan: c.plan, facts, world: c.world, milestones: c.milestones, characterKeys: c.characterKeys, existing: c.existing, steer: c.steer, rationale: c.rationale, contextRefs: c.contextRefs },
    advice,
    vetted: { chapter: vetted.plan.chapter, plan: vetted.plan, moves: vetted.moves ?? null, claimedMilestones: vetted.claimedMilestones, droppedClaims: vetted.droppedClaims, sanitised: vetted.sanitised },
    milestones: chapterPlan.renderPlanMilestones(c.milestones, facts, c.plan, world),
    resolved,
    op,
    empty,
  };
}

const reveal3 = { knowledgeContract: { pov: ['mara'], learns: [{ entityKey: 'mara', factKey: 'lamp_origin' }] } };
const vets: Json[] = [
  vetCase('keeps a reveal the claim meets', { output: output({ claimedMilestones: ['lamp_rank_3'], ...reveal3 }) }),
  vetCase('drops an unmet reveal and cuts its terms', {
    output: output({
      scenes: [scene('mara', ['She finds the sealed vault.', 'It burns cold.']), scene('mara'), scene('mara')],
      knowledgeContract: { pov: ['mara'], learns: [{ entityKey: 'mara', factKey: 'lamp_origin' }, { entityKey: 'mara', factKey: 'sealed_truth' }] },
      moves: 'Opens the sealed vault.',
    }),
  }),
  vetCase('drops claims on unknown and already claimed milestones', {
    output: output({ claimedMilestones: ['lamp_rank_3', 'ghost'] }),
    world: { ...WORLD, plans: [{ chapter: 6, volumeKey: null, isEnding: false, claimedMilestones: ['lamp_rank_3'] }] },
  }),
  vetCase('asks one repair', { output: output({ claimedMilestones: ['ghost'], ...reveal3 }) }),
  vetCase('pools the contract over scene povs', {
    output: output({ claimedMilestones: ['lamp_rank_3'], knowledgeContract: { pov: ['kel'], learns: [{ entityKey: 'ren', factKey: 'lamp_origin' }] } }),
    steer: 'The lamp burns cold',
    rationale: 'What the story owes now:\n- x',
  }),
  vetCase('never adds a learner who is no scene pov', {
    output: output({ scenes: [scene('mara')], claimedMilestones: ['lamp_rank_3'], knowledgeContract: { pov: ['mara'], learns: [{ entityKey: 'kel', factKey: 'lamp_origin' }] } }),
  }),
  vetCase('bounds a multi-pov plan with no reveal, replacing the old contract', { output: output(), existing: { knowledgeContract: { pov: ['kel'], learns: [] }, direction: null } }),
  vetCase('falls back to the planner cast with no scene pov', {
    output: output({ scenes: [scene(undefined)], claimedMilestones: ['lamp_rank_3'], knowledgeContract: { pov: ['mara'], learns: [{ entityKey: 'mara', factKey: 'lamp_origin' }] } }),
  }),
  vetCase('clears what the replaced plan held', { output: output({ scenes: [scene(undefined)] }), existing: { knowledgeContract: { pov: ['mara'], learns: [] }, direction: 'Old' } }),
  vetCase('carries repetition and density risks', { output: output({ repetitionRisks: ['another gate scene'], densityRisk: ' Thin material ' }) }),
  vetCase('no milestones at all', { output: output({ claimedMilestones: ['lamp_rank_3'] }), world: { plans: [], milestones: [], volumeOrdinals: {} }, milestones: [] }),
  vetCase('unknown pov names and blank povs', { output: output({ scenes: [scene(' mara '), scene('the_lamp'), scene('   '), scene('')] }), characterKeys: ['mara'] }),
  vetCase('duplicate scenes', { output: output({ scenes: [scene('mara'), scene('mara'), scene('mara')], knowledgeContract: { pov: ['mara', 'mara'], learns: [] } }) }),
  vetCase('empty repetition risks and blank density', { output: output({ repetitionRisks: [], densityRisk: '   ' }) }),
  vetCase('continuation flags and handoff beat', { output: output({ continuesIntoNextChapter: true, startsFromPreviousChapter: true, handoffBeat: 'Mara at the gate' }) }),
  vetCase('empty handoff beat', { output: output({ continuesIntoNextChapter: true, handoffBeat: '' }) }),
  vetCase('objective with runs of whitespace', { output: output({ objective: '  Mara   tests\n the lamp.  ' }) }),
  vetCase('steer and existing direction', { output: output(), steer: 'Keep it short', existing: { knowledgeContract: null, direction: 'Old' } }),
  vetCase('existing direction cleared', { output: output(), steer: null, existing: { knowledgeContract: null, direction: 'Old' } }),
  vetCase('writer note replaces the offending sentence', {
    output: output({ objective: 'Mara walks in. She opens the sealed vault! Then she leaves.', chapterPurpose: 'The sealed vault.' }),
    facts: [{ factKey: 'sealed_truth', revealChapter: null, unlock: null, source: 'manual', terms: ['sealed vault'], writerNote: 'Mara finds something she cannot name.' }],
  }),
  vetCase('writer note that names the term', {
    output: output({ objective: 'Mara opens the sealed vault.' }),
    facts: [{ factKey: 'sealed_truth', revealChapter: null, unlock: null, source: 'manual', terms: ['sealed vault'], writerNote: 'The sealed vault again.' }],
  }),
  vetCase('dated reveal before and after its chapter', {
    output: output({ objective: 'The ash storm arrives.', scenes: [scene('mara', ['The ash storm hits.'])] }),
    facts: [{ factKey: 'storm', revealChapter: 9, unlock: null, source: 'manual', terms: ['ash storm'], writerNote: null }],
  }),
  vetCase('dated reveal already due', {
    output: output({ objective: 'The ash storm arrives.' }),
    facts: [{ factKey: 'storm', revealChapter: 3, unlock: null, source: 'manual', terms: ['ash storm'], writerNote: null }],
  }),
  vetCase('seed fact is never guarded', {
    output: output({ objective: 'The ash storm arrives.' }),
    facts: [{ factKey: 'storm', revealChapter: null, unlock: null, source: 'seed', terms: ['ash storm'], writerNote: null }],
  }),
  vetCase('every beat of a scene is cut', {
    output: output({ scenes: [scene('mara', ['The sealed vault opens.', 'Inside the sealed vault.'])] }),
  }),
  vetCase('ending contract and risks mention a term', {
    output: output({
      endingContract: { hookType: 'turn', emotionalBeat: 'Dread of the sealed vault', openQuestion: 'What is in the sealed vault?', handoffState: 'At the gate', mustNotResolve: ['the sealed vault', 'thread:heir'] },
      repetitionRisks: ['sealed vault scenes', 'gate scenes'],
      handoffBeat: 'Into the sealed vault',
    }),
  }),
  vetCase('unlock by volume and ending', {
    output: output({ objective: 'The drowned king speaks.', ...reveal3 }),
    plan: { chapter: 4, volumeKey: 'v2', isEnding: false, claimedMilestones: [] },
    facts: [{ factKey: 'lamp_origin', revealChapter: null, unlock: { all: [{ volume: 'v2' }, { chapter: 3 }] }, source: 'manual', terms: ['drowned king'], writerNote: null }],
    world: { plans: [], milestones: [], volumeOrdinals: { v1: 1, v2: 2 } },
  }),
  vetCase('empty moves and blank claims', { output: output({ moves: '', claimedMilestones: ['  ', ' lamp_rank_3 ', 'lamp_rank_3'] }) }),
  vetCase('plan claims a milestone and milestones render with several unlocks', {
    output: output(),
    plan: { ...PLAN, claimedMilestones: [] },
    facts: [...FACTS, { factKey: 'second', revealChapter: null, unlock: { all: [{ milestone: 'lamp_rank_3' }, { chapter: 2 }] }, source: 'manual', terms: ['whispering well'], writerNote: null }],
  }),
];

{
  const rng = createRng(9001);
  const terms = ['sealed vault', 'drowned king', 'Ash', 'ember', 'ab', 'the Keeper'];
  const sentences = [
    'Mara opens the sealed vault.',
    'The drowned king stirs beneath the lamp!',
    'Ren watches the gate.',
    'Is the Keeper lying?',
    'Ash falls on the road.',
    'An ember glows.',
    'She waits"',
    'They leave at dawn',
    'The sealed vault and the drowned king meet.',
  ];
  const text = (): string => rng.subset(sentences, 0.4).join(rng.pick([' ', '  ', '\n'])) || rng.pick(sentences);
  const optional = (): string | undefined => (rng.chance(0.7) ? text() : undefined);
  const milestoneKeys = ['m1', 'm2', 'm3'];
  for (let index = 0; index < 160; index++) {
    const facts = Array.from({ length: rng.int(0, 4) }, (_, slot) => ({
      factKey: `f${slot}`,
      revealChapter: rng.chance(0.4) ? rng.int(1, 9) : null,
      unlock: rng.chance(0.5) ? { all: rng.subset([{ milestone: 'm1' }, { milestone: 'm2' }, { chapter: rng.int(1, 8) }, { volume: 'v1' }, { ending: true }], 0.5).slice(0, 2).concat([{ milestone: 'm3' }]) } : null,
      source: rng.pick(['manual', 'manual', 'seed', 'brief']),
      terms: rng.subset(terms, 0.4),
      writerNote: rng.chance(0.4) ? text() : null,
    }));
    const chapter = rng.int(1, 9);
    const plan = { chapter, volumeKey: rng.chance(0.5) ? rng.pick(['v1', 'v2']) : null, isEnding: rng.chance(0.1), claimedMilestones: rng.chance(0.5) ? rng.subset(milestoneKeys, 0.3) : [] };
    const world = {
      plans: Array.from({ length: rng.int(0, 3) }, () => ({ chapter: rng.int(1, 9), volumeKey: rng.chance(0.5) ? 'v1' : null, isEnding: rng.chance(0.15), claimedMilestones: rng.subset(milestoneKeys, 0.3) })).filter(other => other.chapter !== chapter),
      milestones: milestoneKeys.slice(0, rng.int(0, 3)).map(key => ({ milestoneKey: key, state: rng.pick(['open', 'planned', 'reached']), reachedChapter: rng.chance(0.5) ? rng.int(1, 9) : null })),
      volumeOrdinals: { v1: 1, v2: 2 },
    };
    const povs = ['mara', 'ren', 'kel', 'ghost', ' mara '];
    const scenes = Array.from({ length: rng.int(1, 4) }, () => {
      const row: Json = { summary: text(), pov: rng.chance(0.8) ? rng.pick(povs) : undefined, goal: optional(), obstacle: optional(), turn: optional(), beats: rng.chance(0.8) ? Array.from({ length: rng.int(1, 3) }, text) : undefined };
      if (rng.chance(0.8)) row.estimatedWords = rng.int(1, 2000);
      return row;
    });
    const learns = rng.subset(facts.map(fact => ({ entityKey: rng.pick(['mara', 'ren', 'kel']), factKey: fact.factKey })), 0.6);
    const planned = output({
      title: text(),
      objective: text(),
      scenes,
      chapterPurpose: text(),
      handoffBeat: rng.chance(0.4) ? text() : undefined,
      continuesIntoNextChapter: rng.chance(0.2) || undefined,
      startsFromPreviousChapter: rng.chance(0.2) || undefined,
      endingContract: { hookType: 'turn', emotionalBeat: text(), openQuestion: text(), handoffState: text(), mustNotResolve: rng.chance(0.5) ? Array.from({ length: rng.int(0, 3) }, text) : undefined },
      knowledgeContract: rng.chance(0.7) ? { pov: rng.subset(['mara', 'ren', 'kel'], 0.6), learns: rng.chance(0.85) ? learns : undefined } : undefined,
      claimedMilestones: rng.chance(0.7) ? rng.subset([...milestoneKeys, ' m1 ', 'ghost', ''], 0.4) : undefined,
      repetitionRisks: rng.chance(0.6) ? Array.from({ length: rng.int(0, 3) }, text) : undefined,
      densityRisk: rng.chance(0.3) ? text() : undefined,
      moves: rng.chance(0.6) ? text() : undefined,
    });
    vets.push(
      vetCase(`random ${index}`, {
        output: planned,
        plan,
        facts,
        world,
        milestones: milestoneKeys.map(key => ({ milestoneKey: key, label: `Milestone ${key}`, subjectEntityKey: rng.chance(0.5) ? 'mara' : null, state: rng.pick(['open', 'planned', 'reached']) })),
        characterKeys: rng.subset(['mara', 'ren', 'kel'], 0.7),
        existing: rng.chance(0.5) ? { knowledgeContract: rng.chance(0.5) ? { pov: ['kel'] } : null, direction: rng.chance(0.5) ? 'Old' : null } : null,
        steer: rng.chance(0.4) ? 'A steer' : rng.chance(0.2) ? '' : null,
        rationale: rng.chance(0.4) ? 'Why' : null,
        contextRefs: rng.subset(['entity:mara', 'entity:ren', 'thread:debt'], 0.5),
      }),
    );
  }
}

const MESSAGES = [
  'Plan chapter 4: the tide turns.',
  'The tide turns at dawn. Mara sells the lamp.',
  'Maybe the tide turns at dawn?',
  'I do not want the tide to turn at dawn.',
  'Not the tide turning at dawn, make it dusk.',
  'What if Mara sells the lamp?',
  'Mara sells the lamp',
  '"Mara sells the lamp."',
  'Mara sells the lamp… and then regrets it.',
  'Mara sells the old lamp to the keeper, then leaves.',
  'Keep it short. Mara sells the lamp! Then she regrets it.',
  'Mara could sell the lamp.',
  'Yes, drop that. Instead Mara keeps the lamp.',
  '',
  '   ',
];
const INTENTS = ['Mara sells the lamp', 'the tide turns at dawn', 'Mara sells the lamp.', '  Mara keeps the lamp  ', 'tide', 'lamp', '', '   ', '"Mara sells the lamp"', 'Mara sells the old lamp', 'Plan chapter 4', 'Mara!'];
const DIRECTIONS = [undefined, '', '  ', 'The mine floods', ' The mine floods '];

const intentStated: Json[] = [];
for (const intent of INTENTS) for (const message of MESSAGES) intentStated.push({ intent, message, result: planJob.intentStatedIn(intent, message) });

const steers: Json[] = [];
{
  const rng = createRng(4242);
  for (let index = 0; index < 260; index++) {
    const intent = rng.chance(0.15) ? undefined : rng.pick(INTENTS);
    const direction = rng.pick(DIRECTIONS);
    const messages = Array.from({ length: rng.int(0, 3) }, () => rng.pick(MESSAGES));
    const result = planJob.planSteer(intent, direction, messages);
    steers.push({ intent: intent ?? null, direction: direction ?? null, messages, result });
  }
}

function fakeDb(messages: Json[], proposals: Json[]) {
  const column = (col: string): string => col.split('.')[1] as string;
  const matches = (node: Json, row: Json): boolean => {
    if (node.t === 'and') return node.parts.every((part: Json) => matches(part, row));
    if (node.t === 'or') return node.parts.some((part: Json) => matches(part, row));
    if (node.t === 'sql') return row.hasPlanAction === true;
    const left = row[column(node.col)];
    if (node.t === 'eq') return left === node.val;
    if (node.t === 'lt') return left < node.val;
    if (node.t === 'lte') return left <= node.val;
    if (node.t === 'gt') return left > node.val;
    throw new Error(`unknown condition ${node.t}`);
  };
  const find = (rows: Json[]) => ({
    findFirst: async (query: Json) => rows.filter(row => matches(query.where, row)).sort((a, b) => (query.orderBy ? b.id - a.id : 0))[0],
    findMany: async (query: Json) => rows.filter(row => matches(query.where, row)).sort((a, b) => b.id - a.id).slice(0, query.limit),
  });
  return { query: { chatMessages: find(messages), refinementProposals: find(proposals) } };
}

const windows: Json[] = [];
async function windowCase(name: string, messages: Json[], proposals: Json[], origin: Json) {
  const db = fakeDb(
    messages.map(message => ({ id: message.id, sessionId: message.sessionId, role: message.isAuthor ? 'user' : 'assistant', content: message.content, contexts: message.contexts ?? null })),
    proposals.map(proposal => ({ id: proposal.id, sessionId: proposal.sessionId, kind: proposal.plansChapter && !proposal.viaAction ? 'chapter_plan' : 'other', messageId: proposal.messageId, hasPlanAction: Boolean(proposal.plansChapter && proposal.viaAction) })),
  );
  const result = await planJob.authorMessagesFor(db, { sessionId: origin.sessionId ?? '', messageId: origin.messageId ?? null, proposalId: origin.proposalId });
  windows.push({ name, messages, proposals, origin, result });
}

const msg = (id: number, content: string, extra: Json = {}) => ({ id, sessionId: 's1', isAuthor: true, content, contexts: null, ...extra });
const chat = Array.from({ length: 8 }, (_, index) => msg(index + 1, `Turn ${index + 1} of the author.`));
await windowCase('latest three turns', chat, [], { sessionId: 's2', messageId: 8, proposalId: 40 });
await windowCase('up to the card message', chat, [], { sessionId: 's2', messageId: 5, proposalId: 40 });
await windowCase('fewer than three', chat.slice(0, 2), [], { sessionId: 's2', messageId: 2, proposalId: 40 });
await windowCase('stops after the previous plan card', chat, [{ id: 10, sessionId: 's1', messageId: 6, plansChapter: true }], { sessionId: 's2', messageId: 8, proposalId: 40 });
await windowCase('stops after the previous plan action', chat, [{ id: 10, sessionId: 's1', messageId: 6, plansChapter: true, viaAction: true }], { sessionId: 's2', messageId: 8, proposalId: 40 });
await windowCase('latest previous plan wins', chat, [{ id: 10, sessionId: 's1', messageId: 3, plansChapter: true }, { id: 12, sessionId: 's1', messageId: 7, plansChapter: true }], { sessionId: 's2', messageId: 8, proposalId: 40 });
await windowCase('later proposals are ignored', chat, [{ id: 50, sessionId: 's1', messageId: 7, plansChapter: true }], { sessionId: 's2', messageId: 8, proposalId: 40 });
await windowCase('other chats plans are ignored', chat, [{ id: 10, sessionId: 'other', messageId: 7, plansChapter: true }], { sessionId: 's2', messageId: 8, proposalId: 40 });
await windowCase('non plan proposals are ignored', chat, [{ id: 10, sessionId: 's1', messageId: 7, plansChapter: false }], { sessionId: 's2', messageId: 8, proposalId: 40 });
await windowCase('previous plan answered no message', chat, [{ id: 10, sessionId: 's1', messageId: null, plansChapter: true }], { sessionId: 's2', messageId: 8, proposalId: 40 });
await windowCase('previous plan on the card message', chat, [{ id: 10, sessionId: 's1', messageId: 8, plansChapter: true }], { sessionId: 's2', messageId: 8, proposalId: 40 });
await windowCase('assistant turns are not the author', [msg(1, 'a'), msg(2, 'reply', { isAuthor: false }), msg(3, 'b'), msg(4, 'reply', { isAuthor: false })], [], { sessionId: 's2', messageId: 4, proposalId: 40 });
await windowCase('other session messages are not read', [msg(1, 'a'), msg(2, 'elsewhere', { sessionId: 'other' }), msg(3, 'b')], [], { sessionId: 's2', messageId: 3, proposalId: 40 });
await windowCase('a card moved to another chat reads the original chat', [msg(1, 'a'), msg(2, 'elsewhere', { sessionId: 'adopting' }), msg(3, 'b')], [], { sessionId: 'adopting', messageId: 3, proposalId: 40 });
await windowCase('passage comments are the author words', [msg(1, '', { contexts: [{ quote: 'The tide turns late tonight.', comment: 'Make the tide turn at dawn instead.' }] }), msg(2, 'Plan it.', { contexts: [{ quote: 'q', comment: ' ' }, { quote: 'q2', comment: 'Second' }] })], [], { sessionId: 's2', messageId: 2, proposalId: 40 });
await windowCase('no card message', chat, [], { sessionId: 's2', messageId: null, proposalId: 40 });
await windowCase('no session', chat, [], { sessionId: null, messageId: 8, proposalId: 40 });
await windowCase('answered message is gone', chat, [], { sessionId: 's2', messageId: 99, proposalId: 40 });

const fixture = { obligations, vets, intentStated, steers, windows };
writeFileSync(join(outDir, 'chapter-plan.json'), `${JSON.stringify(fixture, null, 1)}\n`);
console.log(`obligations ${obligations.length}, vets ${vets.length}, intentStated ${intentStated.length}, steers ${steers.length}, windows ${windows.length}`);
