import { plugin } from 'bun';
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');

const server = join(platformRepo, 'apps/novel-forge-server/src');
const classes = await import(join(server, 'classes/app-error-code.ts'));

plugin({
  name: 'reveal-fixture-stubs',
  setup(build) {
    const noop = () => null;
    build.module('drizzle-orm', () => ({ exports: { and: noop, eq: noop, isNotNull: noop, lt: noop }, loader: 'object' }));
    build.module('@server/database', () => ({ exports: { schema: new Proxy({}, { get: () => new Proxy({}, { get: () => null }) }) }, loader: 'object' }));
    build.module('@server/classes', () => ({ exports: { AppErrorCode: classes.AppErrorCode }, loader: 'object' }));
    build.onResolve({ filter: /\/chapter-shift$/ }, () => ({ path: 'chapter-shift', namespace: 'stub' }));
    build.onLoad({ filter: /.*/, namespace: 'stub' }, () => ({ contents: 'export const shiftChapterNumber = () => 0;', loader: 'js' }));
  },
});

const reveal = await import(join(server, 'common/reveal-rule.ts'));
const unlock = await import(join(server, 'common/unlock-condition.ts'));
const contract = await import(join(server, 'common/knowledge-contract.ts'));
const gate = await import(join(server, 'common/teaching-gate.ts'));

interface Rng {
  next(): number;
  int(min: number, max: number): number;
  chance(p: number): boolean;
  pick<T>(items: readonly T[]): T;
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
    chance: (p) => next() < p,
    pick: (items) => items[Math.floor(next() * items.length)] as never,
  };
}

type Tagged = null | boolean | number | string | Tagged[] | { o: [string, Tagged][] };

function materialize(value: Tagged): unknown {
  if (Array.isArray(value)) return value.map(materialize);
  if (value === null || typeof value !== 'object') return value;
  const out: Record<string, unknown> = {};
  for (const [key, entry] of value.o) Object.defineProperty(out, key, { value: materialize(entry), enumerable: true, writable: true, configurable: true });
  return out;
}

const obj = (...entries: [string, Tagged][]): Tagged => ({ o: entries });

const NFC = 'é';
const NFD = 'é';
const KEYS = [
  'lamp_rank_4', 'lamp_rank_5', 'the_tower', 'the_sea', 'the_marsh', 'a', 'b', 'Lamp_Rank_4', NFC, NFD, 'É', 'ß', 'SS', 'İ', 'i̇', '😀', 'x y', ' k ',
  '﻿k', ' k ', 'k​', 'k᠎', ' lamp', 'lamp ', 'k\n', 'Å', 'Å', 'Å', 'ǆ', 'Ǆ', 'ǅ', 'ͅ', 'ﬁ', 'fi',
];
const BLANKS = ['', ' ', '  ', '\t', '\n', ' ', ' ', '﻿', ' ', ' 　 '];
const STRANGE_KEYS = ['constructor', '__proto__', 'toString', 'hasOwnProperty', '0', '1', '2', '10', '01', '4294967295', 'all', 'All', 'ALL', 'milestone', 'Milestone', 'volume', 'chapter', 'chapters', 'ending', 'x', NFC, NFD];
const CHAPTER_ODDITIES: Tagged[] = [0, -1, 1.5, 2.5, 1e21, 1e100, 9007199254740991, 9007199254740993, '3', '', true, false, null, [], obj(), [1], 0.1, -0.5, 100, 1e2, 3.0];

function key(rng: Rng): string {
  return rng.pick(KEYS);
}

function nonEmptyKey(rng: Rng): string {
  return rng.pick(KEYS.filter((candidate) => candidate.trim() !== ''));
}

function anyScalar(rng: Rng): Tagged {
  return rng.pick<Tagged>([null, true, false, 0, 1, -1, 7, 1.5, '', 'x', 'all', NFC, [], obj(), [1, 2], obj(['a', 1])]);
}

function validTerm(rng: Rng): Tagged {
  switch (rng.int(0, 3)) {
    case 0:
      return obj(['milestone', nonEmptyKey(rng)]);
    case 1:
      return obj(['volume', nonEmptyKey(rng)]);
    case 2:
      return obj(['chapter', rng.chance(0.1) ? rng.pick([1, 2, 1e2, 3.0, 9007199254740991]) : rng.int(1, 14)]);
    default:
      return obj(['ending', true]);
  }
}

function brokenTerm(rng: Rng): Tagged {
  switch (rng.int(0, 13)) {
    case 0:
      return anyScalar(rng);
    case 1:
      return obj();
    case 2:
      return obj(['milestone', rng.pick<Tagged>([...BLANKS, null, 5, true, [], obj(), ['a']])]);
    case 3:
      return obj(['volume', rng.pick<Tagged>([...BLANKS, null, 0, false, [], obj(['x', 1])])]);
    case 4:
      return obj(['chapter', rng.pick(CHAPTER_ODDITIES)]);
    case 5:
      return obj(['ending', rng.pick<Tagged>([false, 1, 'true', null, [], obj(), 'ending'])]);
    case 6:
      return obj(['milestone', nonEmptyKey(rng)], ['volume', nonEmptyKey(rng)]);
    case 7:
      return obj([rng.pick(STRANGE_KEYS), anyScalar(rng)]);
    case 8:
      return obj(['all', [validTerm(rng)]]);
    case 9:
      return obj(['ending', true], ['ending', false]);
    case 10:
      return [validTerm(rng)];
    case 11:
      return obj(['chapter', 1], ['milestone', 'a'], ['volume', 'b'], ['ending', true]);
    case 12:
      return obj(['milestone', nonEmptyKey(rng)], ['milestone', rng.pick<Tagged>(['', null, 3])]);
    default:
      return obj([rng.pick(['Milestone', 'MILESTONE', 'milestones', 'milestone ', ' chapter', 'endinǵ']), nonEmptyKey(rng)]);
  }
}

function termList(rng: Rng, brokenRate: number): Tagged[] {
  const count = rng.pick([1, 1, 1, 2, 2, 3, 4, 5]);
  const terms: Tagged[] = [];
  for (let i = 0; i < count; i++) terms.push(rng.chance(brokenRate) ? brokenTerm(rng) : validTerm(rng));
  if (rng.chance(0.1) && terms.length > 0) terms.push(terms[0] as Tagged);
  return terms;
}

function conditionTagged(rng: Rng): Tagged {
  const roll = rng.int(0, 19);
  if (roll < 7) return obj(['all', termList(rng, 0)]);
  if (roll < 10) return obj(['all', termList(rng, 0.5)]);
  if (roll === 10) return anyScalar(rng);
  if (roll === 11) return [obj(['all', termList(rng, 0)])];
  if (roll === 12) return obj(['all', rng.pick<Tagged>([[], null, 'x', obj(), 0, true, obj(['0', obj(['ending', true])])])]);
  if (roll === 13) return obj();
  if (roll === 14) return obj([rng.pick(STRANGE_KEYS.filter((k) => k !== 'all')), anyScalar(rng)]);
  if (roll < 18) {
    const extras: [string, Tagged][] = [];
    for (let i = rng.int(1, 4); i > 0; i--) extras.push([rng.pick(STRANGE_KEYS), anyScalar(rng)]);
    const entries: [string, Tagged][] = rng.chance(0.7) ? [['all', termList(rng, 0.2)]] : [];
    const at = rng.int(0, entries.length);
    entries.splice(at, 0, ...extras);
    return { o: entries };
  }
  if (roll === 18) return obj(['all', termList(rng, 0)], ['all', termList(rng, 1)]);
  return obj(['all', [obj(['milestone', nonEmptyKey(rng)])]], [rng.pick([NFC, NFD, 'z']), 1]);
}

type Plain = null | boolean | number | string | Plain[] | { [key: string]: Plain };
type Term = { milestone: string } | { volume: string } | { chapter: number } | { ending: true };
type ContractInput = Tagged | { learns: string[] };

function plainTerm(rng: Rng, chapterLow: number, chapterHigh: number, milestones: readonly string[]): Term {
  const kind = rng.int(0, 3);
  if (kind === 0) return { milestone: rng.pick(milestones) };
  if (kind === 1) return { volume: rng.pick(['the_tower', 'the_sea', 'the_marsh', 'unknown', NFC, NFD]) };
  if (kind === 2) return { chapter: rng.int(chapterLow, chapterHigh) };
  return { ending: true };
}

function evalCondition(rng: Rng): { all: Term[] } {
  const all: Term[] = [];
  for (let i = rng.pick([0, 1, 1, 2, 3, 4]); i > 0; i--) all.push(plainTerm(rng, -1, 15, KEYS.slice(0, 12)));
  return { all };
}

function volumeOrdinals(rng: Rng): [string, number][] {
  const pairs: [string, number][] = [];
  for (const volume of ['the_marsh', 'the_tower', 'the_sea', NFC, NFD]) if (rng.chance(0.4)) pairs.push([volume, rng.int(0, 4)]);
  if (rng.chance(0.08)) pairs.push(['the_tower', rng.int(0, 4)]);
  return pairs;
}

type ContextInput = [chapter: number, endingChapter: number | null, volumeKey: string | null, volumeOrdinals: [string, number][], reached: string[]];

function contextInput(rng: Rng, ordinals: [string, number][] = volumeOrdinals(rng)): ContextInput {
  const reached: string[] = [];
  for (let i = rng.int(0, 3); i > 0; i--) reached.push(rng.pick(KEYS.slice(0, 12)));
  const volumeKey = rng.chance(0.25) ? null : rng.pick(['the_tower', 'the_sea', 'the_marsh', 'unknown', NFC, NFD]);
  return [rng.int(-1, 16), rng.chance(0.5) ? null : rng.int(-1, 16), volumeKey, ordinals, reached];
}

function runtimeContext([chapter, endingChapter, volumeKey, ordinals, reached]: ContextInput) {
  return { chapter, endingChapter, volumeKey, volumeOrdinals: new Map(ordinals), reachedMilestones: new Set(reached) };
}

function contextOutput(ctx: { endingChapter: number | null; reachedMilestones: ReadonlySet<string> }) {
  return [ctx.endingChapter, [...ctx.reachedMilestones].sort()];
}

const FACT_KEYS = ['lamp_rank_4_rule', 'lamp_costs_memory', 'keeper_is_heir', 'lamp_is_alive', 'reader_promise', 'f_' + NFC, 'f_' + NFD, 'F_\u00c9', 'unknown_fact', ''];
const MILESTONE_KEYS = ['lamp_rank_4', 'lamp_rank_5', 'm_' + NFC, 'm_' + NFD, 'a', 'b'];

function materializeContract(value: ContractInput): unknown {
  if (value !== null && typeof value === 'object' && !Array.isArray(value) && 'learns' in value) {
    return { pov: ['mira'], learns: value.learns.map((factKey) => ({ entityKey: 'mira', factKey })) };
  }
  return materialize(value as Tagged);
}

function contractTagged(rng: Rng): Tagged {
  const roll = rng.int(0, 11);
  if (roll === 0) return rng.pick<Tagged>([null, false, 0, '', 'x', 7, true, [], [obj(['pov', ['a']])], obj(), obj(['pov', []]), obj(['learns', [obj(['entityKey', 'a'], ['factKey', 'b'])]])]);
  const povPool: Tagged[] = ['mira', 'amara', '', NFC, NFD, 5, null, true, [], obj(), ['nested'], '\u00a0', ' '];
  const pov: Tagged[] = [];
  for (let i = rng.int(0, 4); i > 0; i--) pov.push(rng.pick(povPool));
  const learns: Tagged[] = [];
  for (let i = rng.int(0, 5); i > 0; i--) learns.push(learnEntry(rng));
  const entries: [string, Tagged][] = [];
  if (!rng.chance(0.08)) entries.push(['pov', roll === 1 ? rng.pick<Tagged>(['mira', obj(['0', 'a']), null, 3]) : pov]);
  if (!rng.chance(0.12)) entries.push(['learns', roll === 2 ? rng.pick<Tagged>(['x', obj(), null, 5]) : learns]);
  if (rng.chance(0.15)) entries.push([rng.pick(['extra', 'Pov', 'POV', 'learn', '0']), anyScalar(rng)]);
  if (rng.chance(0.1)) entries.reverse();
  if (rng.chance(0.05)) entries.push(['pov', ['late']]);
  return { o: entries };
}

function learnEntry(rng: Rng): Tagged {
  if (rng.chance(0.1)) return rng.pick<Tagged>([null, 'text', 7, true, [], ['entityKey', 'factKey'], obj(), obj(['entityKey', 'a'])]);
  const entityKey: Tagged = rng.chance(0.85) ? rng.pick(['mira', 'amara', NFC, NFD, '', 'x']) : rng.pick<Tagged>([null, 3, [], obj(), true]);
  const factKey: Tagged = rng.chance(0.85) ? rng.pick(FACT_KEYS) : rng.pick<Tagged>([null, 3, [], obj(), false]);
  const entries: [string, Tagged][] = [['entityKey', entityKey], ['factKey', factKey]];
  if (rng.chance(0.2)) entries.reverse();
  if (rng.chance(0.15)) entries.push(['note', anyScalar(rng)]);
  if (rng.chance(0.05)) entries.shift();
  return { o: entries };
}

function teachingContract(rng: Rng, pool: readonly string[] = FACT_KEYS): ContractInput {
  const learns: string[] = [];
  for (let i = rng.int(0, 2); i > 0; i--) learns.push(rng.pick(pool));
  return { learns };
}

function planContract(rng: Rng, pool: readonly string[]): ContractInput {
  const roll = rng.int(0, 11);
  if (roll === 0) return null;
  if (roll === 1) return contractTagged(rng);
  return teachingContract(rng, rng.chance(0.9) ? pool : FACT_KEYS);
}

function claims(rng: Rng): string[] | null {
  if (rng.chance(0.5)) return null;
  const out: string[] = [];
  for (let i = rng.int(0, 2); i > 0; i--) out.push(rng.pick(MILESTONE_KEYS));
  return out;
}

type PlanInput = [chapter: number, volumeKey: string | null, isEnding: 0 | 1, claimed: string[] | null, contract: ContractInput];

function planInput(rng: Rng, pool: readonly string[]): PlanInput {
  const volumeKey = rng.chance(0.2) ? null : rng.pick(['the_tower', 'the_sea', 'the_marsh', 'unknown', NFC, NFD]);
  return [rng.int(0, 9), volumeKey, rng.chance(0.3) ? 1 : 0, claims(rng), planContract(rng, pool)];
}

interface FactInput {
  factKey: string;
  revealChapter: number | null;
  unlock: { all: Term[] } | null;
  source: string;
}

function factInput(rng: Rng, factKey: string = rng.pick(FACT_KEYS)): FactInput {
  const all: Term[] = [];
  for (let i = rng.int(0, 2); i > 0; i--) all.push(plainTerm(rng, 1, 8, MILESTONE_KEYS.slice(0, 3)));
  return {
    factKey,
    revealChapter: rng.chance(0.45) ? null : rng.int(0, 8),
    unlock: rng.chance(0.4) ? null : { all },
    source: rng.pick(['brief', 'manual', 'import', 'seed', 'generated', 'seed', 'manual']),
  };
}

type MilestoneInput = [milestoneKey: string, state: string, reachedChapter: number | null];

interface WorldInput {
  plans: PlanInput[];
  milestones: MilestoneInput[];
  volumeOrdinals: [string, number][];
}

function worldInput(rng: Rng, pool: readonly string[]): WorldInput {
  const plans: PlanInput[] = [];
  for (let i = rng.pick([1, 1, 2, 2, 3]); i > 0; i--) plans.push(planInput(rng, pool));
  const milestones: MilestoneInput[] = [];
  for (let i = rng.pick([0, 0, 1, 1, 2, 3]); i > 0; i--) {
    const state = rng.pick(['open', 'planned', 'reached', 'reached']);
    const reachedChapter = state === 'reached' ? (rng.chance(0.2) ? null : rng.int(0, 10)) : rng.chance(0.1) ? rng.int(0, 10) : null;
    milestones.push([rng.pick(MILESTONE_KEYS), state, reachedChapter]);
  }
  if (plans.length >= 2 && milestones.length > 0 && rng.chance(0.4)) {
    const shared = (milestones[0] as MilestoneInput)[0];
    for (const plan of plans.slice(0, 2)) plan[3] = [...(plan[3] ?? []), shared];
  }
  return { plans, milestones, volumeOrdinals: volumeOrdinals(rng) };
}

function runtimeWorld(world: WorldInput) {
  return {
    plans: world.plans.map(([chapter, volumeKey, isEnding, claimedMilestones, contract]) => ({
      chapter,
      volumeKey,
      isEnding: isEnding === 1,
      claimedMilestones,
      knowledgeContract: materializeContract(contract),
    })),
    milestones: world.milestones.map(([milestoneKey, state, reachedChapter]) => ({ milestoneKey, state, reachedChapter })),
    volumeOrdinals: new Map(world.volumeOrdinals),
  };
}

function write(name: string, value: unknown): void {
  writeFileSync(join(dirname(fileURLToPath(import.meta.url)), name), JSON.stringify(value) + '\n');
}

const rng = createRng(0x0d09);

const validation = Array.from({ length: 301 }, () => {
  const input = conditionTagged(rng);
  const value = materialize(input);
  return [input, unlock.validateUnlockCondition(value), unlock.isUnlockCondition(value)];
});

const evaluation = Array.from({ length: 301 }, () => {
  const condition = evalCondition(rng);
  const context = contextInput(rng);
  const result = unlock.evaluateUnlock(condition, runtimeContext(context));
  return [condition.all, context, result.holds, result.missing];
});

const descriptions = Array.from({ length: 300 }, () => {
  const term: Term = rng.chance(0.15) ? { chapter: rng.pick([0, -3, 1e6, 9007199254740991, 12]) } : plainTerm(rng, 1, 14, KEYS);
  return [term, unlock.describeUnlockTerm(term)];
});

const contracts = Array.from({ length: 301 }, () => {
  const input = contractTagged(rng);
  const parsed = contract.parseKnowledgeContract(materialize(input));
  return [
    input,
    parsed === null ? null : [parsed.pov, parsed.learns.map((entry: { entityKey: string; factKey: string }) => [entry.entityKey, entry.factKey])],
    reveal.learnedFactKeys(materialize(input)),
  ];
});

const requirements = Array.from({ length: 301 }, () => {
  const fact = factInput(rng);
  const context = contextInput(rng);
  return [[fact.factKey, fact.revealChapter, fact.unlock, fact.source], context, reveal.revealRequirements(fact, runtimeContext(context))];
});

const worlds = Array.from({ length: 301 }, () => {
  const pool = [rng.pick(FACT_KEYS.slice(0, 8)), rng.pick(FACT_KEYS.slice(0, 8)), rng.pick(FACT_KEYS.slice(0, 8))];
  const world = worldInput(rng, pool);
  const runtime = runtimeWorld(world);
  const facts: FactInput[] = [];
  for (let i = rng.pick([1, 1, 2, 2, 3]); i > 0; i--) facts.push(factInput(rng, rng.chance(0.9) ? rng.pick(pool) : undefined));

  const contexts = [...reveal.planUnlockContexts(runtime)].map(([plan, ctx]: [unknown, never]) => [runtime.plans.indexOf(plan as never), contextOutput(ctx)]);
  const given = contextInput(rng, world.volumeOrdinals);
  const perPlan = runtime.plans.map((plan, index) => {
    const violations = reveal.findPlanRevealViolations(plan, facts, runtime);
    const withContext = index === 0 ? reveal.findPlanRevealViolations(plan, facts, runtime, runtimeContext(given)) : null;
    return [
      contextOutput(reveal.planUnlockContext(plan, runtime)),
      violations,
      reveal.renderRevealRuleViolations(violations),
      reveal.findPlanClaimProblems(plan, runtime),
      reveal.findRivalEnding(plan, runtime),
      withContext,
    ];
  });
  return [world, facts.map((fact) => [fact.factKey, fact.revealChapter, fact.unlock, fact.source]), given.slice(0, 3).concat([given[4]] as never), contexts, perPlan, [...reveal.milestonePlanStates(runtime)], [...reveal.factPlannedChapters(facts, runtime)]];
});

type BriefInput = [chapter: number, contract: ContractInput];

const refusals: Record<string, string> = {};

const teaching = await Promise.all(
  Array.from({ length: 301 }, async () => {
    const chapter = rng.int(0, 9);
    const briefs: BriefInput[] = [];
    for (let i = rng.int(0, 3); i > 0; i--) briefs.push([rng.int(0, 10), rng.chance(0.55) ? teachingContract(rng) : rng.chance(0.5) ? null : contractTagged(rng)]);
    const drafts: [number, string, string][] = [];
    for (let i = rng.int(0, 3); i > 0; i--) drafts.push([rng.int(0, 10), rng.pick(['draft', 'final']), rng.pick(['generating', 'needs_review', 'contradiction', 'approved', 'final'])]);
    const chapters: [number, string][] = [];
    for (let i = rng.int(0, 3); i > 0; i--) chapters.push([rng.int(0, 10), rng.pick(['done', 'done', 'failed', 'skipped'])]);
    const db = {
      query: {
        briefs: { findMany: async () => briefs.filter(([at]) => at < chapter).map(([at, raw]) => ({ chapter: at, knowledgeContract: materializeContract(raw) })) },
        drafts: { findMany: async () => drafts.filter(([at]) => at < chapter).map(([at, status, reviewStatus]) => ({ chapter: at, status, reviewStatus })) },
        chapters: { findMany: async () => chapters.filter(([number, status]) => status === 'done' && number < chapter).map(([number]) => ({ number })) },
      },
    };
    const teacher: number | null = await gate.unsettledTeacher(db, 1n, chapter);
    const refusal = await gate.assertTeacherSettled(db, 1n, chapter).then(
      () => null,
      (error: { code: string; message: string }) => error,
    );
    if (refusal !== null) refusals[`${chapter}/${teacher}`] = refusal.message;
    if (refusal !== null && refusal.code !== 'DRF_016') throw new Error(`unexpected code ${refusal.code}`);
    return [chapter, briefs, drafts, chapters, teacher, refusal !== null];
  }),
);

const batches = Array.from({ length: 301 }, () => {
  const chapters: number[] = [];
  for (let i = rng.int(0, 4); i > 0; i--) chapters.push(rng.int(0, 8));
  const plans: [number, ContractInput][] = [];
  for (let chapter = 0; chapter <= 8; chapter++) if (rng.chance(0.22)) plans.push([chapter, rng.chance(0.3) ? teachingContract(rng) : rng.chance(0.5) ? null : contractTagged(rng)]);
  const map = new Map<number, { knowledgeContract?: unknown }>(plans.map(([chapter, raw]) => [chapter, raw === null && chapter % 2 === 0 ? {} : { knowledgeContract: materializeContract(raw) }]));
  return [chapters, plans, gate.untilFirstTeacher(chapters, map)];
});

write('unlock.json', { validation, evaluation, descriptions });
write('contract.json', { contracts });
write('reveal.json', { requirements, worlds });
write('teaching.json', { teaching, refusals, batches });
