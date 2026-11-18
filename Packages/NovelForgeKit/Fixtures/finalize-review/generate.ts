import { plugin } from 'bun';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');

const server = join(platformRepo, 'apps/novel-forge-server/src');
const finalizeReview = join(server, 'modules/finalize-review');
const outDir = dirname(fileURLToPath(import.meta.url));
const classes = await import(join(server, 'classes/app-error-code.ts'));

const sha256 = (body: string): string => createHash('sha256').update(body).digest('hex');

function sourceOf(path: string, marker: string): string {
  const source = readFileSync(join(server, path), 'utf8');
  if (!source.includes(marker)) throw new Error(`${path} no longer holds ${marker}`);
  return source;
}

const common: Record<string, unknown> = {};
const noop = () => undefined;

plugin({
  name: 'finalize-review-fixture-stubs',
  setup(build) {
    build.module('drizzle-orm', () => ({ exports: { and: noop, asc: noop, eq: noop, isNotNull: noop, lt: noop }, loader: 'object' }));
    build.module('@server/database', () => ({ exports: { schema: new Proxy({}, { get: () => new Proxy({}, { get: () => null }) }) }, loader: 'object' }));
    build.module('@server/classes', () => ({ exports: { AppErrorCode: classes.AppErrorCode }, loader: 'object' }));
    build.module('@server/common', () => ({ exports: common, loader: 'object' }));
  },
});

const reveal = await import(join(server, 'common/reveal-rule.ts'));
Object.assign(common, {
  revealRequirements: reveal.revealRequirements,
});

const items = await import(join(finalizeReview, 'finalize-review-items.ts'));
const isolation = await import(join(server, 'modules/ai/isolation-read-policy.ts'));
const walledOff: string = isolation.WALLED_OFF_EXCERPT;

function transpiled(source: string): string {
  return new Bun.Transpiler({ loader: 'ts' }).transformSync(source);
}

// finalize-review-gate.ts:24-59, taken from its source: importing the module pulls in the whole review and apply graph. Its body hash is review-findings.ts:75.
const gate = ((): Record<string, (...args: unknown[]) => unknown> => {
  sourceOf('modules/review/review-findings.ts', "export function hashReviewedBody(body: string): string {\n  return createHash('sha256').update(body).digest('hex');\n}");
  const source = sourceOf('modules/finalize-review/finalize-review-gate.ts', 'export function reviewRefusal(');
  const from = source.indexOf('/** Whether the review still describes the prose');
  const tail = 'export function reviewRefusal(';
  const end = source.indexOf('\n}\n', source.indexOf(tail));
  if (from === -1 || end === -1) throw new Error('the finalize review gate moved');
  const script = transpiled(`${source.slice(from, end + 3).replaceAll('export function', 'function')}\nglobalThis.__finalizeGate = { isReviewCurrent, unreachedClaims, strandedReveals, reviewRefusal };`);
  new Function('hashReviewedBody', 'effectiveChange', 'openItems', 'AppErrorCode', script)(sha256, items.effectiveChange, items.openItems, classes.AppErrorCode);
  return (globalThis as unknown as { __finalizeGate: Record<string, (...args: unknown[]) => unknown> }).__finalizeGate;
})();

// finalize-review.service.ts:523-531: the carry-over rule of storeItems, taken from its source so the fixture follows the reference as it stands.
type CarryOver = (chapterReviews: SimReview[], review: SimReview, built: Item[]) => (Item | undefined)[];
const carryOver = ((): CarryOver => {
  const source = sourceOf('modules/finalize-review/finalize-review.service.ts', 'private async storeItems(');
  const from = source.indexOf('      const earlier = chapterReviews');
  const head = '      const carried = (item: (typeof items)[number]): FinalizeReview.Item | undefined => {';
  const carried = source.indexOf(head, from);
  const end = source.indexOf('\n      };\n', carried);
  if (from === -1 || carried === -1 || end === -1) throw new Error('the carry-over of storeItems moved');
  const body = source.slice(from, end + '\n      };\n'.length);
  const wrapped = `function carryOver(chapterReviews: any[], review: any, items: any[]) {\n${body}\n  return items.map((item) => carried(item));\n}\nglobalThis.__finalizeCarryOver = carryOver;`;
  const script = transpiled(wrapped);
  new Function('sameProposal', script)(items.sameProposal);
  return (globalThis as unknown as { __finalizeCarryOver: CarryOver }).__finalizeCarryOver;
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
  const pick = <T>(list: readonly T[]): T => list[Math.floor(next() * list.length)] as T;
  return {
    next,
    int: (min, max) => min + Math.floor(next() * (max - min + 1)),
    chance: (p) => next() < p,
    pick,
    subset: (list, p = 0.5) => list.filter(() => next() < p),
  };
}

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
type Item = Record<string, Json>;

interface MaterialInput {
  extraction: Record<string, Json>;
  isolated: boolean;
  claimedMilestones: string[];
  milestones: { milestoneKey: string; label: string; state: string }[];
  entityNames: [string, string][];
  settledPromises: string[];
  plannedLearns: [string, string][];
  plannedFactKeys: string[];
  facts: { factKey: string; revealChapter: number | null; unlock: Json; source: string }[];
  unlock: { chapter: number; endingChapter: number | null; volumeKey: string | null; volumeOrdinals: [string, number][]; reachedMilestones: string[] };
  autoKeep: string[];
}

function material(input: MaterialInput): unknown {
  return {
    extraction: input.extraction,
    isolated: input.isolated,
    claimedMilestones: input.claimedMilestones,
    milestones: input.milestones,
    entityNames: new Map(input.entityNames),
    settledPromises: new Set(input.settledPromises),
    plannedLearns: new Set(input.plannedLearns.map(([entity, fact]) => `${entity}:${fact}`)),
    plannedFactKeys: input.plannedFactKeys,
    facts: input.facts,
    unlock: { ...input.unlock, volumeOrdinals: new Map(input.unlock.volumeOrdinals), reachedMilestones: new Set(input.unlock.reachedMilestones) },
    autoKeep: new Set(input.autoKeep),
  };
}

const json = (value: unknown): Json => JSON.parse(JSON.stringify(value)) as Json;
const build = (input: MaterialInput): Json => json(items.buildReviewItems(material(input)));

function write(name: string, value: unknown): void {
  writeFileSync(join(outDir, name), JSON.stringify(value) + '\n');
}

const NFC = 'café';
const NFD = 'café';
const CATEGORIES = ['entity', 'appearance', 'character_state', 'relationship', 'promise', 'knowledge', 'milestone', 'summary'];
const ENTITY_TYPES = ['character', 'faction', 'location', 'power_rule', 'item', 'concept'];
const ENTITY_KEYS = ['mira', 'oren', 'tal', NFC, NFD, 'ghost'];
const KNOWN_NAMES: [string, string][] = [['mira', 'Mira'], ['oren', 'Oren'], ['tal', 'Tal'], [NFC, 'Café']];
const MILESTONE_KEYS = ['lamp_rank_4', 'lamp_rank_5', 'tower_fall'];
const FACT_KEYS = ['lamp_rank_4_rule', 'tower_secret', 'old_name'];
const THREAD_KEYS = ['lamp_debt', 'oath'];
const MYSTERY_KEYS = ['cold_lamp', 'old_name'];

function maybe<T>(rng: Rng, value: () => T, p = 0.5): T | undefined {
  return rng.chance(p) ? value() : undefined;
}

function confidence(rng: Rng): 'high' | 'low' | undefined {
  return rng.pick([undefined, undefined, 'high', 'low'] as const);
}

function strip(record: Record<string, unknown>): Record<string, Json> {
  return Object.fromEntries(Object.entries(record).filter(([, value]) => value !== undefined)) as Record<string, Json>;
}

function extraction(rng: Rng): Record<string, Json> {
  const count = (max: number) => rng.int(0, max);
  const list = <T>(max: number, entry: () => T): T[] => Array.from({ length: count(max) }, entry);
  return strip({
    appeared: rng.subset(ENTITY_KEYS, 0.3),
    newEntities: list(2, () =>
      strip({
        entityKey: rng.pick(ENTITY_KEYS),
        name: rng.pick(['Mira', 'Mirabel', 'Oren', 'Café', 'Ghost']),
        type: rng.pick(ENTITY_TYPES),
        notes: rng.pick([undefined, '', 'a keeper of lamps']),
      }),
    ),
    threads: list(2, () =>
      strip({
        threadKey: rng.pick(THREAD_KEYS),
        status: rng.pick(['open', 'open', 'closed', 'dropped']),
        summary: rng.pick([undefined, '', 'Mira repays the keeper']),
        intentionallyOpen: rng.pick([undefined, false, true]),
        confidence: confidence(rng),
      }),
    ),
    mysteries: list(2, () =>
      strip({
        mysteryKey: rng.pick(MYSTERY_KEYS),
        status: rng.pick(['open', 'open', 'resolved', 'dropped']),
        question: rng.pick([undefined, '', 'Why does the lamp burn cold?']),
        intentionallyOpen: rng.pick([undefined, true]),
        truthFactKey: rng.pick([undefined, undefined, '', 'tower_secret']),
        confidence: confidence(rng),
      }),
    ),
    timeline: [],
    relationships: list(2, () =>
      strip({
        entityKey: rng.pick(ENTITY_KEYS),
        targetKey: rng.pick(ENTITY_KEYS),
        kind: rng.pick(['ally', 'rival']),
        note: rng.pick([undefined, '', 'since the fire']),
        evidence: 'They stand together',
        confidence: confidence(rng),
      }),
    ),
    power: [],
    characterStates: list(3, () =>
      strip({
        entityKey: rng.pick(ENTITY_KEYS),
        location: rng.pick([undefined, '', 'the tower', 'the tower top']),
        conditions: rng.pick([undefined, [], ['tired'], ['', 'cold'], ['']]),
        immediateGoal: rng.pick([undefined, '', 'climb']),
        statusNote: rng.pick([undefined, '', 'shaken']),
        evidence: rng.pick(['Mira climbs the tower', 'She stands on the tower']),
        confidence: confidence(rng),
      }),
    ),
    knowledgeChanges: list(2, () => ({ entityKey: rng.pick(ENTITY_KEYS), factKey: rng.pick([...FACT_KEYS, 'unknown_fact']), how: rng.pick(['overheard it', 'read the ledger']) })),
    chapterSummary: rng.pick([undefined, '', '   ', 'Mira climbs.', '  Mira climbs the tower.  ']),
    milestones: list(3, () => strip({ milestoneKey: rng.pick([...MILESTONE_KEYS, 'unknown_milestone']), reached: rng.chance(0.5), evidence: maybe(rng, () => 'the lamp burns cold') })),
  });
}

function unlockCondition(rng: Rng): Json {
  switch (rng.int(0, 3)) {
    case 0:
      return { all: [{ milestone: rng.pick(MILESTONE_KEYS) }] };
    case 1:
      return { all: [{ milestone: rng.pick(MILESTONE_KEYS) }, { milestone: rng.pick(MILESTONE_KEYS) }] };
    case 2:
      return { all: [{ chapter: rng.int(3, 7) }] };
    default:
      return { all: [{ ending: true }] };
  }
}

function randomMaterial(rng: Rng): MaterialInput {
  return {
    extraction: extraction(rng),
    isolated: rng.chance(0.25),
    claimedMilestones: [...rng.subset(MILESTONE_KEYS, 0.4), ...(rng.chance(0.1) ? ['lamp_rank_4'] : [])],
    milestones: MILESTONE_KEYS.filter(() => rng.chance(0.8)).map((milestoneKey) => ({
      milestoneKey,
      label: `Label of ${milestoneKey}`,
      state: rng.pick(['open', 'planned', 'reached']),
    })),
    entityNames: rng.subset(KNOWN_NAMES, 0.8),
    settledPromises: rng.subset(['thread:lamp_debt', 'thread:oath', 'mystery:cold_lamp', 'mystery:old_name'], 0.3),
    plannedLearns: rng.subset(
      ENTITY_KEYS.flatMap((entity) => FACT_KEYS.map((fact): [string, string] => [entity, fact])),
      0.1,
    ),
    plannedFactKeys: rng.subset(FACT_KEYS, 0.5),
    facts: FACT_KEYS.filter(() => rng.chance(0.85)).map((factKey) => {
      const roll = rng.int(0, 4);
      return {
        factKey,
        revealChapter: roll === 1 ? rng.int(3, 7) : null,
        unlock: roll <= 2 ? unlockCondition(rng) : null,
        source: roll === 3 ? 'seed' : rng.pick(['manual', 'brief', 'generated']),
      };
    }),
    unlock: {
      chapter: 5,
      endingChapter: rng.pick([null, 5, 8]),
      volumeKey: null,
      volumeOrdinals: [],
      reachedMilestones: rng.subset(MILESTONE_KEYS, 0.5),
    },
    autoKeep: rng.chance(0.3) ? [...items.ROUTINE_CATEGORIES] : rng.subset(CATEGORIES, 0.5),
  };
}

// finalize-review-rules.spec.ts:14-43
const SPEC_EXTRACTION: Record<string, Json> = {
  appeared: ['mira'],
  newEntities: [],
  threads: [{ threadKey: 'lamp_debt', status: 'closed', summary: 'Mira repays the keeper' }],
  mysteries: [],
  timeline: [],
  relationships: [],
  power: [],
  characterStates: [{ entityKey: 'mira', location: 'the tower', evidence: 'Mira climbs the tower' }],
  knowledgeChanges: [],
  chapterSummary: 'Mira climbs.',
  milestones: [],
};

function specMaterial(overrides: Partial<MaterialInput> = {}): MaterialInput {
  return {
    extraction: SPEC_EXTRACTION,
    isolated: false,
    claimedMilestones: ['lamp_rank_4'],
    milestones: [{ milestoneKey: 'lamp_rank_4', label: 'Mira reaches the fourth rank', state: 'planned' }],
    entityNames: [['mira', 'Mira']],
    settledPromises: [],
    plannedLearns: [],
    plannedFactKeys: ['lamp_rank_4_rule'],
    facts: [{ factKey: 'lamp_rank_4_rule', revealChapter: null, unlock: { all: [{ milestone: 'lamp_rank_4' }] }, source: 'manual' }],
    unlock: { chapter: 5, endingChapter: null, volumeKey: null, volumeOrdinals: [], reachedMilestones: ['lamp_rank_4'] },
    autoKeep: [],
    ...overrides,
  };
}

const specItems: [string, MaterialInput][] = [
  ['should flag a claimed milestone the prose missed and propose it stays locked, naming the reveals that need it', specMaterial()],
  ['should propose a claimed milestone the prose reached as a routine update', specMaterial({ extraction: { ...SPEC_EXTRACTION, milestones: [{ milestoneKey: 'lamp_rank_4', reached: true, evidence: 'the lamp burns cold' }] } })],
  ['should keep routine items of an auto-keep category at once and leave payoffs to the author', specMaterial({ autoKeep: ['appearance', 'character_state', 'promise'] })],
  ['should never keep anything automatically on an isolated chapter', specMaterial({ isolated: true, autoKeep: ['appearance', 'character_state'] })],
  [
    'should key an item by the record it is about, so a re-read worded differently is the same item',
    specMaterial({
      extraction: {
        ...SPEC_EXTRACTION,
        threads: [{ threadKey: 'lamp_debt', status: 'closed', summary: 'The keeper is repaid in full' }],
        characterStates: [{ entityKey: 'mira', location: 'the tower top', evidence: 'She stands on the tower' }],
      },
    }),
  ],
  ['should name the reveals a claimed milestone carries even when the prose reached it', specMaterial({ extraction: { ...SPEC_EXTRACTION, milestones: [{ milestoneKey: 'lamp_rank_4', reached: true }] } })],
  ['should withhold every excerpt read from an isolated chapter', specMaterial({ isolated: true })],
  [
    'should ask before a reported new entity renames a record already in the Story Bible, even in an auto-keep category',
    specMaterial({ extraction: { ...SPEC_EXTRACTION, appeared: [], newEntities: [{ entityKey: 'mira', name: 'Mirabel', type: 'character' }] }, autoKeep: ['entity'] }),
  ],
  [
    'should ask before a confident open report reopens a thread already paid off, even in an auto-keep category',
    specMaterial({
      extraction: { ...SPEC_EXTRACTION, threads: [{ threadKey: 'lamp_debt', status: 'open', summary: 'Mira owes the keeper' }] },
      settledPromises: ['thread:lamp_debt'],
      autoKeep: ['promise'],
    }),
  ],
  [
    'should ask before a confident open report reopens a question already answered',
    specMaterial({
      extraction: { ...SPEC_EXTRACTION, threads: [], mysteries: [{ mysteryKey: 'cold_lamp', status: 'open', question: 'Why does the lamp burn cold?' }] },
      settledPromises: ['mystery:cold_lamp'],
      autoKeep: ['promise'],
    }),
  ],
  [
    'should keep a confident open report on a promise still open as routine',
    specMaterial({
      extraction: { ...SPEC_EXTRACTION, threads: [{ threadKey: 'lamp_debt', status: 'open', summary: 'Mira owes the keeper' }] },
      settledPromises: ['mystery:lamp_debt'],
      autoKeep: ['promise'],
    }),
  ],
  [
    'should read a reported new entity that is already a record under the same name as an appearance',
    specMaterial({ extraction: { ...SPEC_EXTRACTION, appeared: [], newEntities: [{ entityKey: 'mira', name: 'Mira', type: 'character' }] } }),
  ],
  // finalize-review.service.spec.ts:86-97, 179-190: the service's default material, every routine category kept until the author chooses.
  ['should read the approved revision into consequential and routine items', specMaterial({ claimedMilestones: [], milestones: [], plannedFactKeys: [], facts: [], autoKeep: [...items.ROUTINE_CATEGORIES] })],
];

const rng = createRng(0x0f06);

const generatedItems = Array.from({ length: 80 }, () => randomMaterial(rng));
write('items.json', {
  routine: items.ROUTINE_CATEGORIES,
  withheld: walledOff,
  spec: specItems.map(([name, input]) => ({ name, material: input, items: build(input) })),
  generated: generatedItems.map((input) => ({ material: input, items: build(input) })),
});

function proposal(rng: Rng): Record<string, Json> {
  const key = () => rng.pick(['mira', 'oren', NFC, NFD]);
  switch (rng.int(0, 8)) {
    case 0:
      return { category: 'entity', entity: strip({ entityKey: key(), name: rng.pick(['Mira', 'Oren']), type: rng.pick(ENTITY_TYPES), notes: rng.pick([undefined, 'a keeper']) }) };
    case 1:
      return { category: 'appearance', entityKey: key() };
    case 2:
      return {
        category: 'character_state',
        state: strip({
          entityKey: key(),
          location: rng.pick([undefined, 'the tower']),
          conditions: rng.pick([undefined, [], ['tired']]),
          immediateGoal: rng.pick([undefined, 'climb']),
          statusNote: rng.pick([undefined, 'shaken']),
          evidence: 'Mira climbs',
        }),
      };
    case 3:
      return { category: 'relationship', relationship: strip({ entityKey: key(), targetKey: key(), kind: 'ally', note: rng.pick([undefined, 'since the fire']), evidence: 'together' }) };
    case 4:
      return {
        category: 'promise',
        thread: strip({ threadKey: rng.pick(THREAD_KEYS), status: rng.pick(['open', 'closed', 'dropped']), summary: rng.pick([undefined, 'repaid']), intentionallyOpen: rng.pick([undefined, true, false]) }),
      };
    case 5:
      return {
        category: 'promise',
        mystery: strip({
          mysteryKey: rng.pick(MYSTERY_KEYS),
          status: rng.pick(['open', 'resolved', 'dropped']),
          question: rng.pick([undefined, 'why?']),
          intentionallyOpen: rng.pick([undefined, true]),
          truthFactKey: rng.pick([undefined, 'tower_secret']),
        }),
      };
    case 6:
      return { category: 'knowledge', entityKey: key(), factKey: rng.pick(FACT_KEYS), how: 'overheard it' };
    case 7:
      return { category: 'milestone', milestoneKey: rng.pick(MILESTONE_KEYS), reached: rng.chance(0.5) };
    default:
      return { category: 'summary', text: rng.pick(['Mira climbs.', NFD]) };
  }
}

const PATCH_FIELDS = [
  'name', 'notes', 'location', 'conditions', 'immediateGoal', 'statusNote', 'note', 'status', 'summary', 'question', 'intentionallyOpen', 'how', 'reached', 'text',
  'entityKey', 'evidence', 'category', 'threadKey', 'truthFactKey', 'kind', '0',
];
const PATCH_VALUES: Json[] = [
  null, '', ' ', ' ', 'the lighthouse', NFD, 'open', 'closed', 'resolved', 'dropped', true, false, 0, 1, [], ['tired'], ['a', 'b'], ['a', 1], [null], {}, { a: 1 },
];

const EDITABLE_FIELDS: Record<string, string[]> = {
  entity: ['name', 'notes'],
  character_state: ['location', 'conditions', 'immediateGoal', 'statusNote'],
  relationship: ['note'],
  thread: ['status', 'summary', 'intentionallyOpen'],
  mystery: ['status', 'question', 'intentionallyOpen'],
  knowledge: ['how'],
  milestone: ['reached'],
  summary: ['text'],
};

function patch(rng: Rng, proposed: Record<string, Json>): Record<string, Json> {
  const record = proposed.category === 'promise' ? ('thread' in proposed ? 'thread' : 'mystery') : (proposed.category as string);
  const editable = EDITABLE_FIELDS[record] ?? [];
  const field = () => (editable.length > 0 && rng.chance(0.8) ? rng.pick(editable) : rng.pick(PATCH_FIELDS));
  const entries: [string, Json][] = Array.from({ length: rng.pick([0, 1, 1, 1, 2, 2, 3]) }, () => [field(), rng.pick(PATCH_VALUES)]);
  return Object.fromEntries(entries);
}

const reorder = (value: Json): Json => {
  if (Array.isArray(value)) return value.map(reorder);
  if (value === null || typeof value !== 'object') return value;
  return Object.fromEntries(Object.entries(value).reverse().map(([key, entry]) => [key, reorder(entry)]));
};

function variant(rng: Rng, value: Record<string, Json>): Json {
  switch (rng.int(0, 4)) {
    case 0:
      return json(value);
    case 1:
      return reorder(value);
    case 2:
      return JSON.parse(JSON.stringify(value).replaceAll(NFC, NFD).replaceAll('Mira', 'Mirà')) as Json;
    case 3:
      return proposal(rng);
    default:
      return JSON.parse(JSON.stringify(value).replace('"evidence":"', '"evidence":"x').replace('true', 'false')) as Json;
  }
}

const edits = Array.from({ length: 350 }, () => {
  const proposed = proposal(rng);
  const change = patch(rng, proposed);
  return { proposed, patch: change, itemKey: items.itemKeyOf(proposed), result: json(items.editedChange(proposed, change)) };
});
const sames = Array.from({ length: 200 }, () => {
  const left = proposal(rng);
  const right = variant(rng, left);
  return { left, right, same: items.sameProposal(left, right) };
});
const autoKeep = [null, {}, { finalizeReview: {} }, { finalizeReview: { autoKeep: ['appearance'] } }, { finalizeReview: { autoKeep: [] } }, { finalizeReview: { autoKeep: ['milestone', 'entity'] } }].map(
  (config) => ({ chosen: (config as { finalizeReview?: { autoKeep?: string[] } } | null)?.finalizeReview?.autoKeep ?? null, expected: items.effectiveAutoKeep(config) }),
);
// finalize-review-rules.spec.ts:186-195
const specProposal = { category: 'character_state', state: { entityKey: 'mira', location: 'the tower', evidence: 'x' } };
const specEdits = [{ location: 'the lighthouse' }, { entityKey: 'oren' }].map((change) => ({ proposed: specProposal, patch: change, itemKey: items.itemKeyOf(specProposal), result: json(items.editedChange(specProposal, change)) }));
for (const entry of [...specEdits, ...edits]) {
  const outcome = entry.result as { refused?: string };
  if (outcome.refused !== undefined) (entry as Record<string, unknown>).message = classes.AppErrorCode.FRV_009.create({ reason: outcome.refused }).message;
}
write('edits.json', { spec: specEdits, edits, same: sames, autoKeep });

const PROSE = 'Mira climbs the tower and the lamp burns cold.';

function gateItem(rng: Rng): Item {
  const milestone = rng.chance(0.75);
  const reached = rng.chance(0.5);
  const proposed = milestone ? { category: 'milestone', milestoneKey: rng.pick(MILESTONE_KEYS), reached } : proposal(rng);
  const decision = rng.pick([null, 'kept', 'kept', 'edited', 'skipped']);
  const edited = decision === 'edited' && rng.chance(0.85) ? (milestone ? { ...proposed, reached: rng.chance(0.5) } : proposed) : null;
  const subjectKey = milestone ? (proposed as { milestoneKey: string }).milestoneKey : 'mira';
  return {
    itemKey: items.itemKeyOf(proposed),
    category: proposed.category as string,
    triage: rng.pick(['routine', 'consequential']),
    basis: 'observed',
    subjectKey,
    claim: 'claim',
    evidence: null,
    proposed: json(proposed),
    flag: milestone ? rng.pick([null, 'missed_milestone', 'unclaimed_milestone']) : null,
    dependents: rng.pick([null, [], ['lamp_rank_4_rule'], ['lamp_rank_4_rule', 'tower_secret']]),
    decision,
    edited: json(edited),
    reason: decision === 'skipped' ? 'not yet' : null,
    autoKept: false,
  };
}

interface GateReview {
  draftRevision: number;
  sourceHash: string;
  status: string;
  items: Item[];
}

function gateCase(reviews: GateReview[], draft: { revision: number; body: string }) {
  const refusal = gate.reviewRefusal(
    reviews.map((review) => ({ ...review, bridgeOnly: false })),
    draft,
  ) as { code: string; message: string } | null;
  return { reviews, draft, refusal: refusal && { code: refusal.code, message: refusal.message } };
}

const decided: Item = { ...gateItem(createRng(1)), category: 'appearance', itemKey: 'appearance:mira', subjectKey: 'mira', flag: null, dependents: null, decision: 'kept', proposed: { category: 'appearance', entityKey: 'mira' }, edited: null, reason: null };
const ready = (list: Item[], overrides: Partial<GateReview> = {}): GateReview => ({ draftRevision: 3, sourceHash: sha256(PROSE), status: 'ready', items: list, ...overrides });
const missed: Item = { ...decided, category: 'milestone', itemKey: 'milestone:lamp_rank_4', flag: 'missed_milestone', subjectKey: 'lamp_rank_4', dependents: ['lamp_rank_4_rule'], proposed: { category: 'milestone', milestoneKey: 'lamp_rank_4', reached: false } };
const routine: Item = { ...missed, flag: null, proposed: { category: 'milestone', milestoneKey: 'lamp_rank_4', reached: true } };
// finalize-review-rules.spec.ts:197-246
const specGate: [string, GateReview[], { revision: number; body: string }][] = [
  ['should let a chapter approved before reviews existed finalize on the direct path', [], { revision: 3, body: PROSE }],
  ['should invalidate the review once the prose is edited after approval', [ready([decided])], { revision: 4, body: `${PROSE} Edited.` }],
  ['should refuse a finalize whose prose does not hash to the reviewed source', [ready([decided])], { revision: 3, body: 'Other prose at the same revision.' }],
  ['should accept a finalize whose prose hashes to the reviewed source', [ready([decided])], { revision: 3, body: PROSE }],
  ['should refuse while an item is unanswered', [ready([{ ...decided, decision: null }])], { revision: 3, body: PROSE }],
  ['should refuse while the review is still being read', [ready([decided], { status: 'preparing' })], { revision: 3, body: PROSE }],
  ['should refuse a missed milestone kept locked while the plan reveals what it unlocks', [ready([{ ...missed, decision: 'kept', edited: null }])], { revision: 3, body: PROSE }],
  ['should accept a missed milestone the author keeps reached', [ready([{ ...missed, decision: 'edited', edited: { category: 'milestone', milestoneKey: 'lamp_rank_4', reached: true } }])], { revision: 3, body: PROSE }],
  ['should refuse a skipped routine "reached" milestone the plan reveals through', [ready([{ ...routine, decision: 'skipped', edited: null, reason: 'not yet' }])], { revision: 3, body: PROSE }],
  ['should refuse a routine "reached" milestone edited to not reached', [ready([{ ...routine, decision: 'edited', edited: { category: 'milestone', milestoneKey: 'lamp_rank_4', reached: false } }])], { revision: 3, body: PROSE }],
  ['should accept a kept routine "reached" milestone', [ready([{ ...routine, decision: 'kept', edited: null }])], { revision: 3, body: PROSE }],
  ['should refuse a review whose reading failed', [ready([decided], { status: 'failed' })], { revision: 3, body: PROSE }],
  ['should accept a review already applied', [ready([{ ...decided, decision: null }], { status: 'applied' })], { revision: 3, body: PROSE }],
];

const generatedGate = Array.from({ length: 120 }, () => {
  const reviews = Array.from({ length: rng.pick([1, 1, 1, 2, 3]) }, () => ({
    draftRevision: rng.pick([2, 3, 3, 3, 3, 3, 3, 4]),
    sourceHash: sha256(rng.chance(0.08) ? 'Other prose.' : PROSE),
    status: rng.pick(['preparing', 'ready', 'ready', 'ready', 'ready', 'failed', 'applied']),
    items: Array.from({ length: rng.int(0, 4) }, () => gateItem(rng)),
  }));
  for (const review of reviews) if (rng.chance(0.3)) for (const item of review.items) if (item.decision === null) item.decision = 'kept';
  return gateCase(reviews, { revision: 3, body: rng.chance(0.95) ? PROSE : `${PROSE} Edited.` });
});
const lists = Array.from({ length: 100 }, () => {
  const list = Array.from({ length: rng.int(0, 5) }, () => gateItem(rng));
  return { items: list, unreached: gate.unreachedClaims(list).map((item: Item) => list.indexOf(item)), stranded: gate.strandedReveals(list), open: items.openItems(list).map((item: Item) => list.indexOf(item)), effective: list.map((item) => items.effectiveChange(item)) };
});
const gateFixture = { spec: specGate.map(([name, reviews, draft]) => ({ name, ...gateCase(reviews, draft) })), generated: generatedGate, lists };
const codes = new Set(generatedGate.map((entry) => entry.refusal?.code ?? 'none'));
for (const code of ['none', 'FRV_002', 'FRV_003', 'FRV_004', 'FRV_005', 'FRV_006']) if (!codes.has(code)) throw new Error(`no gate case yields ${code}`);
write('gate.json', gateFixture);

interface SimReview {
  id: number;
  draftRevision: number;
  items: Item[];
}

type Op =
  | { op: 'read'; revision: number; extraction: Record<string, Json>; isolated: boolean; autoKeep: string[] }
  | { op: 'decide'; itemKey: string; decision: string; edited: Json; reason: string | null }
  | { op: 'keepRoutine' };

// finalize-review.service.ts:518-561 (storeItems), :346-366 (decide), :368-379 (keepRoutine) over rows held in memory.
function simulate(ops: Op[]): { steps: (Op & { after: Item[] })[]; items: Item[] } {
  const reviews: SimReview[] = [];
  const latest = (): SimReview => reviews.reduce((best, review) => (review.draftRevision > best.draftRevision ? review : best));
  const steps = ops.map((op) => {
    if (op.op === 'read') {
      let review = reviews.find((candidate) => candidate.draftRevision === op.revision);
      if (!review) {
        review = { id: reviews.length + 1, draftRevision: op.revision, items: [] };
        reviews.push(review);
      }
      const built = json(items.buildReviewItems(material({ ...CARRY_BASE, extraction: op.extraction, isolated: op.isolated, autoKeep: op.autoKeep }))) as Item[];
      const priors = carryOver(reviews, review, built);
      review.items = built.map((item, position) => {
        const prior = priors[position];
        const { decision, autoKept, ...rest } = item;
        return prior
          ? { ...rest, decision: prior.decision as Json, reason: prior.reason as Json, edited: (prior.edited ?? null) as Json, autoKept: prior.autoKept as Json }
          : { ...rest, decision, autoKept, reason: null, edited: null };
      });
    } else if (op.op === 'decide') {
      const item = latest().items.find((candidate) => candidate.itemKey === op.itemKey);
      if (!item) throw new Error(`no item ${op.itemKey}`);
      Object.assign(item, { decision: op.decision, edited: op.edited, reason: op.reason, autoKept: false });
    } else {
      for (const item of latest().items) if (item.triage === 'routine' && item.decision === null) item.decision = 'kept';
    }
    return { ...op, after: latest().items.map(({ itemKey, decision, edited, reason, autoKept }) => json({ itemKey, decision, edited, reason, autoKept }) as Item) };
  });
  return { steps, items: latest().items };
}

const CARRY_STATES = ['the tower', 'the tower top', 'the lighthouse'];

const CARRY_BASE = specMaterial({
  entityNames: [['mira', 'Mira'], ['oren', 'Oren']],
  facts: [
    { factKey: 'lamp_rank_4_rule', revealChapter: null, unlock: { all: [{ milestone: 'lamp_rank_4' }] }, source: 'manual' },
    { factKey: 'tower_secret', revealChapter: 9, unlock: null, source: 'manual' },
  ],
});

function carryRead(rng: Rng, revision: number, autoKeep: string[]): Op {
  const states = rng.chance(0.85) ? [{ entityKey: 'mira', location: rng.pick(CARRY_STATES), evidence: 'Mira climbs the tower' }] : [];
  return {
    op: 'read',
    revision,
    extraction: {
      ...SPEC_EXTRACTION,
      appeared: rng.pick([['mira'], ['mira', 'oren'], []]),
      threads: rng.chance(0.85) ? [{ threadKey: 'lamp_debt', status: rng.pick(['closed', 'closed', 'open']), summary: rng.pick(['Mira repays the keeper', 'The keeper is repaid at last']) }] : [],
      characterStates: states,
      relationships: rng.chance(0.5) ? [{ entityKey: 'mira', targetKey: 'oren', kind: 'ally', note: rng.pick(['since the fire', 'for now']), evidence: 'together', confidence: rng.pick([undefined, 'low']) }] : [],
      knowledgeChanges: rng.chance(0.5) ? [{ entityKey: 'mira', factKey: 'tower_secret', how: rng.pick(['overheard it', 'read the ledger']) }] : [],
      milestones: rng.chance(0.5) ? [{ milestoneKey: 'lamp_rank_4', reached: rng.chance(0.6) }] : [],
      chapterSummary: rng.pick(['Mira climbs.', 'Mira reaches the top.']),
    } as Record<string, Json>,
    isolated: rng.chance(0.1),
    autoKeep,
  };
}

function editFor(rng: Rng, item: Item): Json {
  const proposed = item.proposed as Record<string, Json>;
  const choices: Record<string, Record<string, Json>[]> = {
    entity: [{ name: 'Mirabel' }, { notes: null }],
    character_state: [{ location: 'the lighthouse' }, { location: null, statusNote: 'shaken' }, { conditions: ['tired'] }],
    relationship: [{ note: 'until the end' }, { note: null }],
    promise: 'thread' in proposed ? [{ status: 'open' }, { summary: 'Half paid' }] : [{ status: 'resolved' }],
    knowledge: [{ how: 'read the ledger' }],
    milestone: [{ reached: true }, { reached: false }],
    summary: [{ text: 'Mira reaches the top.' }],
  };
  const outcome = items.editedChange(proposed, rng.pick(choices[item.category as string] ?? [{}]));
  if (!('change' in outcome)) throw new Error(`edit refused: ${outcome.refused}`);
  return json(outcome.change);
}

function randomOps(rng: Rng): Op[] {
  let revision = 1;
  let autoKeep = rng.chance(0.5) ? [...items.ROUTINE_CATEGORIES] : rng.subset(items.ROUTINE_CATEGORIES as string[], 0.4);
  const ops: Op[] = [carryRead(rng, revision, autoKeep)];
  let current = simulate(ops).items;
  for (let step = rng.int(6, 18); step > 0; step--) {
    const roll = rng.next();
    if (roll < 0.45 && current.length > 0) {
      const item = rng.pick(current);
      const decision = item.category === 'appearance' ? rng.pick(['kept', 'skipped']) : rng.pick(['kept', 'skipped', 'edited']);
      ops.push({ op: 'decide', itemKey: item.itemKey as string, decision, edited: decision === 'edited' ? editFor(rng, item) : null, reason: decision === 'skipped' ? rng.pick(['not paid yet', 'wrong']) : rng.pick([null, 'fine']) });
    } else if (roll < 0.55) {
      ops.push({ op: 'keepRoutine' });
    } else {
      if (roll < 0.75) revision += 1;
      if (rng.chance(0.2)) autoKeep = rng.subset(items.ROUTINE_CATEGORIES as string[], 0.5);
      ops.push(carryRead(rng, revision, autoKeep));
    }
    current = simulate(ops).items;
  }
  return ops;
}

const withThread = (revision: number, summary: string): Op => ({
  op: 'read',
  revision,
  extraction: { ...SPEC_EXTRACTION, threads: [{ threadKey: 'lamp_debt', status: 'closed', summary }] },
  isolated: false,
  autoKeep: [...items.ROUTINE_CATEGORIES],
});
const withState = (revision: number, location: string): Op => ({
  op: 'read',
  revision,
  extraction: { ...SPEC_EXTRACTION, characterStates: [{ entityKey: 'mira', location, evidence: 'Mira climbs the tower' }] },
  isolated: false,
  autoKeep: [],
});
const namedOps: [string, Op[]][] = [
  // finalize-review.service.spec.ts:125-137
  [
    'should never ask a skipped item again, even when the revision is read again',
    [
      withThread(3, 'Mira repays the keeper'),
      { op: 'decide', itemKey: 'promise:thread:lamp_debt', decision: 'skipped', edited: null, reason: 'the debt is only half paid' },
      withThread(3, 'Mira repays the keeper'),
    ],
  ],
  // finalize-review.service.spec.ts:139-154
  [
    "should carry a skip into the next revision's review even when the re-read words the update differently",
    [
      withThread(3, 'Mira repays the keeper'),
      { op: 'decide', itemKey: 'promise:thread:lamp_debt', decision: 'skipped', edited: null, reason: 'not paid yet' },
      withThread(4, 'The keeper is repaid at last'),
    ],
  ],
  [
    'should carry a keep only onto the change the author saw',
    [
      withState(3, 'the tower'),
      { op: 'decide', itemKey: 'character_state:mira', decision: 'kept', edited: null, reason: null },
      withState(3, 'the tower'),
      withState(3, 'the tower top'),
      withState(4, 'the tower top'),
    ],
  ],
  [
    'divergence: a keep given on a proposal comes back when a later read proposes it again',
    [
      withState(3, 'the tower'),
      { op: 'decide', itemKey: 'character_state:mira', decision: 'kept', edited: null, reason: null },
      withState(3, 'the tower top'),
      withState(3, 'the tower'),
    ],
  ],
  [
    'divergence: an earlier revision skip stays overruled by a keep that stopped carrying',
    [
      withState(3, 'the tower'),
      { op: 'decide', itemKey: 'character_state:mira', decision: 'skipped', edited: null, reason: 'wrong' },
      withState(4, 'the tower'),
      { op: 'decide', itemKey: 'character_state:mira', decision: 'kept', edited: null, reason: null },
      withState(4, 'the tower top'),
      withState(4, 'the lighthouse'),
    ],
  ],
  [
    'divergence: a skip outlives a read that leaves the item out',
    [
      withThread(3, 'Mira repays the keeper'),
      { op: 'decide', itemKey: 'promise:thread:lamp_debt', decision: 'skipped', edited: null, reason: 'not paid yet' },
      { op: 'read', revision: 3, extraction: { ...SPEC_EXTRACTION, threads: [] }, isolated: false, autoKeep: [...items.ROUTINE_CATEGORIES] },
      withThread(3, 'Mira repays the keeper'),
    ],
  ],
];

write('carry.json', {
  base: CARRY_BASE,
  named: namedOps.map(([name, ops]) => ({ name, steps: simulate(ops).steps })),
  generated: Array.from({ length: 50 }, () => ({ steps: simulate(randomOps(rng)).steps })),
});
