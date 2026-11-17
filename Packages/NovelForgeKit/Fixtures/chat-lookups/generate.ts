import { plugin } from 'bun';
import { readdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// Run as: PLATFORM_REPO=<checkout> bun --tsconfig-override "$PLATFORM_REPO/apps/novel-forge-server/tsconfig.json" generate.ts (the reference schemas use legacy decorators)
const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');

const server = join(platformRepo, 'apps/novel-forge-server/src');
const outDir = dirname(fileURLToPath(import.meta.url));
const classes = await import(join(server, 'classes/app-error-code.ts'));
const realDrizzle = await import(join(platformRepo, 'apps/novel-forge-server/node_modules/drizzle-orm/index.js'));
const zod = await import(join(platformRepo, 'apps/novel-forge-server/node_modules/zod/index.js'));
const pgCore = await import(join(platformRepo, 'apps/novel-forge-server/node_modules/drizzle-orm/pg-core/index.js'));

const commonExports: Record<string, any> = {};
for (const file of readdirSync(join(server, 'common')).filter((name) => name.endsWith('.ts') && !name.endsWith('.spec.ts') && name !== 'index.ts').sort()) {
  try {
    Object.assign(commonExports, await import(join(server, 'common', file)));
  } catch {
    continue;
  }
}

const HUNDREDTHS_PER_TOKEN = 100;

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
  return Math.ceil(sum / HUNDREDTHS_PER_TOKEN);
}

interface Column {
  key: string;
}

const columnKeys = new Map<object, string>();
const tableNames = new Map<object, string>();
const store: Record<string, any[]> = {};
const predicate = (test: (row: any) => boolean): { test: (row: any) => boolean } => ({ test });
const keyOf = (column: object): string => {
  const key = columnKeys.get(column);
  if (key === undefined) throw new Error('an unmapped column');
  return key;
};
const ops = {
  and: (...parts: any[]) => predicate((row) => parts.filter(Boolean).every((part) => part.test(row))),
  eq: (column: object, value: unknown) => predicate((row) => row[keyOf(column)] === value),
  ne: (column: object, value: unknown) => predicate((row) => row[keyOf(column)] !== value),
  inArray: (column: object, values: unknown[]) => predicate((row) => values.includes(row[keyOf(column)])),
  isNull: (column: object) => predicate((row) => row[keyOf(column)] === null || row[keyOf(column)] === undefined),
  between: (column: object, low: number, high: number) => predicate((row) => row[keyOf(column)] >= low && row[keyOf(column)] <= high),
  gte: (column: object, value: number) => predicate((row) => row[keyOf(column)] >= value),
  asc: (column: object) => ({ key: keyOf(column), direction: 1 }),
  desc: (column: object) => ({ key: keyOf(column), direction: -1 }),
};

plugin({
  name: 'chat-lookups-fixture-stubs',
  setup(build) {
    build.module('@server/common', () => ({ exports: commonExports, loader: 'object' }));
    build.module('@server/classes', () => ({ exports: { AppErrorCode: classes.AppErrorCode }, loader: 'object' }));
    build.module('js-tiktoken', () => ({ exports: { getEncoding: () => ({ encode: (text: string) => ({ length: estimateTokens(text) }) }) }, loader: 'object' }));
    build.module('drizzle-orm', () => ({
      exports: { ...realDrizzle, and: ops.and, eq: ops.eq, between: ops.between, gte: ops.gte, inArray: ops.inArray },
      loader: 'object',
    }));
  },
});

const schemas = await import(join(server, 'database/schemas/index.ts'));
for (const [name, table] of Object.entries(schemas)) {
  if (!realDrizzle.is(table, pgCore.PgTable)) continue;
  tableNames.set(table as object, name);
  store[name] = [];
  for (const [key, column] of Object.entries(realDrizzle.getTableColumns(table as any))) columnKeys.set(column as object, key);
}

const ordered = (rows: any[], orderBy: any): any[] => {
  const specs = orderBy === undefined ? [] : Array.isArray(orderBy) ? orderBy : [orderBy];
  return [...rows].sort((left, right) => {
    for (const spec of specs) {
      if (left[spec.key] < right[spec.key]) return -spec.direction;
      if (left[spec.key] > right[spec.key]) return spec.direction;
    }
    return 0;
  });
};

const queryTable = (name: string): any => {
  const matching = (args: any): any[] => {
    const table = schemas[name];
    const where = typeof args?.where === 'function' ? args.where(table, ops) : args?.where;
    const rows = store[name].filter((row) => (where ? where.test(row) : true));
    const order = typeof args?.orderBy === 'function' ? args.orderBy(table, ops) : args?.orderBy;
    return ordered(rows, order);
  };
  return { findFirst: async (args: any) => matching(args)[0], findMany: async (args: any) => matching(args) };
};

const MODEL_CALL_GROUPS = ['role', 'model', 'status', 'costSource'] as const;

function groupedUsage(rows: any[]): any[] {
  const groups = new Map<string, any[]>();
  for (const row of rows) {
    const key = JSON.stringify(MODEL_CALL_GROUPS.map((name) => row[name]));
    groups.set(key, [...(groups.get(key) ?? []), row]);
  }
  const sum = (group: any[], name: string): number => group.reduce((total, row) => total + (row[name] ?? 0), 0);
  return [...groups.values()].map((group) => ({
    role: group[0].role,
    model: group[0].model,
    status: group[0].status,
    costSource: group[0].costSource,
    calls: group.length,
    inputTokens: sum(group, 'inputTokens'),
    cachedInputTokens: sum(group, 'cachedInputTokens'),
    outputTokens: sum(group, 'outputTokens'),
    latencyMs: sum(group, 'latencyMs'),
    recordedCostUsd: sum(group, 'costUsd'),
    unpricedInputTokens: sum(group.filter((row) => row.costUsd === null), 'inputTokens'),
    unpricedOutputTokens: sum(group.filter((row) => row.costUsd === null), 'outputTokens'),
  }));
}

function selectBuilder(fields: any): any {
  const state: { table: object | null; where: any; grouped: boolean } = { table: null, where: null, grouped: false };
  const builder: any = new Proxy(
    {},
    {
      get(_, method: string) {
        if (method === 'then') {
          return (resolve: (rows: any[]) => void, reject: (error: unknown) => void) => {
            try {
              const name = state.table ? tableNames.get(state.table) : undefined;
              const rows = (name ? store[name] : []).filter((row) => (state.where ? state.where.test(row) : true));
              if (state.grouped) return resolve(groupedUsage(rows));
              if (fields && name) return resolve(rows.map((row) => Object.fromEntries(Object.entries(fields).map(([alias, column]) => [alias, row[keyOf(column as object)]]))));
              resolve(rows);
            } catch (error) {
              reject(error);
            }
          };
        }
        return (...args: any[]) => {
          if (method === 'from') state.table = args[0];
          if (method === 'where') state.where = args[0];
          if (method === 'groupBy') state.grouped = true;
          return builder;
        };
      },
    },
  );
  return builder;
}

const audits: any[] = [];
const fakeDb: any = {
  query: new Proxy({}, { get: (_, name: string) => queryTable(name) }),
  select: (fields?: any) => selectBuilder(fields),
  insert: () => ({
    values: (rows: any[]) => {
      audits.push(...rows);
      return { catch: () => Promise.resolve() };
    },
  }),
};

const lookupModule = await import(join(server, 'modules/refinement/chat-lookup.service.ts'));
const registry = await import(join(server, 'modules/ai/tools/tool-registry.service.ts'));
const traceModule = await import(join(server, 'modules/refinement/chat-turn-trace.ts'));
const plannerGuard = await import(join(server, 'modules/refinement/planner-only-guard.ts'));
const chatPrompt = await import(join(server, 'modules/ai/prompts/chat-refine.prompt.ts'));
const metrics = await import(join(server, 'modules/eval/deterministic-metrics.ts'));
const noop = { warn: () => undefined, error: () => undefined };

const service: any = Object.create(lookupModule.ChatLookupService.prototype);
service.db = fakeDb;
service.logger = noop;
service.toolRegistry = new registry.ToolRegistryService();

const PROJECT = 1n;
const strip = (text: string): string => text.replace(/[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]/g, '');
const sanitize = (value: unknown): unknown => JSON.parse(JSON.stringify(value, (_, item) => (typeof item === 'bigint' ? Number(item) : item)));

function createRng(seed: number): () => number {
  let state = seed | 0;
  return () => {
    state = (state + 0x6d2b79f5) | 0;
    let t = Math.imul(state ^ (state >>> 15), 1 | state);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const next = createRng(20261117);
const pick = <T>(items: readonly T[]): T => items[Math.floor(next() * items.length)] as T;
const WORDS = ('the a of and to in he she it was had were that with for on as at by from his her they them there then when what which who would could should lighthouse keeper '
  + 'stairs window grey sea sky morning lantern harbour captain letter promise winter river bridge silence shadow memory garden kitchen walked climbed whispered remembered '
  + 'carried opened closed turned waited listened wondered believed forgot answered followed slowly quietly suddenly always never old young cold long narrow bright empty heavy').split(' ');
const words = (count: number): string => Array.from({ length: count }, () => pick(WORDS)).join(' ');
const sentence = (): string => {
  const text = words(5 + Math.floor(next() * 9));
  return `${text.charAt(0).toUpperCase()}${text.slice(1)}.`;
};
const paragraph = (sentences: number): string => Array.from({ length: sentences }, sentence).join(' ');
const prose = (paragraphs: number, sentences = 3): string => Array.from({ length: paragraphs }, () => paragraph(sentences)).join('\n\n');

type Segment = string | { unit: string; length: number };
const recipes = new Map<string, Segment[]>();
const recipe = (...segments: Segment[]): string => {
  const text = segments.map((segment) => (typeof segment === 'string' ? segment : segment.unit.repeat(Math.ceil(segment.length / segment.unit.length)).slice(0, segment.length))).join('');
  recipes.set(text, segments);
  return text;
};
const UNIT = 'Mara climbed the grey stairs to the lamp room.\n\nThe sea waited below, quiet and cold, and the keeper listened. ';
const proseOf = (length: number): string => recipe({ unit: UNIT, length });

// Postgres jsonb keeps object keys by length, then bytes, and the reference reads them back in that order.
const jsonb = (value: any): any => {
  if (Array.isArray(value)) return value.map(jsonb);
  if (value === null || typeof value !== 'object') return value;
  const bytes = (key: string): Buffer => Buffer.from(key, 'utf8');
  return Object.fromEntries(
    Object.entries(value)
      .sort(([left], [right]) => bytes(left).length - bytes(right).length || Buffer.compare(bytes(left), bytes(right)))
      .map(([key, item]) => [key, jsonb(item)]),
  );
};

const FRONTMATTER = jsonb({ title: 'Overview', n: 7, ok: true, nothing: null, tags: ['a', 'b'], nested: { zz: 1, b: { yy: 2, x: 1 }, 'ünï': 3 }, aa: 'first', z: 'last', ctl: 'tab\there\nnl \u0001 "q" \\' });
const HEADER_OVERVIEW = '**lore/huge** (rev 1)\n'.length;
const emojiAtCut = (limit: number): string => recipe({ unit: 'x', length: limit - HEADER_OVERVIEW - 1 }, '😀', { unit: 'tail ', length: 200 });

const pages = [
  { section: 'project', slug: 'overview', revision: 3, frontmatter: FRONTMATTER, body: 'A short overview.\n\nSecond paragraph with 日本語 and 😀.' },
  { section: 'world', slug: 'places', revision: 1, frontmatter: {}, body: 'Places of the book.' },
  { section: 'world', slug: 'empty-body', revision: 2, frontmatter: null, body: null },
  { section: 'world', slug: 'blank-body', revision: 2, frontmatter: null, body: '' },
  { section: 'project', slug: 'timeline', revision: 4, frontmatter: { kind: 'timeline' }, body: 'Organised timeline.' },
  { section: 'project', slug: 'open-questions', revision: 1, frontmatter: null, body: 'What is under the tower?' },
  { section: 'story_state', slug: 'volume-plan', revision: 5, frontmatter: null, body: prose(3) },
  { section: 'lore', slug: 'huge', revision: 1, frontmatter: null, body: emojiAtCut(24000) },
  { section: 'lore', slug: 'ünï-café', revision: 1, frontmatter: { 'ñ': 'é' }, body: 'Combining: é and é.' },
];

const entities = [
  { id: 1n, entityKey: 'mara', name: 'Mara', type: 'character', status: null, firstSeenChapter: null, body: 'The lighthouse keeper.', notes: 'ignored notes' },
  { id: 2n, entityKey: 'tower', name: 'The Tower', type: 'location', status: 'ruined', firstSeenChapter: null, body: null, notes: 'Only notes here.' },
  { id: 3n, entityKey: 'blank', name: 'Blank', type: 'item', status: 'active', firstSeenChapter: null, body: '', notes: 'hidden by the empty body' },
  { id: 4n, entityKey: 'nothing', name: 'Nothing', type: 'concept', status: null, firstSeenChapter: null, body: null, notes: null },
  { id: 5n, entityKey: 'ünï', name: 'Ünï', type: 'faction', status: 'active', firstSeenChapter: null, body: 'Accents é and 😀', notes: null },
  { id: 6n, entityKey: 'long', name: 'Long', type: 'power_rule', status: null, firstSeenChapter: null, body: proseOf(14100), notes: null },
];

const ENDING = { hookType: 'cliffhanger', handoffState: 'at the door', openQuestion: 'who knocked?', emotionalBeat: 'dread' };
const briefs = [
  {
    chapter: 1, volumeKey: 'one', title: 'The Lamp', body: 'Mara lights the lamp.', contextRefs: ['project/overview', 'world/places'], pov: 'mara', endingContract: ENDING,
    knowledgeContract: { pov: ['mara'], learns: [] }, chapterPurpose: 'Establish the keeper.', readerValue: ['dread', 'warmth'], repetitionRisks: ['the lamp again'],
    guidance: 'Keep it quiet.', writeMode: 'standard', revision: 4,
  },
  {
    chapter: 2, volumeKey: null, title: null, body: 'Bare plan.', contextRefs: [], pov: null, endingContract: null, knowledgeContract: null, chapterPurpose: null, readerValue: [], repetitionRisks: null,
    guidance: '', writeMode: 'external', revision: 1,
  },
  {
    chapter: 5, volumeKey: 'one', title: null, body: 'Plan five.', contextRefs: null, pov: null, endingContract: null, knowledgeContract: null, chapterPurpose: null, readerValue: null,
    repetitionRisks: null, guidance: null, writeMode: 'standard', revision: 1,
  },
  {
    chapter: 7, volumeKey: 'two', title: 'Reveal', body: 'The heir is named.', contextRefs: null, pov: 'mara', endingContract: { ...ENDING, mustNotResolve: ['the heir'] },
    knowledgeContract: { pov: ['mara', 'tower'], learns: [{ factKey: 'heir', entityKey: 'mara' }, { factKey: 'tide', entityKey: 'tower' }] }, chapterPurpose: null, readerValue: null,
    repetitionRisks: null, guidance: null, writeMode: 'standard', revision: 2,
  },
  { chapter: 9, volumeKey: 'two', title: 'Long', body: proseOf(20100), contextRefs: null, pov: null, endingContract: null, knowledgeContract: null, chapterPurpose: null, readerValue: null, repetitionRisks: null, guidance: null, writeMode: 'standard', revision: 1 },
];

const draftRow = (chapter: number, title: string | null, body: string, review: string, extra: Record<string, unknown> = {}): any => ({
  chapter, title, status: review === 'final' ? 'final' : 'draft', revision: chapter, words: metrics.countWords(body), summary: null, body, isolated: false, reviewStatus: review, ...extra,
});
const drafts = [
  draftRow(1, 'The Lamp', prose(2), 'final', { summary: 'Mara lights the lamp.' }),
  draftRow(5, 'Low Tide', prose(2), 'approved', { summary: 'The tide drops.' }),
  draftRow(8, null, prose(3), 'needs_review'),
  draftRow(9, 'Hidden Title', prose(2), 'needs_review', { isolated: true, summary: 'private summary' }),
  draftRow(10, 'Empty', '', 'needs_review'),
  draftRow(11, 'Huge', proseOf(40300), 'needs_review', { summary: 'big' }),
];

const chapters = [
  { number: 1, summary: 'Mara lights the lamp and meets the heir.', isolated: false, title: 'The Lamp', disclosed: ['heir'] },
  { number: 2, summary: null, isolated: false, title: null, disclosed: [] },
  { number: 3, summary: 'A third summary — with 日本語 and 😀.', isolated: false, title: 'Third', disclosed: ['secret_c'] },
  { number: 4, summary: 'Hidden summary', isolated: true, title: 'Walled', disclosed: [] },
  { number: 6, summary: 'Sixth.', isolated: false, title: 'Sixth', disclosed: [] },
];

const volumes = [
  { volumeKey: 'one', ordinal: 1, title: 'The Lamp Years', objective: 'Establish the keeper.', body: 'Volume one notes.' },
  { volumeKey: 'two', ordinal: 2, title: null, objective: null, body: null },
  { volumeKey: 'three', ordinal: 3, title: 'Three', objective: '', body: '' },
];

const threads = [
  { threadKey: 'ghost', status: 'dropped', openedChapter: null, closedChapter: 4, summary: 'A dropped ghost.', payoffWindow: null, payoffMilestoneKey: null, payoffVolumeKey: 'two', intentionallyOpen: true },
  { threadKey: 'lamp', status: 'open', openedChapter: 1, closedChapter: null, summary: 'Who keeps the lamp?', payoffWindow: 9, payoffMilestoneKey: null, payoffVolumeKey: null, intentionallyOpen: false },
  { threadKey: 'quiet', status: 'open', openedChapter: 3, closedChapter: null, summary: 'Quiet thread', payoffWindow: null, payoffMilestoneKey: null, payoffVolumeKey: null, intentionallyOpen: true },
  { threadKey: 'tide', status: 'closed', openedChapter: 2, closedChapter: 6, summary: null, payoffWindow: null, payoffMilestoneKey: 'rise', payoffVolumeKey: 'one', intentionallyOpen: false },
];

const facts = [
  { factKey: 'heir', text: 'Mara is the heir.', unlock: { all: [{ chapter: 4 }] }, plannedChapter: 7, disclosedInChapter: 1, writerNote: 'Hint only.', terms: ['heir', 'crown'], allowedClues: ['a ring', 'a scar'] },
  { factKey: 'tide', text: 'The tide is a clock.', unlock: { all: [{ milestone: 'rise' }, { volume: 'two' }, { ending: true }] }, plannedChapter: null, disclosedInChapter: null, writerNote: null, terms: [], allowedClues: [] },
  { factKey: 'secret_a', text: 'Plain secret.', unlock: null, plannedChapter: null, disclosedInChapter: null, writerNote: '', terms: null, allowedClues: null },
  { factKey: 'secret_b', text: 'Bad unlock shape.', unlock: { any: [] }, plannedChapter: null, disclosedInChapter: null, writerNote: null, terms: ['x'], allowedClues: null },
  { factKey: 'secret_c', text: 'Revealed secret with 😀.', unlock: null, plannedChapter: null, disclosedInChapter: 3, writerNote: 'Careful.', terms: null, allowedClues: ['ring'] },
];

const NOTES_LONG = `${paragraph(3)}\n\n${'abcdefghij'.repeat(300)}\n\n${paragraph(2)}\n\n${'日本語の文章です。'.repeat(150)}\n\n${prose(8, 4)}`;
const NOTES_MANY = Array.from({ length: 45 }, (_, index) => `Note ${index + 1}: ${paragraph(3)}`).join('\n\n');
const NOTES_SHORT = 'First paragraph about the Heir.\n\n\n\nSecond paragraph.\n\n   \n\nThird, with 😀 and Heir again.';

const ledgerRow = (statement: string): any => ({ projectId: PROJECT, topic: 'start.brief', supersededAt: null, createdAt: new Date(0), statement });

const usageCalls = [
  { task: 'writing', model: 'claude-big', outcome: 'finished', input: 12000, output: 8000, cacheRead: 500, nano: 123_000_000, source: 'reported' },
  { task: 'writing', model: 'claude-big', outcome: 'finished', input: 3000, output: 1000, cacheRead: 0, nano: 44_000_000, source: 'reported' },
  { task: 'planning', model: 'claude-mid', outcome: 'finished', input: 900, output: 300, cacheRead: 0, nano: 2_500_000, source: 'computed' },
  { task: 'chat', model: 'claude-mid', outcome: 'finished', input: 1_000_000, output: 20, cacheRead: 0, nano: 5_000, source: 'computed' },
  { task: 'review', model: 'claude-small', outcome: 'finished', input: 1_234_567, output: 89_012, cacheRead: 0, nano: 1_500_000_000, source: 'reported' },
];
const usageRows = (calls: typeof usageCalls): any[] =>
  calls.map((call) => ({
    projectId: PROJECT,
    role: call.task,
    model: call.model,
    status: call.outcome === 'finished' ? 'ok' : 'error',
    costSource: call.source === 'computed' ? 'estimate' : call.source,
    costUsd: call.nano / 1e9,
    inputTokens: call.input,
    cachedInputTokens: call.cacheRead,
    outputTokens: call.output,
    latencyMs: 1234,
    chapter: null,
    runId: 'r',
    createdAt: new Date(0),
  }));

const worlds: Record<string, any> = {
  rich: { pages, entities, briefs, drafts, chapters, volumes, threads, facts, notes: NOTES_SHORT, usage: usageCalls },
  bare: { pages: [], entities: [], briefs: [], drafts: [], chapters: [], volumes: [], threads: [], facts: [], notes: null, usage: [] },
  longNotes: { pages: [], entities: [], briefs: [], drafts: [], chapters: [], volumes: [], threads: [], facts: [], notes: NOTES_LONG, usage: [] },
  manyNotes: { pages: [], entities: [], briefs: [], drafts: [], chapters: [], volumes: [], threads: [], facts: [], notes: NOTES_MANY, usage: [] },
  singleCall: { pages: [], entities: [], briefs: [], drafts: [], chapters: [], volumes: [], threads: [], facts: [], notes: null, usage: usageCalls.slice(0, 1) },
};

function load(world: any): void {
  const withProject = (rows: any[]): any[] => rows.map((row) => ({ projectId: PROJECT, ...row }));
  store.bibleDocuments = withProject(world.pages);
  store.entities = withProject(world.entities);
  store.entityAliases = [];
  store.entityRelationships = [];
  store.briefs = withProject(world.briefs);
  store.drafts = withProject(world.drafts);
  store.chapters = withProject(world.chapters);
  store.volumes = withProject(world.volumes);
  store.plotThreads = withProject(world.threads);
  store.canonFacts = withProject(world.facts);
  store.decisionLedgerEntries = world.notes === null ? [] : [ledgerRow(world.notes)];
  store.modelCalls = usageRows(world.usage);
  store.workflowRuns = [];
}

interface Lookup {
  tool: string;
  args?: unknown;
}

interface CaseSpec {
  name: string;
  world: string;
  lookups: Lookup[];
  withoutDuration?: boolean;
}

const doc = (section: unknown, slug: unknown): Lookup => ({ tool: 'get_bible_document', args: { section, slug } });
const tool = (name: string, args?: unknown): Lookup => ({ tool: name, args });

const specs: CaseSpec[] = [
  { name: 'bible document: frontmatter, nested key order, accents', world: 'rich', lookups: [doc('project', 'overview'), doc('lore', 'ünï-café'), doc('world', 'places')] },
  { name: 'bible document: empty bodies and not found', world: 'rich', lookups: [doc('world', 'empty-body'), doc('world', 'blank-body'), doc('world', 'missing'), doc('plot', 'nothing')] },
  { name: 'bible document: planner-only pages', world: 'rich', lookups: [doc('project', 'timeline')] },
  { name: 'bible document: planner-only page that does not exist', world: 'rich', lookups: [doc('project', 'open-questions'), doc('project', 'timeline')] },
  { name: 'bible document: writer-excluded page is not planner-only', world: 'rich', lookups: [doc('story_state', 'volume-plan')] },
  { name: 'bible document: cut inside a surrogate pair', world: 'rich', lookups: [doc('lore', 'huge')] },
  { name: 'bible document: argument errors', world: 'rich', lookups: [doc('nowhere', 'x'), tool('get_bible_document', { section: 'world' }), tool('get_bible_document', {}), tool('get_bible_document'), doc(3, 4), doc(null, true), doc(['world'], {})] },
  { name: 'bible document: unknown keys are stripped', world: 'rich', lookups: [tool('get_bible_document', { section: 'world', slug: 'places', extra: 1, chapter: 'x' })] },
  { name: 'bible document: call budget', world: 'rich', lookups: Array.from({ length: 12 }, () => doc('world', 'places')) },
  { name: 'brief: full', world: 'rich', lookups: [tool('get_brief', { chapter: 1 }), tool('get_brief', { chapter: 7 })] },
  { name: 'brief: sparse and external', world: 'rich', lookups: [tool('get_brief', { chapter: 2 })] },
  { name: 'brief: not found and odd numbers', world: 'rich', lookups: [tool('get_brief', { chapter: 3 }), tool('get_brief', { chapter: 1e21 }), tool('get_brief', { chapter: 1e300 }), tool('get_brief', { chapter: 9007199254740993 })] },
  { name: 'brief: argument errors', world: 'rich', lookups: [tool('get_brief', { chapter: 0 }), tool('get_brief', { chapter: -3 }), tool('get_brief', { chapter: 1.5 }), tool('get_brief', { chapter: 0.5 }), tool('get_brief', { chapter: '2' }), tool('get_brief', { chapter: null }), tool('get_brief', {}), tool('get_brief', { chapter: [1] }), tool('get_brief', { chapter: true })] },
  { name: 'brief: truncation', world: 'rich', lookups: [tool('get_brief', { chapter: 9 })] },
  { name: 'draft: statuses', world: 'rich', lookups: [tool('get_draft', { chapter: 1 }), tool('get_draft', { chapter: 5 }), tool('get_draft', { chapter: 8 })] },
  { name: 'draft: isolated, empty, missing', world: 'rich', lookups: [tool('get_draft', { chapter: 9 }), tool('get_draft', { chapter: 10 }), tool('get_draft', { chapter: 99 })] },
  { name: 'draft: truncation and budget', world: 'rich', lookups: [tool('get_draft', { chapter: 11 }), tool('get_draft', { chapter: 1 }), tool('get_draft', { chapter: 1 })] },
  { name: 'entity: cards', world: 'rich', lookups: [tool('get_entity', { entityKey: 'mara' }), tool('get_entity', { entityKey: 'tower' }), tool('get_entity', { entityKey: 'blank' }), tool('get_entity', { entityKey: 'nothing' }), tool('get_entity', { entityKey: 'ünï' })] },
  { name: 'entity: missing, errors and truncation', world: 'rich', lookups: [tool('get_entity', { entityKey: 'ghost' }), tool('get_entity', { entityKey: '' }), tool('get_entity', {}), tool('get_entity', { entityKey: 5 })] },
  { name: 'canon facts: disclosure, unlock terms, planned reveal', world: 'rich', lookups: [tool('get_canon_facts', { keys: ['heir', 'tide', 'secret_a'] }), tool('get_canon_facts', { keys: ['secret_c', 'secret_b'] })] },
  { name: 'canon facts: missing keys and duplicates', world: 'rich', lookups: [tool('get_canon_facts', { keys: ['nope', 'heir', 'nope', 'heir'] }), tool('get_canon_facts', { keys: ['x', 'y'] }), tool('get_canon_facts', { keys: ['tide', 'heir', 'secret_a'] })] },
  { name: 'canon facts: argument errors', world: 'rich', lookups: [tool('get_canon_facts', { keys: [] }), tool('get_canon_facts', { keys: Array.from({ length: 21 }, (_, index) => `k${index}`) }), tool('get_canon_facts', { keys: [''] }), tool('get_canon_facts', { keys: ['a', 1, ''] }), tool('get_canon_facts', { keys: 'heir' }), tool('get_canon_facts', {}), tool('get_canon_facts', { keys: Array.from({ length: 21 }, () => 3) })] },
  { name: 'canon facts: no facts at all', world: 'bare', lookups: [tool('get_canon_facts', { keys: ['heir'] })] },
  { name: 'chapter summaries: range with gaps, bridges and unrestricted', world: 'rich', lookups: [tool('get_chapter_summaries', { from: 1, to: 6 }), tool('get_chapter_summaries', { from: 4, to: 4 }), tool('get_chapter_summaries', { from: 2, to: 2 })] },
  { name: 'chapter summaries: empty and reversed ranges', world: 'rich', lookups: [tool('get_chapter_summaries', { from: 7, to: 12 }), tool('get_chapter_summaries', { from: 5, to: 2 }), tool('get_chapter_summaries', { from: 1, to: 21 }), tool('get_chapter_summaries', { from: 1, to: 22 })] },
  { name: 'chapter summaries: argument errors', world: 'rich', lookups: [tool('get_chapter_summaries', { from: 0, to: 3 }), tool('get_chapter_summaries', { from: 1 }), tool('get_chapter_summaries', {}), tool('get_chapter_summaries', { from: 'a', to: 2.5 }), tool('get_chapter_summaries', { from: 1, to: 30 }), tool('get_chapter_summaries', { from: 1e300, to: 1e300 }), tool('get_chapter_summaries', { from: 0, to: 40 })] },
  { name: 'chapter summaries: none stored', world: 'bare', lookups: [tool('get_chapter_summaries', { from: 1, to: 3 })] },
  { name: 'plot threads: all and filtered', world: 'rich', lookups: [tool('get_plot_threads'), tool('get_plot_threads', {}), tool('get_plot_threads', { status: 'open' }), tool('get_plot_threads', { status: 'closed' }), tool('get_plot_threads', { status: 'dropped' })] },
  { name: 'plot threads: none and argument errors', world: 'bare', lookups: [tool('get_plot_threads'), tool('get_plot_threads', { status: 'bogus' }), tool('get_plot_threads', { status: 3 }), tool('get_plot_threads', { status: null }), tool('get_plot_threads', { status: 'open' }), tool('get_plot_threads', { status: 'open' })] },
  { name: 'volume: records', world: 'rich', lookups: [tool('get_volume', { volumeKey: 'one' }), tool('get_volume', { volumeKey: 'two' }), tool('get_volume', { volumeKey: 'three' }), tool('get_volume', { volumeKey: 'nine' }), tool('get_volume', {})] },
  { name: 'notes: none stored', world: 'bare', lookups: [tool('get_notes'), tool('get_notes', { from: 2 })] },
  { name: 'notes: short notes, queries and offsets', world: 'rich', lookups: [tool('get_notes'), tool('get_notes', { query: 'heir' }), tool('get_notes', { query: '  HEIR ' }), tool('get_notes', { from: 2 }), tool('get_notes', { from: 4 })] },
  { name: 'notes: past the end and no match', world: 'rich', lookups: [tool('get_notes', { from: 9 }), tool('get_notes', { query: 'zzz' }), tool('get_notes', { from: 3, query: 'heir' }), tool('get_notes', { part: 2 })] },
  { name: 'notes: argument errors', world: 'rich', lookups: [tool('get_notes', { from: 0 }), tool('get_notes', { part: 0 }), tool('get_notes', { query: '   ' }), tool('get_notes', { query: '' }), tool('get_notes', { from: 1.5 }), tool('get_notes', { query: 7 }), tool('get_notes', { from: null })] },
  { name: 'notes: long paragraphs come in parts', world: 'longNotes', lookups: [tool('get_notes'), tool('get_notes', { from: 2, part: 2 }), tool('get_notes', { from: 4, part: 3 })] },
  { name: 'notes: paging over many paragraphs', world: 'manyNotes', lookups: [tool('get_notes'), tool('get_notes', { from: 30 }), tool('get_notes', { query: 'note 5' })] },
  { name: 'usage: totals and roles', world: 'rich', lookups: [tool('get_usage'), tool('get_usage', { period: 'all' })], withoutDuration: true },
  { name: 'usage: one call, none, errors', world: 'singleCall', lookups: [tool('get_usage'), tool('get_usage', { period: 'year' }), tool('get_usage', { last_run: 'yes' }), tool('get_usage', { chapter: 0 })], withoutDuration: true },
  { name: 'usage: nothing recorded', world: 'bare', lookups: [tool('get_usage')] },
  { name: 'rounds: unknown and unoffered tools, joined blocks', world: 'rich', lookups: [tool('search_web', { query: 'x' }), tool('fetch_page', { url: 'https://example.com' }), tool('nope'), tool(''), tool('GET_BRIEF', { chapter: 1 }), tool('get_volume', { volumeKey: 'one' }), tool('get_entity', { entityKey: 'mara' })] },
  { name: 'rounds: call budgets per tool', world: 'rich', lookups: [...Array.from({ length: 3 }, () => tool('get_draft', { chapter: 1 })), ...Array.from({ length: 5 }, () => tool('get_canon_facts', { keys: ['heir'] }))] },
];

const lookupsOf = (spec: CaseSpec): any[] => spec.lookups.map((lookup) => (lookup.args === undefined ? { tool: lookup.tool } : { tool: lookup.tool, args: lookup.args }));

const callLimits = new Map<string, number>(registry.toolsForNode('chat-hub').map((entry: any) => [entry.name, entry.maxCallsPerRun]));
const chunked = (spec: CaseSpec): CaseSpec[] => {
  if (spec.name.startsWith('rounds:') || spec.name.endsWith('call budget')) return [spec];
  const chunks: Lookup[][] = [[]];
  let counts = new Map<string, number>();
  for (const lookup of spec.lookups) {
    const used = (counts.get(lookup.tool) ?? 0) + 1;
    if (used > (callLimits.get(lookup.tool) ?? 0) && used > 1) {
      chunks.push([]);
      counts = new Map();
    }
    counts.set(lookup.tool, (counts.get(lookup.tool) ?? 0) + 1);
    chunks[chunks.length - 1]?.push(lookup);
  }
  return chunks.map((lookups, index) => ({ ...spec, name: index === 0 ? spec.name : `${spec.name} (${index + 1})`, lookups }));
};

const cases: any[] = [];
for (const spec of specs.flatMap(chunked)) {
  load(worlds[spec.world]);
  audits.length = 0;
  const planner = { read: false };
  const callCounts = new Map<string, number>();
  const sources: any[] = [];
  const traceStub = { lookupStarted: () => undefined, lookupSettled: (name: string, args: any, status: string) => sources.push({ tool: name, args: traceModule.traceArgs(name, args), status }) };
  let text: string = await service.executeLookups(PROJECT, 'run', lookupsOf(spec), callCounts, { round: 1, relay: null, trace: traceStub, planner, webMode: 'off' });
  text = text.replace(/\nFirst seen: ch \?(?=\n|$)/g, '');
  if (spec.withoutDuration) text = text.replace(/, \d+(\.\d+)?(ms|s) total\./g, '.');
  const outcomes = audits.map((audit, index) => ({ tool: audit.tool, status: audit.status, trace: sources[index]?.args ?? {}, traceStatus: sources[index]?.status }));
  cases.push({
    name: spec.name,
    world: spec.world,
    lookups: spec.lookups.map((lookup) => ({ tool: lookup.tool, argsJSON: lookup.args === undefined ? null : JSON.stringify(lookup.args) })),
    expected: { text: strip(text), plannerRead: planner.read, outcomes },
    withoutDuration: spec.withoutDuration ?? false,
  });
}

const TRACE_TOOLS = ['get_bible_document', 'get_brief', 'get_notes', 'get_chapter_summaries', 'get_plot_threads', 'get_entity', 'get_volume', 'get_review', 'search_web', 'fetch_page', 'get_usage', 'constructor', '__proto__', ''];
const TRACE_ARGS: unknown[] = [
  {},
  { slug: 'overview', section: 'plot' },
  { slug: '  padded  ', section: '' },
  { slug: 'x'.repeat(200), section: 'y'.repeat(121) },
  { slug: ('é' + ' ').repeat(80) },
  { chapter: 3, from: 2, to: 9, part: 4 },
  { chapter: '3', from: null, to: 1.5, part: -2 },
  { chapter: 1e21, from: 1e999 },
  { query: 'q'.repeat(41) },
  { query: `${'a'.repeat(39)}  b` },
  { query: '  spaced out query  ' },
  { query: '😀'.repeat(30) },
  { query: '   ' },
  { status: 'open', entityKey: 'mara', volumeKey: 'one', category: 'c', url: 'https://example.com/a' },
  { status: 5, entityKey: null, volumeKey: [], category: {}, url: false },
  { entityKey: 'e'.repeat(121), volumeKey: ' v ', category: ' nbsp ' },
  { constructor: 'x', toString: 'y', __proto__: 'z' },
  { extra: 'ignored' },
];
const traceFixtures = TRACE_TOOLS.flatMap((name) => TRACE_ARGS.map((args) => ({ tool: name, argsJSON: JSON.stringify(args), expected: sanitize(traceModule.traceArgs(name, args as any)) })));

const definitions = [...registry.toolsForNode('chat-hub')].map((entry: any) => ({
  name: entry.name,
  description: entry.description,
  maxCallsPerRun: entry.maxCallsPerRun,
  tokensBudget: entry.tokensBudget,
  arguments: entry.inputSchema instanceof zod.z.ZodObject ? Object.keys(entry.inputSchema.shape) : null,
}));
const toolLines = chatPrompt.chatScopeInstructions(registry.toolsForNode('chat-hub')).split('\n').filter((line: string) => line.startsWith('- '));

const fixture = {
  notes: 'The expected text of every case is the reference lookup service run over a fake database; get_usage cases drop the duration clause the on-device ledger cannot record; lone surrogates are stripped; entity cards drop the constant first-seen line the vault cannot fill.',
  bibleSections: [...schemas.bibleSection.enumValues],
  definitions,
  scopeLines: toolLines,
  worlds: JSON.parse(JSON.stringify(worlds, (_, item) => (typeof item === 'bigint' ? Number(item) : typeof item === 'string' && recipes.has(item) ? { recipe: recipes.get(item) } : item))),
  cases,
  trace: traceFixtures,
  plannerGuard: ['get_notes', 'get_bible_document', 'get_brief'].flatMap((name) =>
    [
      { section: 'project', slug: 'timeline' },
      { section: 'project', slug: 'open-questions' },
      { section: 'project', slug: 'overview' },
      { section: 3, slug: 'timeline' },
      {},
    ].map((args) => ({ tool: name, argsJSON: JSON.stringify(args), expected: plannerGuard.readsPlannerOnlyPage(name, args) })),
  ),
};

writeFileSync(join(outDir, 'chat-lookups.json'), `${JSON.stringify(sanitize(fixture))}\n`);
