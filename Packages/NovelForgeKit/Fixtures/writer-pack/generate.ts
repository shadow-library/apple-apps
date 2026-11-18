import { plugin } from 'bun';
import { createHash } from 'node:crypto';
import { readdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// Run as: PLATFORM_REPO=<checkout> bun --tsconfig-override "$PLATFORM_REPO/apps/novel-forge-server/tsconfig.json" generate.ts
// Each scenario is a novel the Swift test builds (as a world, and through typed records when `storable`); the expected pack is the reference's own
// forChapter over an in-memory database holding the same rows, its `where` read by the reference's tests/sql-filter.ts.
const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');

const appRoot = join(platformRepo, 'apps/novel-forge-server');
const server = join(appRoot, 'src');
const outDir = dirname(fileURLToPath(import.meta.url));
const classes = await import(join(server, 'classes/app-error-code.ts'));

const commonExports: Record<string, any> = {};
for (const file of readdirSync(join(server, 'common')).filter((name) => name.endsWith('.ts') && !name.endsWith('.spec.ts') && name !== 'index.ts').sort()) {
  try {
    Object.assign(commonExports, await import(join(server, 'common', file)));
  } catch {
    continue;
  }
}

// The native token estimate (TokenBudget.swift), in place of o200k_base: decision 18.
type RunKind = 'letter' | 'digit' | 'space' | 'control' | 'symbol' | 'wide' | 'alphabetic' | 'otherBmp' | 'astral';
function kindOf(code: number): RunKind {
  if (code < 0x80) {
    if ((code >= 0x41 && code <= 0x5a) || (code >= 0x61 && code <= 0x7a)) return 'letter';
    if (code >= 0x30 && code <= 0x39) return 'digit';
    if (code === 0x20) return 'space';
    if (code < 0x20 || code === 0x7f) return 'control';
    return 'symbol';
  }
  if (code >= 0x10000) return 'astral';
  if ((code >= 0x3040 && code <= 0x30ff) || (code >= 0x3400 && code <= 0x9fff) || (code >= 0xac00 && code <= 0xd7af) || (code >= 0xf900 && code <= 0xfaff)) return 'wide';
  if (code <= 0x2fff && /^\p{L}$/u.test(String.fromCodePoint(code))) return 'alphabetic';
  return 'otherBmp';
}
function runCost(kind: RunKind, length: number): number {
  switch (kind) {
    case 'letter': return 110 + 65 * Math.max(0, Math.ceil((length - 9) / 8));
    case 'digit': return 125 * Math.ceil(length / 3);
    case 'space': return length === 1 ? 0 : 50 + 5 * length;
    case 'control': return 105 + 10 * length;
    case 'symbol': return 80 + 25 * length;
    case 'wide': return 100 * length;
    case 'alphabetic': return 45 * length;
    case 'otherBmp': return 100 * length;
    case 'astral': return 250 * length;
  }
}
const RUN_KINDS: readonly RunKind[] = ['letter', 'digit', 'space', 'control', 'symbol'];
function estimateTokens(text: string): number {
  let sum = 0;
  let kind: RunKind | null = null;
  let length = 0;
  for (const char of text) {
    const next = kindOf(char.codePointAt(0) ?? 0);
    if (next === kind && RUN_KINDS.includes(next)) {
      length += 1;
      continue;
    }
    if (kind !== null) sum += runCost(kind, length);
    kind = next;
    length = 1;
  }
  if (kind !== null) sum += runCost(kind, length);
  return Math.ceil(sum / 100);
}

plugin({
  name: 'writer-pack-fixture-stubs',
  setup(build) {
    build.module('@server/common', () => ({ exports: commonExports, loader: 'object' }));
    build.module('@server/classes', () => ({ exports: { AppErrorCode: classes.AppErrorCode }, loader: 'object' }));
    build.module('js-tiktoken', () => ({ exports: { getEncoding: () => ({ encode: (text: string) => ({ length: estimateTokens(text) }) }) }, loader: 'object' }));
  },
});

const contextDir = join(server, 'modules/ai/context');
const assemblerModule = await import(join(contextDir, 'context-assembler.service.ts'));
const resolverModule = await import(join(contextDir, 'context-ref-resolver.ts'));
const writerBriefModule = await import(join(contextDir, 'writer-brief.ts'));
const writerContext = await import(join(contextDir, 'writer-context.ts'));
const policyModule = await import(join(server, 'modules/bible/fact/writer-disclosure-policy.ts'));
const sqlFilter = await import(join(appRoot, 'tests/sql-filter.ts'));

function createRng(seed: number): () => number {
  let state = seed | 0;
  return () => {
    state = (state + 0x6d2b79f5) | 0;
    let t = Math.imul(state ^ (state >>> 15), 1 | state);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const random = createRng(20261119);
const int = (min: number, max: number): number => min + Math.floor(random() * (max - min + 1));
const chance = (p: number): boolean => random() < p;
const pick = <T>(items: readonly T[]): T => items[Math.floor(random() * items.length)] as T;
const maybe = <T>(p: number, value: () => T): T | null => (chance(p) ? value() : null);
const WORDS = ('the a of and to in he she it was had that with for on as at by from his her they there then when what which who would could '
  + 'lighthouse keeper stairs window grey sea sky morning lantern harbour captain letter promise winter river bridge silence shadow memory garden '
  + 'walked climbed whispered remembered carried opened closed turned waited listened wondered believed forgot answered followed slowly quietly').split(' ');
const ODD = ['Élodie', 'naïve café', '😀', '𠮷野家', 'é', '日本語の文章'];
const words = (count: number): string => Array.from({ length: count }, () => pick(WORDS)).join(' ');
const sentence = (count = int(4, 12)): string => {
  const text = words(count);
  return `${text.charAt(0).toUpperCase()}${text.slice(1)}${pick(['.', '.', '!', '?'])}`;
};
const paragraph = (sentences = int(1, 3)): string => Array.from({ length: sentences }, () => sentence()).join(' ');
const prose = (paragraphs: number): string => Array.from({ length: paragraphs }, () => paragraph()).join('\n\n');
const odd = (text: string): string => (chance(0.3) ? `${text} ${pick(ODD)}` : text);
const filler = (subject: string, count: number): string =>
  Array.from({ length: count }, (_, i) => `Paragraph ${i}. ${`${subject} walks the quay past tar barrels, coiled rope and gull-picked nets. `.repeat(12)}`).join('\n\n');

// What the Swift test builds; field names follow the native records. `state` and `unlock` are JSON text, so their member order survives decoding.
interface Contract { pov: string[]; learns: { entity: string; fact: string }[]; claimedMilestones: string[]; isEnding: boolean }
interface Ending { hookType: string; emotionalBeat: string; openQuestion: string; handoffState: string; mustNotResolve: string[] | null }
interface Spec {
  name: string;
  chapter: number;
  budgetTokens: number;
  permissive: boolean;
  enforce: boolean;
  storable: boolean;
  novel: { writingStyle: string | null; ending: string | null; endingQuestion: string | null } | null;
  volumes: { key: string; ordinal: number; title: string | null; objective: string | null; body: string | null; goalMet: boolean }[];
  milestones: string[];
  secrets: { key: string; text: string; constraintNote: string | null; writerNote: string | null; terms: string[] | null; clues: string[] | null; subjects: string[] | null; revealChapter: number | null; unlock: string | null; source: string }[];
  entities: { key: string; name: string; type: string; status: string | null; body: string | null; notes: string | null; aliases: string[] }[];
  knowledge: { fact: string; entity: string; chapter: number }[];
  threads: { key: string; status: string; openedChapter: number | null; closedChapter: number | null; summary: string | null }[];
  mysteries: { key: string; status: string; openedChapter: number | null; question: string }[];
  pages: { section: string; slug: string; body: string }[];
  ledger: { kind: string; topic: string; statement: string; writerLine: string | null }[];
  plans: { chapter: number; body: string; volume: string | null; pov: string | null; contextRefs: string[]; chapterPurpose: string | null; readerValue: string[] | null; repetitionRisks: string[] | null; guidance: string | null; ending: Ending | null; contract: Contract }[];
  finals: { chapter: number; title: string | null; body: string; summary: string | null; isolated: boolean; volume: string | null }[];
  drafts: { chapter: number; title: string | null; body: string; summary: string | null; isolated: boolean; state: string | null; stale: boolean }[];
  characterStates: { entity: string; location: string | null; conditions: string[] | null; immediateGoal: string | null; statusNote: string | null; lastUpdatedChapter: number }[];
  relationships: { entity: string; target: string; kind: string; note: string | null; chapter: number | null }[];
  worldFacts: { category: string; key: string; value: string }[];
}

const empty = (name: string, chapter: number): Spec => ({
  name, chapter, budgetTokens: 24_000, permissive: false, enforce: false, storable: true, novel: null, volumes: [], milestones: [], secrets: [], entities: [], knowledge: [],
  threads: [], mysteries: [], pages: [], ledger: [], plans: [], finals: [], drafts: [], characterStates: [], relationships: [], worldFacts: [],
});
const contract = (overrides: Partial<Contract> = {}): Contract => ({ pov: [], learns: [], claimedMilestones: [], isEnding: false, ...overrides });
const plan = (chapter: number, overrides: Partial<Spec['plans'][number]> = {}): Spec['plans'][number] => ({
  chapter, body: paragraph(), volume: null, pov: null, contextRefs: [], chapterPurpose: null, readerValue: null, repetitionRisks: null, guidance: null, ending: null,
  contract: contract(), ...overrides,
});
const secret = (key: string, text: string, overrides: Partial<Spec['secrets'][number]> = {}): Spec['secrets'][number] => ({
  key, text, constraintNote: null, writerNote: null, terms: null, clues: null, subjects: null, revealChapter: null, unlock: null, source: 'manual', ...overrides,
});
const entity = (key: string, name: string, overrides: Partial<Spec['entities'][number]> = {}): Spec['entities'][number] => ({
  key, name, type: 'character', status: 'active', body: null, notes: null, aliases: [], ...overrides,
});
const codeUnitOrder = (left: string, right: string): number => (left < right ? -1 : left > right ? 1 : 0);

// The rows of the reference's tables for a spec, ids in insertion order; fact, entity and world-fact rows in key order, as the native reads them.
function tables(spec: Spec): Map<string, Record<string, unknown>[]> {
  const ids = { next: 1n };
  const row = (fields: Record<string, unknown>): Record<string, unknown> => ({ id: ids.next++, projectId: 7n, ...fields });
  const finals = new Set(spec.finals.map((final) => final.chapter));
  const claimed = (milestone: string, final: boolean): number[] =>
    spec.plans.filter((entry) => finals.has(entry.chapter) === final && entry.contract.claimedMilestones.includes(milestone)).map((entry) => entry.chapter);
  const firstOpen = [...spec.volumes].sort((left, right) => left.ordinal - right.ordinal).find((volume) => !volume.goalMet)?.key;
  const entityIds = new Map<string, bigint>();
  const entities = [...spec.entities].sort((left, right) => codeUnitOrder(left.key, right.key)).map((item) => {
    const created = row({ entityKey: item.key, name: item.name, type: item.type, status: item.status, body: item.body, notes: item.notes, aliases: item.aliases.map((alias) => ({ alias })) });
    entityIds.set(item.key, created.id as bigint);
    return created;
  });
  const factIds = new Map<string, bigint>();
  const facts = [...spec.secrets].sort((left, right) => codeUnitOrder(left.key, right.key)).map((item) => row({
      factKey: item.key, text: item.text, constraintNote: item.constraintNote, writerNote: item.writerNote, terms: item.terms ?? [], allowedClues: item.clues, subjects: item.subjects,
      revealChapter: item.revealChapter, unlock: item.unlock === null ? null : JSON.parse(item.unlock), source: item.source, plannedChapter: null, disclosedInChapter: null,
    }));
  for (const fact of facts) factIds.set(fact['factKey'] as string, fact['id'] as bigint);
  return new Map<string, Record<string, unknown>[]>([
    ['projects', spec.novel ? [{ id: 7n, instructions: spec.novel.writingStyle, ending: spec.novel.ending, endingQuestion: spec.novel.endingQuestion, storyCurrentChapter: Math.max(0, ...finals), premise: null, themes: null, contentMode: 'standard' }] : []],
    ['briefs', spec.plans.map((entry) => row({
      chapter: entry.chapter, body: entry.body, volumeKey: entry.volume, pov: entry.pov, contextRefs: entry.contextRefs, chapterPurpose: entry.chapterPurpose, readerValue: entry.readerValue,
      repetitionRisks: entry.repetitionRisks, guidance: entry.guidance, isEnding: entry.contract.isEnding, claimedMilestones: entry.contract.claimedMilestones, staleReason: null,
      knowledgeContract: { pov: entry.contract.pov, learns: entry.contract.learns.map((learn) => ({ entityKey: learn.entity, factKey: learn.fact })) },
      endingContract: entry.ending ? { hookType: entry.ending.hookType, emotionalBeat: entry.ending.emotionalBeat, openQuestion: entry.ending.openQuestion, handoffState: entry.ending.handoffState, ...(entry.ending.mustNotResolve ? { mustNotResolve: entry.ending.mustNotResolve } : {}) } : null,
    }))],
    ['milestones', spec.milestones.map((key) => {
      const reached = claimed(key, true);
      const state = reached.length > 0 ? 'reached' : claimed(key, false).length > 0 ? 'planned' : 'open';
      return row({ milestoneKey: key, state, reachedChapter: reached.length > 0 ? Math.min(...reached) : null });
    })],
    ['volumes', [...spec.volumes].sort((left, right) => left.ordinal - right.ordinal).map((volume) => row({
      volumeKey: volume.key, ordinal: volume.ordinal, title: volume.title, objective: volume.objective, body: volume.body,
      state: volume.goalMet ? 'goal_met' : volume.key === firstOpen ? 'active' : 'not_started',
    }))],
    ['canonFacts', facts],
    ['characterKnowledge', spec.knowledge.map((item) => row({ factId: factIds.get(item.fact), entityId: entityIds.get(item.entity), learnedInChapter: item.chapter, source: 'manual', note: null, status: 'committed', draftRevision: null }))],
    ['chapters', [...spec.finals].sort((left, right) => left.chapter - right.chapter).map((final) => row({
      number: final.chapter, status: 'done', isolated: final.isolated, title: final.title, content: final.body, summary: final.summary, volumeKey: final.volume,
    }))],
    ['drafts', [...spec.drafts].sort((left, right) => left.chapter - right.chapter).map((draft) => row({
      chapter: draft.chapter, title: draft.title, body: draft.body, summary: draft.summary, isolated: draft.isolated, state: draft.state === null ? null : JSON.parse(draft.state),
      staleReason: draft.stale ? 'the draft does not record what it was written against' : null, status: finals.has(draft.chapter) ? 'final' : 'draft', revision: 1,
    }))],
    ['entities', entities],
    ['characterStates', spec.characterStates.map((state) => row({ entityKey: state.entity, location: state.location, conditions: state.conditions, immediateGoal: state.immediateGoal, statusNote: state.statusNote, lastUpdatedChapter: state.lastUpdatedChapter }))],
    ['entityRelationships', spec.relationships.map((relationship) => row({ entityId: entityIds.get(relationship.entity) ?? -1n, targetKey: relationship.target, kind: relationship.kind, note: relationship.note, chapter: relationship.chapter }))],
    ['worldFacts', [...spec.worldFacts].sort((left, right) => codeUnitOrder(left.category, right.category) || codeUnitOrder(left.key, right.key)).map((fact) => row({ ...fact }))],
    ['plotThreads', spec.threads.map((thread) => row({ threadKey: thread.key, status: thread.status, openedChapter: thread.openedChapter, closedChapter: thread.closedChapter, summary: thread.summary }))],
    ['mysteries', spec.mysteries.map((mystery) => row({ mysteryKey: mystery.key, status: mystery.status, openedChapter: mystery.openedChapter, question: mystery.question }))],
    ['bibleDocuments', spec.pages.map((page) => row({ ...page, frontmatter: null }))],
    ['decisionLedgerEntries', spec.ledger.map((entry) => row({ ...entry, why: null, rejectedAlternatives: [], decidedBy: 'author', supersededAt: null, links: {} }))],
  ]);
}

// sql-filter sorts numeric columns only; a string column keeps the rows' (already sorted) order, and the one upper-case DESC the assembler writes is read here.
function ordered(rows: Record<string, unknown>[], query: any): Record<string, unknown>[] {
  try {
    return sqlFilter.queryRows(rows, { where: query?.where, orderBy: query?.orderBy });
  } catch (error) {
    const match = /"(\w+)" DESC"$/.exec(String((error as Error).message));
    if (!match) throw error;
    const key = (match[1] as string).replace(/_(\w)/g, (_: string, letter: string) => letter.toUpperCase());
    return sqlFilter.queryRows(rows, { where: query?.where }).sort((left: any, right: any) => Number(right[key]) - Number(left[key]));
  }
}

function makeDb(rows: Map<string, Record<string, unknown>[]>): any {
  const finder = (name: string) => ({
    findFirst: async (query?: any) => ordered(rows.get(name) ?? [], query)[0],
    findMany: async (query?: any) => {
      const found = ordered(rows.get(name) ?? [], query);
      return query?.limit === undefined ? found : found.slice(0, query.limit);
    },
  });
  return {
    query: new Proxy({}, { get: (_, name: string) => finder(name) }),
    select: () => ({ from: () => ({ innerJoin: () => ({ where: async () => [] }) }) }),
    $count: async () => 0,
  };
}

function assemblerOf(db: any): any {
  const instance = Object.create(assemblerModule.ContextAssembler.prototype);
  instance.db = db;
  instance.refResolver = new resolverModule.ContextRefResolver(db);
  instance.logger = { warn: () => undefined, info: () => undefined };
  return instance;
}

const section = (value: any): any => ({
  key: value.key, tier: value.tier, segment: value.segment, tokens: value.tokens, truncated: value.truncated, sourceRefs: value.sourceRefs, rendered: value.rendered,
  required: Boolean(value.required), priority: value.priority ?? null,
});

// The joined texts repeat every section, so the fixture holds their SHA-256 (of the UTF-8 bytes) and the sections themselves.
const digest = (text: string): string => createHash('sha256').update(text, 'utf8').digest('hex');

const errorOf = (error: any): any => {
  if (!error?.code) throw error;
  return { code: error.code, message: error.message };
};

async function expected(spec: Spec): Promise<any> {
  const rows = tables(spec);
  const db = makeDb(rows);
  const policy = spec.permissive ? { writerClass: 'permissive', contextSections: [] } : undefined;
  const disclosure = await policyModule.loadWriterDisclosurePolicy(db, 7n, spec.chapter);
  const brief = rows.get('briefs')?.find((row) => row['chapter'] === spec.chapter);
  const writerBrief = await writerBriefModule.loadWriterBrief(db, 7n, spec.chapter, brief, disclosure);
  try {
    const pack = await assemblerOf(db).forChapter(7n, spec.chapter, { dryRun: true, budgetTokens: spec.budgetTokens, policy, enforceWriterReservations: spec.enforce });
    return {
      budgetTokens: pack.budgetTokens, usedTokens: pack.usedTokens, sections: pack.sections.map(section), unresolvedRefs: pack.unresolvedRefs, withheldRefs: pack.withheldRefs,
      omitted: pack.omitted.map((omission: any) => ({ key: omission.key, reason: omission.reason, tokens: omission.tokens ?? null })), renderedStable: digest(pack.renderedStable),
      renderedVolatile: digest(pack.renderedVolatile), rendered: digest(pack.rendered), chapterBrief: writerBrief.chapterBrief, endingContract: writerBrief.endingContract, error: null,
    };
  } catch (error) {
    return { error: errorOf(error), chapterBrief: writerBrief.chapterBrief, endingContract: writerBrief.endingContract };
  }
}

const specs: Spec[] = [];

// tests/ai/chapter-pack.spec.ts:15-104 (chapterOneDb), over a database that honours every query
const POV_TAIL = 'POV_CARD_LAST_PARAGRAPH';
const DESCRIPTION_TAIL = 'SIDE_CARD_LAST_DESCRIPTION';
const CAUTION = 'SIDE_CARD_CAUTION_MARKER';
const PROHIBITION = 'SIDE_CARD_PROHIBITION_MARKER';
const BASE_REFS = ['entity:wren', 'entity:tobin', 'entity:harbor_guild', 'volume:volume_tides', 'volume:volume_missing', 'arc:arc_opening', 'world_fact:harbor_customs',
  'world_fact:fog_season', 'world_fact:weather/fog_season', 'world_fact:harbor_customs/missing', 'bible_doc:world/harbor'];
const DECISIONS = [
  { kind: 'decision', topic: 'protagonist', statement: 'Wren trusts ledgers over people.', writerLine: 'WRITER_LINE_MARKER Wren checks the numbers before she answers anyone.' },
  { kind: 'direction', topic: 'taste', statement: 'DIRECTION_MARKER keep it quiet', writerLine: null },
  { kind: 'system', topic: 'cast', statement: 'Tobin is thirty.', writerLine: 'Tobin jokes when the crew is scared.' },
];
function chapterOne(name: string, options: { contextRefs?: string[]; instructions?: string; extras?: number; ledger?: Spec['ledger']; budgetTokens?: number } = {}): Spec {
  const extras = Array.from({ length: options.extras ?? 0 }, (_, i) => entity(`crew_${i}`, `Crew ${i}`, { body: filler(`Crew ${i}`, 3) }));
  return {
    ...empty(name, 1),
    storable: false,
    budgetTokens: options.budgetTokens ?? 24_000,
    novel: { writingStyle: options.instructions ?? 'WRITING_STYLE_MARKER Write close third person.', ending: null, endingQuestion: null },
    plans: [plan(1, { body: 'Wren counts crates.', contextRefs: [...(options.contextRefs ?? BASE_REFS), ...extras.map((extra) => `entity:${extra.key}`)], pov: 'wren', volume: 'volume_tides', contract: contract({ pov: ['wren'] }) })],
    volumes: [{ key: 'volume_tides', ordinal: 2, title: 'The Turning Tide', objective: 'VOLUME_REF_OBJECTIVE', body: null, goalMet: false }],
    entities: [
      entity('wren', 'Wren Aldous', { body: `${filler('Wren', 5)}\n\n${POV_TAIL}`, aliases: ['the tallyman'] }),
      entity('tobin', 'Tobin Reyes', { body: `${filler('Tobin', 5)}\n\n${DESCRIPTION_TAIL}\n\n## Drafter guidance\n\nKeep his humour dry and brief. ${CAUTION}\n\n**Never:** he never raises his voice at a crew member. ${PROHIBITION}` }),
      entity('harbor_guild', 'Harbor Guild', { type: 'faction', body: 'Keeps the tide tables.' }),
      ...extras,
    ],
    worldFacts: [
      { category: 'harbor_customs', key: 'bell_curfew', value: 'No boat leaves after the third bell.' },
      { category: 'harbor_customs', key: 'tithe_scale', value: 'Every tenth crate goes to the guild.' },
      { category: 'weather', key: 'fog_season', value: 'Fog holds the bay for a month each autumn.' },
    ],
    pages: [
      { section: 'world', slug: 'harbor', body: 'BIBLE_HARBOR_MARKER The harbor is tidal and shallow.' },
      { section: 'world', slug: 'ledger', body: filler('The ledger', 15) },
    ],
    ledger: options.ledger ?? [],
  };
}
specs.push(chapterOne('chapter pack'));
specs.push(chapterOne('chapter pack over budget', { contextRefs: [...BASE_REFS, 'bible_doc:world/ledger'], budgetTokens: 3_000 }));
specs.push(chapterOne('chapter pack oversized style', { instructions: `WRITING_STYLE_MARKER\n\n${filler('The narrator', 20)}` }));
specs.push(chapterOne('chapter pack crowded cast', { contextRefs: [...BASE_REFS, 'bible_doc:world/ledger', 'nocolon', 'unknown:thing'], extras: 3, budgetTokens: 4_500 }));
specs.push(chapterOne('chapter pack decisions', { ledger: DECISIONS }));
specs.push(chapterOne('chapter pack decisions over budget', { contextRefs: [...BASE_REFS, 'bible_doc:world/ledger'], ledger: DECISIONS, budgetTokens: 3_000 }));

// tests/ai/writer-disclosure-fixtures.ts:12-226 (writerTables) without the plugin section; `vault` leaves out what the vault cannot hold yet
const TRUTH = 'The keeper trades one memory for every hour the lamp burns.';
const TERM = 'memory tithe';
const KEY = 'lamp_memory_price';
const CLUE = 'The keeper forgets small names after a long night.';
const ENDING = 'The keeper lets the lamp go dark and the harbour floods.';
const ENDING_QUESTION = 'Will the keeper keep the harbour lit through winter?';
const V2_GOAL = 'The apprentice learns to light the lamp alone.';
const V3_GOAL = 'The drowned town rises to claim its keeper at last.';
const TIMELINE_LINE = 'The apprentice discovers the ledger of lost names in the cellar.';
const OPEN_QUESTION = 'Does the apprentice ever learn who built the lamp?';
const PAYLOAD = [TRUTH, `Villagers whisper of the ${TERM}.`, `See ${KEY}.`, ENDING, ENDING_QUESTION, V2_GOAL, V3_GOAL, TIMELINE_LINE, OPEN_QUESTION, CLUE].join(' ');
function disclosureScenario(scenario: 'locked' | 'unlocked', vault: boolean): Spec {
  const unlocked = scenario === 'unlocked';
  const done = (chapter: number, extra: Partial<Spec['finals'][number]> = {}): Spec['finals'][number] => ({ chapter, title: null, body: 'A quiet day.', summary: 'A quiet day.', isolated: false, volume: null, ...extra });
  return {
    ...empty(`writer disclosure ${scenario}${vault ? ' vault' : ''}`, 5),
    storable: vault,
    novel: { writingStyle: `Write close third. ${PAYLOAD}`, ending: ENDING, endingQuestion: ENDING_QUESTION },
    plans: [plan(5, {
      body: `Open on the pier. ${PAYLOAD}`, volume: unlocked ? 'v2' : 'v1', pov: 'keeper',
      contextRefs: ['entity:apprentice', 'entity:ghost', ...(vault ? [] : ['world_fact:lamps']), 'thread:harbour_debt', 'thread:winter_debt', 'mystery:lamp_builder', 'chapter:4', 'chapter:7', 'volume:v1', 'volume:v2', 'volume:v3', 'fact:harbour_rule',
        'bible_doc:lore/harbour-notes', 'bible_doc:project/timeline', 'bible_doc:project/open-questions', 'bible_doc:story_state/volume-plan'],
      ending: { hookType: 'turn', emotionalBeat: `Dread of the ${TERM}`, openQuestion: '', handoffState: TRUTH, mustNotResolve: null },
      contract: contract({ pov: ['keeper'], learns: [{ entity: 'keeper', fact: KEY }, { entity: 'keeper', fact: 'pier_door' }], claimedMilestones: unlocked ? ['lamp_rank'] : [], isEnding: unlocked }),
    })],
    milestones: ['lamp_rank'],
    volumes: [
      { key: 'v1', ordinal: 1, title: 'Spring', objective: `Keep the lamp lit. ${PAYLOAD}`, body: null, goalMet: false },
      { key: 'v2', ordinal: 2, title: 'Summer', objective: V2_GOAL, body: null, goalMet: false },
      { key: 'v3', ordinal: 3, title: 'Winter', objective: V3_GOAL, body: null, goalMet: false },
    ],
    secrets: [
      secret(KEY, TRUTH, { writerNote: `Keep the lamp's price off the page. ${V3_GOAL}`, terms: [TERM], revealChapter: 5, unlock: JSON.stringify({ all: [{ milestone: 'lamp_rank' }] }), clues: [CLUE] }),
      secret('harbour_rule', `Harbour law holds. ${PAYLOAD}`, { revealChapter: 1 }),
      secret('pier_door', `The pier hides a door. ${PAYLOAD}`, { revealChapter: 5 }),
    ],
    finals: [done(1), done(2), done(3), done(4, { title: `The ${TERM}`, body: `Earlier prose. ${PAYLOAD}`, summary: PAYLOAD })],
    drafts: [{ chapter: 4, title: null, body: 'Draft body.', summary: PAYLOAD, isolated: false, stale: false,
      state: vault ? JSON.stringify({ establishedFacts: [`The ${TERM} is paid.`, 'The pier is rotten.'], [`${TERM} status`]: PAYLOAD }) : JSON.stringify({ [`${TERM} status`]: PAYLOAD, establishedFacts: [`The ${TERM} is paid.`, 'The pier is rotten.'] }) }],
    entities: [
      entity('apprentice', 'Tam', { body: PAYLOAD, aliases: vault ? [] : [`Heir of the ${TERM}`] }),
      entity('keeper', 'Oren', { body: PAYLOAD }),
    ],
    characterStates: vault ? [] : [{ entity: 'keeper', location: 'Pier', conditions: [], immediateGoal: null, statusNote: PAYLOAD, lastUpdatedChapter: 4 }],
    relationships: vault ? [] : [{ entity: 'keeper', target: 'apprentice', kind: 'mentor', note: PAYLOAD, chapter: 4 }],
    worldFacts: vault ? [] : [{ category: 'lamps', key: 'fuel', value: PAYLOAD }],
    threads: [
      { key: 'harbour_debt', status: 'open', openedChapter: 1, closedChapter: null, summary: PAYLOAD },
      { key: 'winter_debt', status: 'open', openedChapter: 7, closedChapter: null, summary: 'Planned for winter.' },
    ],
    mysteries: [{ key: 'lamp_builder', status: 'open', openedChapter: 1, question: PAYLOAD }],
    pages: [
      { section: 'lore', slug: 'harbour-notes', body: `Copied from the timeline and the secrets page:\n\n${PAYLOAD}` },
      { section: 'project', slug: 'timeline', body: `## Later\n- ${TIMELINE_LINE}` },
      { section: 'project', slug: 'open-questions', body: `- ${OPEN_QUESTION}` },
      { section: 'story_state', slug: 'volume-plan', body: `Volume three: ${V3_GOAL}` },
    ],
    ledger: [{ kind: 'decision', topic: 'voice', statement: 'Quiet dread.', writerLine: PAYLOAD }],
  };
}
for (const scenario of ['locked', 'unlocked'] as const) {
  specs.push(disclosureScenario(scenario, false));
  specs.push(disclosureScenario(scenario, true));
}
specs.push({ ...disclosureScenario('locked', true), name: 'writer disclosure locked permissive', permissive: true });

// Isolated chapters on a standard route and on the permissive one: prose, summary and state reach only the permissive writer.
function isolatedScenario(name: string, permissive: boolean): Spec {
  const hidden = 'ISOLATED_PROSE_MARKER the lantern room at midnight.';
  return {
    ...empty(name, 5),
    permissive,
    novel: { writingStyle: null, ending: null, endingQuestion: null },
    volumes: [{ key: 'v1', ordinal: 1, title: 'First', objective: 'Reach the light.', body: null, goalMet: true }, { key: 'v2', ordinal: 2, title: 'Second', objective: 'Hold the light.', body: null, goalMet: false }],
    plans: [1, 2, 3, 4].map((chapter) => plan(chapter, { volume: chapter <= 2 ? 'v1' : 'v2' })).concat([plan(5, { volume: 'v2', contextRefs: ['chapter:2', 'chapter:3', 'chapter:4'] })]),
    finals: [1, 2, 3].map((chapter) => ({ chapter, title: `Title ${chapter} ${chapter === 2 ? hidden : ''}`.trim(), body: chapter === 2 ? `${prose(2)}\n\n${hidden}` : prose(2), summary: chapter === 2 ? `Summary ${hidden}` : sentence(), isolated: chapter === 2, volume: chapter <= 2 ? 'v1' : 'v2' })),
    drafts: [
      { chapter: 3, title: null, body: prose(1), summary: sentence(), isolated: false, state: null, stale: false },
      { chapter: 4, title: null, body: `${prose(2)}\n\n${hidden}`, summary: `Draft summary ${hidden}`, isolated: true, state: JSON.stringify({ location: hidden, mood: 'quiet' }), stale: false },
    ],
  };
}
specs.push(isolatedScenario('isolated chapters standard', false));
specs.push(isolatedScenario('isolated chapters permissive', true));
specs.push({ ...isolatedScenario('isolated final ending standard', false), chapter: 4, drafts: [] });

// Dynamic cast state and relationships, sorted by localeCompare over keys and lines whose code-unit order differs.
const CAST_KEYS = ['Alpha', 'beta', '_x', 'a10', 'a9', 'Émile'];
specs.push({
  ...empty('cast state order', 3),
  storable: false,
  plans: [plan(3, { pov: 'beta', contextRefs: CAST_KEYS.map((key) => `entity:${key}`), contract: contract({ pov: ['beta', 'a9'] }) })],
  entities: CAST_KEYS.map((key, i) => entity(key, `${key} ${words(1)}`, { body: sentence(), type: i % 3 === 2 ? 'location' : 'character' })),
  characterStates: CAST_KEYS.map((key, i) => ({ entity: key, location: maybe(0.8, () => words(2)), conditions: i % 2 === 0 ? [words(1)] : [], immediateGoal: maybe(0.5, () => sentence()), statusNote: null, lastUpdatedChapter: 2 })),
  relationships: [
    ...CAST_KEYS.map((key, i) => ({ entity: key, target: CAST_KEYS[(i + 1) % CAST_KEYS.length] as string, kind: pick(['ally', 'Rival', '_debt']), note: maybe(0.5, () => words(2)), chapter: pick([null, 1, 2]) })),
    { entity: 'beta', target: 'Alpha', kind: 'ally', note: 'later', chapter: 2 },
    { entity: 'beta', target: 'Alpha', kind: 'ally', note: 'same chapter, later row', chapter: 2 },
    { entity: 'ghost', target: 'beta', kind: 'ally', note: null, chapter: 1 },
  ],
});

// A fact open to the whole book that the chapter's ending contract forbids resolving: locked, so open canon leaves it out.
specs.push({
  ...empty('open canon withholds a forbidden fact', 3),
  novel: { writingStyle: null, ending: null, endingQuestion: null },
  secrets: [
    secret('harbour_law', 'FORBIDDEN_FACT_MARKER the harbour law binds the keeper.', { revealChapter: 1, terms: ['harbour law'] }),
    secret('tide_rule', 'The tide turns twice a day.', { revealChapter: 1 }),
  ],
  plans: [plan(1), plan(2), plan(3, {
    body: 'The keeper reads the tide tables. FORBIDDEN_FACT_MARKER the harbour law binds the keeper.',
    ending: { hookType: 'turn', emotionalBeat: 'unease', openQuestion: 'Who wrote the law?', handoffState: 'The keeper hesitates.', mustNotResolve: ['harbour_law'] },
  })],
  finals: [1, 2].map((chapter) => ({ chapter, title: null, body: prose(1), summary: sentence(), isolated: false, volume: null })),
});

// Required material over its limits: CTX_002 for a cap, for the plan, and for the budget.
specs.push({ ...chapterOne('oversized plan enforced'), storable: true, entities: [entity('wren', 'Wren Aldous', { body: filler('Wren', 5) })], worldFacts: [], plans: [plan(1, { body: filler('The plan', 30), pov: 'wren', contract: contract({ pov: ['wren'] }) })], enforce: true });
specs.push({ ...chapterOne('budget enforced'), storable: true, entities: [entity('wren', 'Wren Aldous', { body: filler('Wren', 5) })], worldFacts: [], plans: [plan(1, { body: filler('The plan', 6), pov: 'wren', contract: contract({ pov: ['wren'] }) })], enforce: true, budgetTokens: 2_000 });
specs.push({ ...chapterOne('style crowds the budget enforced', { instructions: filler('The narrator', 18) }), storable: true, entities: [], worldFacts: [], pages: [], plans: [plan(1, { body: 'Short.' })], enforce: true, budgetTokens: 3_500 });

// Seeded worlds the vault can hold.
const SECTIONS = ['lore', 'world', 'plot', 'project', 'story_state'] as const;
function seededWorld(index: number): Spec {
  const chapter = int(1, 7);
  const spec = empty(`seeded ${index}`, chapter);
  spec.budgetTokens = pick([24_000, 24_000, 6_000, 3_000, 1_500]);
  spec.permissive = chance(0.25);
  spec.enforce = chance(0.2);
  const later = chapter + int(0, 2);
  spec.volumes = Array.from({ length: int(0, 3) }, (_, i) => ({ key: `v${i + 1}`, ordinal: i + 1, title: maybe(0.8, () => odd(words(2))), objective: maybe(0.8, () => odd(sentence())), body: maybe(0.3, () => sentence()), goalMet: chance(0.4) }));
  const volumeKeys = spec.volumes.map((volume) => volume.key);
  spec.milestones = Array.from({ length: int(0, 2) }, (_, i) => `m${i + 1}`);
  spec.entities = Array.from({ length: int(0, 6) }, (_, i) => entity(`e${i}`, odd(words(2)), {
    type: pick(['character', 'character', 'location', 'item', 'power_rule']), status: pick([null, 'active', 'planned', 'missing']), body: maybe(0.7, () => (chance(0.2) ? filler(`E${i}`, int(2, 8)) : prose(int(1, 3)))), notes: maybe(0.3, () => sentence()),
  }));
  const entityKeys = spec.entities.map((item) => item.key);
  spec.secrets = Array.from({ length: int(0, 5) }, (_, i) => {
    const text = odd(sentence(int(6, 10)));
    return secret(`s${i}_${pick(['a', 'B', 'z', '_q'])}`, text, {
      writerNote: maybe(0.6, () => sentence()), constraintNote: maybe(0.3, () => sentence()), terms: maybe(0.5, () => [words(2)]), clues: maybe(0.4, () => [sentence()]),
      subjects: maybe(0.5, () => (entityKeys.length > 0 ? [pick(entityKeys)] : [])), revealChapter: pick([null, null, 1, chapter, chapter + 1, chapter + 3]),
      unlock: spec.milestones.length > 0 && chance(0.3) ? JSON.stringify({ all: [{ milestone: pick(spec.milestones) }] }) : null, source: pick(['manual', 'manual', 'seed', 'brief']),
    });
  });
  const secretKeys = spec.secrets.map((item) => item.key);
  if (entityKeys.length > 0 && secretKeys.length > 0 && chapter > 1) {
    const pairs = new Set<string>();
    for (let n = int(0, 3); n > 0; n--) {
      const pair = { fact: pick(secretKeys), entity: pick(entityKeys), chapter: int(1, chapter - 1) };
      if (pairs.has(`${pair.fact}/${pair.entity}`)) continue;
      pairs.add(`${pair.fact}/${pair.entity}`);
      spec.knowledge.push(pair);
    }
  }
  spec.threads = Array.from({ length: int(0, 3) }, (_, i) => {
    const status = pick(['open', 'closed', 'dropped']);
    return { key: `t${i}`, status, openedChapter: pick([null, 1, chapter, chapter + 2]), closedChapter: status === 'closed' ? pick([null, chapter]) : null, summary: maybe(0.8, () => odd(sentence())) };
  });
  spec.mysteries = Array.from({ length: int(0, 2) }, (_, i) => ({ key: `q${i}`, status: pick(['open', 'resolved']), openedChapter: pick([null, 1, chapter + 1]), question: odd(sentence()) }));
  spec.pages = Array.from({ length: int(0, 4) }, (_, i) => {
    const section = pick(SECTIONS);
    const slug = section === 'project' ? pick(['timeline', 'open-questions', 'premise']) : section === 'story_state' ? pick(['volume-plan', 'current']) : `page-${i}`;
    const copy = chance(0.4) && spec.secrets.length > 0 ? ` ${pick(spec.secrets).text}` : '';
    return { section, slug, body: chance(0.1) ? '' : `${prose(int(1, 3))}${copy}` };
  }).filter((page, i, all) => all.findIndex((other) => other.section === page.section && other.slug === page.slug) === i);
  spec.ledger = Array.from({ length: int(0, 4) }, (_, i) => ({ kind: pick(['decision', 'system', 'direction']), topic: `topic.${i}`, statement: sentence(), writerLine: maybe(0.7, () => odd(sentence())) }));
  spec.novel = chance(0.9) ? { writingStyle: maybe(0.6, () => odd(paragraph())), ending: maybe(0.6, () => sentence()), endingQuestion: maybe(0.5, () => sentence()) } : null;

  const refPool = [...entityKeys.map((key) => `entity:${key}`), ...spec.threads.map((t) => `thread:${t.key}`), ...spec.mysteries.map((m) => `mystery:${m.key}`),
    ...volumeKeys.map((key) => `volume:${key}`), ...secretKeys.map((key) => `fact:${key}`), ...spec.pages.map((page) => `bible_doc:${page.section}/${page.slug}`),
    `chapter:${Math.max(1, chapter - 1)}`, 'chapter:1', 'entity:ghost', 'nocolon', 'world_fact:x'];
  const finalCount = Math.max(0, chapter - 1 - int(0, 2));
  for (let n = 1; n <= later; n++) {
    const current = n === chapter;
    const volume = volumeKeys.length > 0 && chance(0.8) ? volumeKeys[Math.min(volumeKeys.length - 1, Math.floor((n - 1) / 2))] as string : null;
    const pov = entityKeys.length > 0 && chance(0.7) ? pick(entityKeys) : null;
    const povCast = pov && chance(0.6) ? [pov, ...(entityKeys.length > 1 && chance(0.4) ? [pick(entityKeys)] : [])] : [];
    if (!current && n > finalCount && n < chapter && chance(0.15)) continue;
    spec.plans.push(plan(n, {
      body: odd(paragraph()), volume, pov, chapterPurpose: maybe(0.5, () => sentence()), readerValue: maybe(0.3, () => [words(2)]), repetitionRisks: maybe(0.2, () => [words(3)]), guidance: maybe(0.3, () => sentence()),
      contextRefs: current ? Array.from({ length: int(0, 8) }, () => pick(refPool)) : [],
      ending: maybe(0.6, () => ({ hookType: pick(['cliffhanger', 'turn', 'quiet_dread']), emotionalBeat: words(2), openQuestion: sentence(), handoffState: sentence(), mustNotResolve: current && secretKeys.length > 0 && chance(0.4) ? [pick(secretKeys)] : null })),
      contract: contract({
        pov: povCast, learns: current && povCast.length > 0 && secretKeys.length > 0 && chance(0.6) ? [{ entity: povCast[0] as string, fact: pick(secretKeys) }] : [],
        claimedMilestones: spec.milestones.length > 0 && chance(0.3) ? [pick(spec.milestones)] : [], isEnding: n === later && chance(0.2),
      }),
    }));
  }
  for (let n = 1; n <= finalCount; n++) {
    const isolated = chance(0.2);
    const copy = chance(0.4) && spec.secrets.length > 0 ? ` ${pick(spec.secrets).text}` : '';
    const planned = spec.plans.find((entry) => entry.chapter === n);
    spec.finals.push({ chapter: n, title: maybe(0.8, () => odd(words(2))), body: `${prose(int(1, 4))}${copy}`, summary: chance(0.15) ? (chance(0.5) ? '' : null) : `${odd(sentence())}${copy}`, isolated, volume: planned ? planned.volume : maybe(0.5, () => (volumeKeys.length > 0 ? pick(volumeKeys) : null)) });
  }
  for (let n = Math.max(1, chapter - 3); n < chapter; n++) {
    const final = n <= finalCount;
    if (!chance(final ? 0.3 : 0.8)) continue;
    const copy = chance(0.4) && spec.secrets.length > 0 ? ` ${pick(spec.secrets).text}` : '';
    const state = maybe(0.5, () => JSON.stringify({ establishedFacts: [sentence(), ...(spec.secrets.length > 0 ? [`${pick(spec.secrets).text}`] : [])], location: odd(words(2)), mood: words(1) }));
    spec.drafts.push({ chapter: n, title: maybe(0.5, () => words(2)), body: `${prose(int(1, 3))}${copy}`, summary: maybe(0.8, () => `${sentence()}${copy}`), isolated: chance(0.2), state, stale: !final && chance(0.3) });
  }
  const outside = [chapter - 4, chapter + 1].filter((n) => n >= 1 && !spec.drafts.some((draft) => draft.chapter === n) && chance(0.5));
  for (const n of outside) {
    spec.drafts.push({ chapter: n, title: null, body: `OUTSIDE_WINDOW_MARKER ${prose(1)}`, summary: `OUTSIDE_WINDOW_MARKER ${sentence()}`, isolated: false, state: null, stale: n > finalCount && chance(0.3) });
  }
  return spec;
}
for (let index = 0; index < 28; index++) specs.push(seededWorld(index));

const scenarios = [];
for (const spec of specs) scenarios.push({ spec, expected: await expected(spec) });

// writer-context.ts:57 over random reservations
const fits = Array.from({ length: 24 }, () => {
  const reservations = Array.from({ length: int(1, 6) }, (_, i) => {
    const cap = pick([800, 1_000, 3_000, 6_000]);
    return { name: `section ${i}`, tokens: chance(0.15) ? cap + int(1, 500) : int(0, cap), cap, fromPlan: chance(0.4) };
  });
  const budgetTokens = pick([1_000, 2_500, 6_000, 24_000, 1_234_567]);
  try {
    writerContext.assertWriterContextFits(reservations, budgetTokens);
    return { reservations, budgetTokens, error: null };
  } catch (error) {
    return { reservations, budgetTokens, error: errorOf(error) };
  }
});

for (const reservations of [
  [{ name: 'the chapter plan', tokens: 500, cap: 6_000, fromPlan: true }, { name: 'the style guide', tokens: 500, cap: 4_100, fromPlan: false }],
  [{ name: 'the chapter plan', tokens: 501, cap: 6_000, fromPlan: true }, { name: 'the style guide', tokens: 500, cap: 4_100, fromPlan: false }],
]) {
  try {
    writerContext.assertWriterContextFits(reservations, 900);
    fits.push({ reservations, budgetTokens: 900, error: null });
  } catch (error) {
    fits.push({ reservations, budgetTokens: 900, error: errorOf(error) });
  }
}

const sanitize = (value: unknown): unknown => JSON.parse(JSON.stringify(value, (_, item) => (typeof item === 'bigint' ? Number(item) : item)));
writeFileSync(join(outDir, 'writer-pack.json'), `${JSON.stringify(sanitize({ scenarios, fits, defaultBudget: assemblerModule.DEFAULT_BUDGET }))}\n`);
