import { mock } from 'bun:test';
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');
const src = join(platformRepo, 'apps/novel-forge-server/src');
const outDir = dirname(fileURLToPath(import.meta.url));

mock.module('@shadow-library/app', () => ({ Injectable: () => () => undefined }));
mock.module('@shadow-library/common', () => ({ Logger: { getLogger: () => ({}) } }));
mock.module('@shadow-library/modules', () => ({ DatabaseService: class {} }));
mock.module('drizzle-orm', () => ({ and: () => 0, asc: () => 0, eq: () => 0, isNull: () => 0 }));
mock.module('@server/constants', () => ({ APP_NAME: 'stub' }));
mock.module('@server/database', () => ({ schema: { drafts: { projectId: 0 }, chapters: { projectId: 0, status: 0 }, projects: {}, volumes: {} } }));
mock.module('@server/classes', () => import(join(src, 'classes/app-error-code.ts')));
mock.module(join(src, 'modules/ledger/ledger-entries.ts'), () => ({ filterLedgerEntries: () => [], loadActiveLedger: () => [], mergeLedgerLinks: () => ({}) }));
mock.module(join(src, 'modules/ledger/ledger-sections.ts'), () => ({ isReservedTopic: () => false }));

const batch = await import(join(src, 'common/batch-selection.ts'));
const nextChapter = await import(join(src, 'common/next-chapter.ts'));
const volumeStats = await import(join(src, 'common/volume-stats.ts'));
const promise = await import(join(src, 'common/promise.ts'));
const progress = await import(join(src, 'common/progress.ts'));
const contentHash = await import(join(src, 'common/content-hash.ts'));
const briefScenes = await import(join(src, 'common/brief-scenes.ts'));
const manifest = await import(join(src, 'modules/bible/bible-manifest.ts'));
const hookEnums = await import(join(src, 'modules/ai/schemas/enums.ts'));
const opSpecs = await import(join(src, 'modules/refinement/change-set/op-specs.ts'));
const ledger = await import(join(src, 'modules/ledger/ledger.service.ts'));
const ledgerTypes = await import(join(src, 'modules/ledger/ledger.types.ts'));
const enumSchemas = {
  story: await import(join(src, 'database/schemas/story.ts')),
  plan: await import(join(src, 'database/schemas/plan.ts')),
  knowledge: await import(join(src, 'database/schemas/knowledge.ts')),
  generation: await import(join(src, 'database/schemas/generation.ts')),
  ledger: await import(join(src, 'database/schemas/ledger.ts')),
  bible: await import(join(src, 'database/schemas/bible.ts')),
};

interface Rng {
  next(): number;
  int(min: number, max: number): number;
  chance(p: number): boolean;
  pick<T>(items: readonly T[]): T;
  shuffle<T>(items: readonly T[]): T[];
}

function createRng(seed: number): Rng {
  let state = seed | 0;
  const next = (): number => {
    state = (state + 0x6d2b79f5) | 0;
    let t = Math.imul(state ^ (state >>> 15), 1 | state);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  const int = (min: number, max: number): number => min + Math.floor(next() * (max - min + 1));
  return {
    next,
    int,
    chance: p => next() < p,
    pick: items => items[Math.floor(next() * items.length)] as never,
    shuffle: items => {
      const out = [...items];
      for (let i = out.length - 1; i > 0; i--) {
        const j = int(0, i);
        [out[i], out[j]] = [out[j] as never, out[i] as never];
      }
      return out;
    },
  };
}

const WORDS = ['Mira', 'tide', 'ash', 'the bell', 'keeper', 'draft', 'Ünï', 'é', 'é', 'İ', 'ǅ', '日本語', '😀', 'x', 'K', 'K', 'a b', "o'k", 'q"t', 'back\\slash', 'line\nbreak'];
const BLANKS = ['', ' ', '\t', ' ', '﻿', ' ', '　', ' \n '];
const NOT_TRIMMED = ['\u0085', '​', '᠎'];
const KEYS = ['v1', 'v2', 'V1', 'é', 'é', '', 'a b', 'K', 'K', 'vol_3', 'mk', 'Mk'];

function text(rng: Rng): string {
  const roll = rng.int(0, 9);
  if (roll === 0) return rng.pick(BLANKS);
  if (roll === 1) return rng.pick(BLANKS) + rng.pick(WORDS) + rng.pick(BLANKS);
  if (roll === 2) return rng.pick(NOT_TRIMMED);
  if (roll === 3) return rng.pick(NOT_TRIMMED) + rng.pick(WORDS);
  return rng.pick(WORDS) + (rng.chance(0.3) ? ' ' + rng.pick(WORDS) : '');
}

function write(name: string, value: unknown): void {
  writeFileSync(join(outDir, name), JSON.stringify(value) + '\n');
}

function repeat<T>(count: number, make: (index: number) => T): T[] {
  return Array.from({ length: count }, (_, index) => make(index));
}

const sorted = (set: Iterable<number>): number[] => [...set].sort((a, b) => a - b);

// batch selection, next chapter
function chapterSets(rng: Rng): { max: number; started: Set<number>; finalized: Set<number> } {
  const max = rng.pick([0, 1, 2, 5, 12]);
  const prefix = rng.int(0, max);
  const started = new Set<number>();
  const finalized = new Set<number>();
  for (let chapter = 1; chapter <= prefix; chapter++) (rng.chance(0.5) ? started : finalized).add(chapter);
  for (let chapter = prefix + 1; chapter <= max; chapter++) {
    if (rng.chance(0.25)) started.add(chapter);
    if (rng.chance(0.25)) finalized.add(chapter);
  }
  if (rng.chance(0.08)) started.add(rng.pick([0, -1, -4, 1000000]));
  if (rng.chance(0.08)) finalized.add(rng.pick([0, -2, 1000000]));
  return { max, started, finalized };
}

const batchCases = repeat(320, index => {
  const rng = createRng(1000 + index);
  const { max, started, finalized } = chapterSets(rng);
  const chapter = (): number => (rng.chance(0.06) ? rng.pick([0, -1, -7, 1000000]) : rng.int(1, Math.max(1, max + 2)));
  const briefs = repeat(rng.int(0, 6), () => ({ chapter: chapter(), writeMode: rng.chance(0.25) ? 'external' : rng.chance(0.04) ? 'weird' : 'standard' }));
  if (rng.chance(0.15) && briefs.length > 0) briefs.push({ ...(rng.pick(briefs) as never) });
  const limit = rng.pick([0, 1, 2, 3, 5, 20, -1, 100]);
  const out = batch.selectGenerationBatch(briefs, started, finalized, limit);
  const modes = ['standard', 'external', 'weird'];
  return [
    briefs.map(brief => [brief.chapter, modes.indexOf(brief.writeMode)]),
    sorted(started),
    sorted(finalized),
    limit,
    [out.chapters, out.stoppedAtExternalChapter ?? null, out.stoppedAtUnwrittenChapter ?? null, out.blockedChapter ?? null],
  ];
});

const firstUnwrittenCases = repeat(310, index => {
  const rng = createRng(2000 + index);
  const { started, finalized } = chapterSets(rng);
  return [sorted(started), sorted(finalized), batch.firstUnwrittenChapter(started, finalized)];
});

const nextChapterCases = await Promise.all(
  repeat(310, async index => {
    const rng = createRng(3000 + index);
    const { started, finalized } = chapterSets(rng);
    const drafts = rng.shuffle([...started]);
    const finals = rng.shuffle([...finalized]);
    const db = { query: { drafts: { findMany: async () => drafts.map(chapter => ({ chapter })) }, chapters: { findMany: async () => finals.map(number => ({ number })) } } };
    const next = await nextChapter.nextWritableChapter(db, 1n);
    const chapter = rng.chance(0.4) ? next : rng.pick([next + 1, next - 1, 0, 1, -3, next + 7]);
    let message: string | null = null;
    try {
      await nextChapter.assertStartsNextChapter(db, 1n, chapter);
    } catch (error) {
      message = (error as Error).message;
    }
    return { row: [drafts, finals, chapter, next, message === null ? 0 : 1], message };
  }),
);

write('batch.json', {
  select: batchCases,
  firstUnwritten: firstUnwrittenCases,
  nextChapter: nextChapterCases.map(entry => entry.row),
  nextChapterMessages: nextChapterCases.filter(entry => entry.message !== null).slice(0, 8).map(entry => [entry.row[2], entry.row[3], entry.message]),
});

// volumes
const VOLUME_STATES = ['not_started', 'active', 'goal_met'];

function volumeRows(rng: Rng, allowUnknown: boolean): { k: string; o: number; s: string }[] {
  return repeat(rng.int(0, 5), () => ({
    k: rng.chance(0.1) ? rng.pick(KEYS) : `v${rng.int(1, 9)}`,
    o: rng.pick([-2, 0, 1, 2, 3, 3, 4, 5, 10, 2147483647]),
    s: allowUnknown && rng.chance(0.1) ? 'paused' : rng.pick(VOLUME_STATES),
  }));
}

const statsCases = repeat(310, index => {
  const rng = createRng(4000 + index);
  const rows = repeat(rng.int(0, 5), () => ({ number: rng.pick([-3, 0, 1, 2, 3, 7, 40, 1000000]), wordCount: rng.chance(0.25) ? null : rng.pick([0, 1, 500, 90000, 4000000]) }));
  const out = volumeStats.deriveVolumeStats(rows);
  return [rows.map(row => [row.number, row.wordCount]), [out.chapterCount, out.firstChapter, out.lastChapter, out.wordCount]];
});

const planRangeCases = repeat(305, index => {
  const rng = createRng(5000 + index);
  const numbers = repeat(rng.int(0, 5), () => rng.pick([-3, 0, 1, 2, 3, 7, 7, 40, 1000000]));
  const out = volumeStats.deriveVolumePlanRange(numbers);
  return [numbers, [out.planChapterCount, out.planFirstChapter, out.planLastChapter]];
});

const nextVolumeCases = repeat(320, index => {
  const rng = createRng(6000 + index);
  const rows = volumeRows(rng, false);
  const key = rng.chance(0.75) && rows.length > 0 ? (rng.pick(rows) as { k: string }).k : rng.pick(['missing', '', 'é', 'é', 'v1', 'V1']);
  const out = volumeStats.nextVolumeToActivate(
    rows.map(row => ({ volumeKey: row.k, ordinal: row.o, state: row.s })),
    key,
  );
  return [rows.map(row => [row.k, row.o, VOLUME_STATES.indexOf(row.s)]), key, out];
});

const autoActivateCases = repeat(330, index => {
  const rng = createRng(7000 + index);
  const rows = volumeRows(rng, true);
  const out = volumeStats.volumeToAutoActivate(rows.map(row => ({ volumeKey: row.k, ordinal: row.o, state: row.s })));
  return [rows.map(row => [row.k, row.o, VOLUME_STATES.indexOf(row.s)]), out];
});

write('volume.json', { stats: statsCases, planRange: planRangeCases, next: nextVolumeCases, autoActivate: autoActivateCases });

// promises
const MILESTONE_STATES = ['open', 'planned', 'reached'];
const PROMISE_KEYS = ['', 'v1', 'v2', 'é', 'é', 'K', 'K', 'mk'];
const LABELS = [null, '', ' ', 'A thread', ' padded ', ' ', '﻿ x ﻿', '\u0085', '​', 'Who?', 'é', 'é', ' ', '\t'];

function stateMap(rng: Rng, states: string[]): [string, number][] {
  const keys = [...new Set(repeat(rng.int(0, 2), () => rng.pick(PROMISE_KEYS)))];
  return keys.map(key => [key, rng.chance(0.1) ? -1 : rng.int(0, states.length - 1)]);
}

function toMap(entries: [string, number][], states: string[]): Map<string, string> {
  return new Map(entries.map(([key, index]) => [key, index < 0 ? 'weird' : (states[index] as string)]));
}

function payoffInput(rng: Rng): { w: number | null; m: string | null; v: string | null } {
  const key = (): string | null => (rng.chance(0.4) ? null : rng.pick(PROMISE_KEYS));
  return { w: rng.chance(0.5) ? null : rng.pick([-1, 0, 1, 5, 10, 11]), m: key(), v: key() };
}

const dueCases = repeat(330, index => {
  const rng = createRng(8000 + index);
  const milestones = stateMap(rng, MILESTONE_STATES);
  const volumes = stateMap(rng, VOLUME_STATES);
  const payoff = payoffInput(rng);
  const chapter = rng.pick([-1, 0, 1, 4, 5, 9, 10, 11, 100]);
  const out = promise.resolvePromiseDueStanding(
    { payoffWindow: payoff.w, payoffMilestoneKey: payoff.m, payoffVolumeKey: payoff.v },
    chapter,
    toMap(milestones, MILESTONE_STATES),
    toMap(volumes, VOLUME_STATES),
  );
  return [payoff.w, payoff.m, payoff.v, chapter, milestones, volumes, out];
});

function itemCases(kind: 'thread' | 'mystery', seed: number, statuses: string[]) {
  return repeat(310, index => {
    const rng = createRng(seed + index);
    const milestones = stateMap(rng, MILESTONE_STATES);
    const volumes = stateMap(rng, VOLUME_STATES);
    const payoff = payoffInput(rng);
    const chapterOrNull = (): number | null => (rng.chance(0.3) ? null : rng.int(0, 30));
    const label = kind === 'mystery' ? (rng.pick(LABELS) ?? '') : rng.pick(LABELS);
    const key = rng.pick(['thread-1', 'm', 'é', 'é', 'k 1']);
    const status = rng.int(0, 2);
    const io = rng.chance(0.3);
    const opened = chapterOrNull();
    const advanced = chapterOrNull();
    const ended = chapterOrNull();
    const chapter = rng.pick([0, 1, 5, 10, 11, 30]);
    const common = {
      status: statuses[status],
      intentionallyOpen: io,
      openedChapter: opened,
      lastAdvancedChapter: advanced,
      payoffWindow: payoff.w,
      payoffMilestoneKey: payoff.m,
      payoffVolumeKey: payoff.v,
      createdAt: new Date(index),
      updatedAt: new Date(index + 1),
    };
    const args = [chapter, toMap(milestones, MILESTONE_STATES), toMap(volumes, VOLUME_STATES)] as const;
    const item =
      kind === 'thread'
        ? promise.threadPromiseItem({ threadKey: key, summary: label, closedChapter: ended, ...common }, ...args)
        : promise.mysteryPromiseItem({ mysteryKey: key, question: label, resolvedChapter: ended, ...common }, ...args);
    return [[key, label, status, io, opened, advanced, ended, payoff.w, payoff.m, payoff.v, chapter, milestones, volumes], [item.label, item.due]];
  });
}

write('promise.json', { due: dueCases, threads: itemCases('thread', 9000, ['open', 'closed', 'dropped']), mysteries: itemCases('mystery', 10000, ['open', 'resolved', 'dropped']) });

// progress
const TOPICS = ['progress.ending', 'progress.premise', 'progress.', 'progress', 'Progress.ending', ' progress.theme', 'progress.é', 'progress.é', 'progress.K', 'progress.bogus', 'world.rules', '', 'progress.protagonist', 'progress.reader_promise', 'progress.next_chapter_planned', 'progress.first_volume_goal', 'progress.opposition', 'progress.theme', 'progress.😀'];
const PAYLOADS: unknown[] = [
  null,
  { status: 'undecided' },
  { status: 'dismissed' },
  { status: 'maybe' },
  { status: null },
  { status: 'Undecided' },
  { status: ['undecided'] },
  {},
  { Status: 'dismissed' },
  'dismissed',
  7,
  true,
  [{ status: 'dismissed' }],
  { status: 'dismissed', extra: 1 },
];
const ENTRY_KINDS = ['system', 'direction', 'decision', 'System', 'weird'];

const topicCases = TOPICS.map(topic => [topic, progress.progressKeyFromTopic(topic)]);

const overrideCases = repeat(320, index => {
  const rng = createRng(11000 + index);
  const entries = repeat(rng.int(0, 5), () => [rng.int(1, 1000000), rng.chance(0.75) ? 0 : rng.int(1, 4), rng.int(0, TOPICS.length - 1), rng.int(0, PAYLOADS.length - 1)]);
  const map = progress.progressOverridesFrom(entries.map(([id, kind, topic, payload]) => ({ id: BigInt(id as number), kind: ENTRY_KINDS[kind as number], topic: TOPICS[topic as number], payload: PAYLOADS[payload as number] })));
  return [entries, [...map.entries()].map(([key, value]: [string, { status: string; entryId: bigint }]) => [key, value.status, Number(value.entryId)])];
});

const FIELD_TEXT = [null, undefined, '', ' ', 'x', ' ', '﻿', '\u0085', '​', '᠎', ' ', ' a ', 'Mira', '\t\n'];

const computeCases = repeat(320, index => {
  const rng = createRng(12000 + index);
  const picks = repeat(8, () => rng.int(0, FIELD_TEXT.length - 1));
  const flags = [rng.chance(0.5), rng.chance(0.5)];
  const fields = {
    premise: FIELD_TEXT[picks[0] as number],
    protagonistKey: FIELD_TEXT[picks[1] as number],
    opposition: FIELD_TEXT[picks[2] as number],
    theme: FIELD_TEXT[picks[3] as number],
    readerPromise: FIELD_TEXT[picks[4] as number],
    endingQuestion: FIELD_TEXT[picks[5] as number],
    ending: FIELD_TEXT[picks[6] as number],
    firstVolumeGoal: FIELD_TEXT[picks[7] as number],
    nextChapterPlanned: flags[0],
    chapterOneWritten: flags[1],
  };
  const overrides = new Map<string, { status: string; entryId: bigint }>();
  for (let i = rng.int(0, 3); i > 0; i--) overrides.set(rng.chance(0.15) ? 'bogus' : rng.pick(progress.PROGRESS_ITEM_KEYS), { status: rng.pick(['undecided', 'dismissed']), entryId: BigInt(rng.int(1, 99999)) });
  const items = progress.computeProgress(fields, overrides);
  const codes = 'oaud';
  const status = items.map((item: Record<string, unknown>) => codes[['open', 'answered', 'undecided', 'dismissed'].indexOf(item.status as string)]).join('');
  const ids = items.map((item: Record<string, unknown>) => (item.overrideEntryId === undefined ? 0 : Number(item.overrideEntryId)));
  return [picks, flags, [...overrides.entries()].map(([key, value]) => [key, value.status === 'undecided' ? 0 : 1, Number(value.entryId)]), status, ids];
});

const checklist = progress.computeProgress(
  { premise: null, protagonistKey: null, opposition: null, theme: null, readerPromise: null, endingQuestion: null, ending: null, firstVolumeGoal: null, nextChapterPlanned: false, chapterOneWritten: false },
  new Map(),
);

const BRIEFS = [undefined, { staleReason: null }, { staleReason: undefined }, { staleReason: '' }, { staleReason: ' ' }, { staleReason: 'the author replanned' }];

const fromCases = repeat(310, index => {
  const rng = createRng(13000 + index);
  const picks = repeat(7, () => rng.int(0, FIELD_TEXT.length - 1));
  const objectives = repeat(rng.int(0, 3), () => rng.int(0, FIELD_TEXT.length - 1));
  const brief = rng.int(0, BRIEFS.length - 1);
  const chapter = rng.pick([-1, 0, 1, 2, 30]);
  const project = {
    premise: FIELD_TEXT[picks[0] as number],
    protagonistKey: FIELD_TEXT[picks[1] as number],
    opposition: FIELD_TEXT[picks[2] as number],
    theme: FIELD_TEXT[picks[3] as number],
    readerPromise: FIELD_TEXT[picks[4] as number],
    endingQuestion: FIELD_TEXT[picks[5] as number],
    ending: FIELD_TEXT[picks[6] as number],
  };
  const out = progress.progressFieldsFrom(
    project,
    objectives.map(objective => ({ objective: FIELD_TEXT[objective] })),
    { chapter, ...(BRIEFS[brief] === undefined ? {} : { brief: BRIEFS[brief] }) },
  );
  return [picks, objectives, chapter, brief, [out.firstVolumeGoal === undefined ? null : out.firstVolumeGoal, out.nextChapterPlanned, out.chapterOneWritten]];
});

write('progress.json', {
  fieldTexts: FIELD_TEXT.map(value => (value === undefined ? null : value)),
  topics: topicCases,
  payloads: PAYLOADS,
  entryKinds: ENTRY_KINDS,
  topicPool: TOPICS,
  overrides: overrideCases,
  compute: computeCases,
  from: fromCases,
  checklist: checklist.map((item: Record<string, unknown>) => [item.key, item.label, item.why]),
  itemKeys: progress.PROGRESS_ITEM_KEYS,
});

// content hashes
function shuffleDeep(rng: Rng, value: unknown): unknown {
  if (Array.isArray(value)) return value.map(item => shuffleDeep(rng, item));
  if (value === null || typeof value !== 'object') return value;
  return Object.fromEntries(rng.shuffle(Object.entries(value as Record<string, unknown>)).map(([key, item]) => [key, shuffleDeep(rng, item)]));
}

const NFD = (value: string): string => value.normalize('NFD');

const SHORT = ['a', 'b', 'é', 'é', 'x y', ' ', '', 'Z'];
const short = (rng: Rng): string => rng.pick(SHORT);

function subset(rng: Rng, record: Record<string, unknown>, keep: number): Record<string, unknown> {
  const names = rng.shuffle(Object.keys(record)).slice(0, keep);
  return Object.fromEntries(Object.entries(record).filter(([key]) => names.includes(key)));
}

function volumeRecord(rng: Rng): Record<string, unknown> {
  const full: Record<string, unknown> = { volumeKey: `v${rng.int(1, 4)}`, ordinal: rng.int(0, 5), title: short(rng), objective: rng.chance(0.3) ? null : short(rng), body: rng.chance(0.3) ? null : short(rng), state: rng.pick(['not_started', 'active', 'goal_met', null]), revision: rng.int(1, 9) };
  return subset(rng, full, rng.int(2, 5));
}

function briefRecord(rng: Rng): Record<string, unknown> {
  const full: Record<string, unknown> = {
    chapter: rng.int(1, 9),
    volumeKey: rng.chance(0.3) ? null : `v${rng.int(1, 3)}`,
    title: short(rng),
    body: short(rng),
    contextRefs: repeat(rng.int(0, 2), () => short(rng)),
    pov: rng.chance(0.4) ? null : short(rng),
    endingContract: rng.chance(0.5) ? { m: short(rng), '10': 1, '2': [1, { b: 1, a: 2 }] } : {},
    knowledgeContract: rng.chance(0.5) ? null : { learns: repeat(rng.int(0, 2), () => short(rng)), y: 2, z: 1 },
    chapterPurpose: short(rng),
    readerValue: repeat(rng.int(0, 2), () => short(rng)),
    repetitionRisks: rng.chance(0.5) ? null : repeat(rng.int(0, 2), () => short(rng)),
    guidance: rng.chance(0.4) ? null : short(rng),
    direction: rng.pick([null, 'd']),
    contentMode: rng.pick([null, 'unrestricted']),
    scenes: rng.pick([null, [], [{ summary: short(rng), pov: null }]]),
    claimedMilestones: rng.pick([null, ['m1']]),
    isEnding: rng.chance(0.2),
    updatedAt: 'u',
  };
  return subset(rng, full, rng.int(2, 5));
}

const BRIEF_PLAN_DEFAULTS: Record<string, unknown> = { direction: null, contentMode: null, scenes: null, claimedMilestones: null, isEnding: false };

function mutateRecord(rng: Rng, record: Record<string, unknown>, fields: string[], defaults: Record<string, unknown>): Record<string, unknown> {
  const copy = { ...record };
  const strategy = rng.int(0, 11);
  const field = rng.pick(fields);
  switch (strategy) {
    case 0:
      return copy;
    case 1:
      return { ...(shuffleDeep(rng, copy) as Record<string, unknown>), extraIgnored: rng.int(0, 9) };
    case 2:
      copy.updatedAt = 'changed';
      copy.revision = 99;
      return copy;
    case 3:
      if (copy[field] === null) delete copy[field];
      else if (!(field in copy)) copy[field] = null;
      return copy;
    case 4: {
      const key = rng.pick(Object.keys(defaults));
      if (key in copy) delete copy[key];
      else copy[key] = defaults[key];
      return copy;
    }
    case 5: {
      const key = rng.pick(Object.keys(defaults));
      copy[key] = null;
      return copy;
    }
    case 6:
      if (typeof copy[field] === 'string') copy[field] = NFD(copy[field] as string);
      else copy[field] = 'changed';
      return copy;
    case 7:
      copy[field] = typeof copy[field] === 'string' ? copy[field] + ' ' : 'changed';
      return copy;
    case 8:
      copy[field] = typeof copy[field] === 'string' ? (copy[field] as string).toUpperCase() : 12345;
      return copy;
    case 9:
      copy[field] = copy[field] === '' ? null : '';
      return copy;
    case 10: {
      const key = rng.pick(Object.keys(defaults));
      copy[key] = key === 'isEnding' ? true : key === 'state' ? 'active' : key === 'scenes' ? [] : 'x';
      return copy;
    }
    default:
      return rng.chance(0.5) ? { ...copy, [field]: Array.isArray(copy[field]) ? [...(copy[field] as unknown[])].reverse() : null } : copy;
  }
}

const ALIAS_NAMES = ['volumeKey', 'ordinal', 'title', 'objective', 'body', 'state', 'revision', 'chapter', 'contextRefs', 'pov', 'endingContract', 'knowledgeContract', 'chapterPurpose', 'readerValue', 'repetitionRisks', 'guidance', 'direction', 'contentMode', 'scenes', 'claimedMilestones', 'isEnding', 'updatedAt', 'extraIgnored'];
const ALIASES = 'ABCDEFGHIJKLMNOPQRSTUVW';

function aliased(record: Record<string, unknown>): string {
  return JSON.stringify(Object.fromEntries(Object.entries(record).map(([key, value]) => [ALIASES[ALIAS_NAMES.indexOf(key)] ?? key, value])));
}

function recordPairs(kind: 'volume' | 'brief', seed: number, count: number) {
  const hash = kind === 'volume' ? contentHash.volumeContentHash : contentHash.briefContentHash;
  const fields = kind === 'volume' ? ['volumeKey', 'ordinal', 'title', 'objective', 'body'] : ['chapter', 'title', 'body', 'pov', 'guidance', 'contextRefs', 'endingContract', 'knowledgeContract', 'readerValue'];
  const defaults = kind === 'volume' ? { state: 'not_started' } : BRIEF_PLAN_DEFAULTS;
  return repeat(count, index => {
    const rng = createRng(seed + index);
    const a = kind === 'volume' ? volumeRecord(rng) : briefRecord(rng);
    const b = mutateRecord(rng, a, fields, defaults);
    return [aliased(a), aliased(b), hash(a) === hash(b) ? 1 : 0];
  });
}

const RAW_RECORD_PAIRS: [string, string][] = [
  ['{"volumeKey":"v1","ordinal":1}', '{"ordinal":1.0,"volumeKey":"v1"}'],
  ['{"volumeKey":"v1","ordinal":1}', '{"ordinal":1e0,"volumeKey":"v1"}'],
  ['{"volumeKey":"v1","ordinal":1}', '{"volumeKey":"v1","ordinal":1,"ordinal":2}'],
  ['{"volumeKey":"v1","ordinal":2}', '{"volumeKey":"v1","ordinal":1,"ordinal":2}'],
  ['{"volumeKey":"v1","title":"\\u00e9"}', '{"volumeKey":"v1","title":"é"}'],
  ['{"volumeKey":"v1","title":"é"}', '{"volumeKey":"v1","title":"e\\u0301"}'],
  ['{"volumeKey":"v1","ordinal":9007199254740992}', '{"volumeKey":"v1","ordinal":9007199254740993}'],
  ['{"volumeKey":"v1"}', '{"volumeKey":"v1","volume\\u212aey":"other"}'],
  ['{"volumeKey":"v1"}', '{"volume\\u212aey":"v1"}'],
  ['{"volumeKey":"v1","ordinal":0}', '{"volumeKey":"v1","ordinal":-0}'],
  ['{"volumeKey":"v1","ordinal":0.5}', '{"volumeKey":"v1","ordinal":0.50}'],
  ['{"volumeKey":"v1","state":"not_started"}', '{"volumeKey":"v1","state":"not_started "}'],
  ['{"volumeKey":"v1","state":"not_started"}', '{"volumeKey":"v1","state":"Not_started"}'],
  ['{}', '{"volumeKey":null}'],
  ['{"chapter":1,"endingContract":{"a":1,"b":2}}', '{"chapter":1,"endingContract":{"b":2,"a":1}}'],
  ['{"chapter":1,"endingContract":{"10":1,"2":2}}', '{"chapter":1,"endingContract":{"2":2,"10":1}}'],
  ['{"chapter":1,"scenes":[]}', '{"chapter":1}'],
  ['{"chapter":1,"scenes":[{"summary":"a"}]}', '{"chapter":1,"scenes":[{"summary":"a","pov":null}]}'],
  ['{"chapter":1,"isEnding":false}', '{"chapter":1,"isEnding":0}'],
  ['{"chapter":1,"isEnding":false}', '{"chapter":1,"isEnding":null}'],
  ['{"chapter":1,"direction":""}', '{"chapter":1}'],
];

const rawRecordCases = RAW_RECORD_PAIRS.flatMap(([a, b]) =>
  (['volume', 'brief'] as const).map(kind => {
    const hash = kind === 'volume' ? contentHash.volumeContentHash : contentHash.briefContentHash;
    return [kind === 'volume' ? 0 : 1, a, b, hash(JSON.parse(a)) === hash(JSON.parse(b)) ? 1 : 0];
  }),
);

const RAW_DOC_PAIRS: [string | null, string | null, string | null, string | null][] = [
  ['{"title":"Promise","status":"draft"}', '"body"', '{"status":"draft","title":"Promise"}', '"body"'],
  ['{"title":"Promise","status":"draft"}', '"body"', '{"title":"Promise","status":"draft"}', '"body"'],
  [null, '"body"', null, '"body"'],
  [null, null, null, null],
  ['null', '"b"', null, '"b"'],
  ['{}', '"b"', null, '"b"'],
  ['{"b":1,"1":2}', '"x"', '{"1":2,"b":1}', '"x"'],
  ['{"b":1,"a":2}', '"x"', '{"a":2,"b":1}', '"x"'],
  ['{"10":1,"9":2}', '"x"', '{"9":2,"10":1}', '"x"'],
  ['{"a":1,"a":2}', '"x"', '{"a":2}', '"x"'],
  ['{"a":1,"b":2,"a":3}', '"x"', '{"a":3,"b":2}', '"x"'],
  ['{"a":1,"b":2,"a":3}', '"x"', '{"b":2,"a":3}', '"x"'],
  ['{"n":1}', '"x"', '{"n":1.0}', '"x"'],
  ['{"n":1}', '"x"', '{"n":1e0}', '"x"'],
  ['{"n":0}', '"x"', '{"n":-0}', '"x"'],
  ['{"n":0.1}', '"x"', '{"n":1e-1}', '"x"'],
  ['{"n":1e21}', '"x"', '{"n":1000000000000000000000}', '"x"'],
  ['{"n":1e400}', '"x"', '{"n":null}', '"x"'],
  ['{"é":1}', '"x"', '{"e\\u0301":1}', '"x"'],
  ['{"a":"é"}', '"x"', '{"a":"\\u00e9"}', '"x"'],
  ['{"a":"é"}', '"x"', '{"a":"e\\u0301"}', '"x"'],
  ['{"a":"\\u2028"}', '"x"', '{"a":" "}', '"x"'],
  ['{"a":"\\/"}', '"x"', '{"a":"/"}', '"x"'],
  ['{"a":"\\u001f"}', '"x"', '{"a":"\\u001F"}', '"x"'],
  ['{"a":"x"}', '"é"', '{"a":"x"}', '"e\\u0301"'],
  ['{"a":"x"}', '"b"', '{"a":"x"}', '"b "'],
  ['{"a":[1,2]}', '"b"', '{"a":[2,1]}', '"b"'],
  ['{"a":{"x":1,"y":2}}', '"b"', '{"a":{"y":2,"x":1}}', '"b"'],
  ['{"a":1}', '1', '{"a":1}', '"1"'],
  ['{"a":1}', '[]', '{"a":1}', null],
  ['{"a":1}', '{"k":1,"j":2}', '{"a":1}', '{"j":2,"k":1}'],
];

function docPair(frontA: string | null, bodyA: string | null, frontB: string | null, bodyB: string | null) {
  const parse = (value: string | null): unknown => (value === null ? undefined : JSON.parse(value));
  return [frontA, bodyA, frontB, bodyB, contentHash.computeBibleDocHash(parse(frontA), parse(bodyA)) === contentHash.computeBibleDocHash(parse(frontB), parse(bodyB)) ? 1 : 0];
}

function docJson(rng: Rng): string {
  const entries = repeat(rng.int(0, 4), () => [rng.pick(['title', 'status', 'tags', 'a', 'b', '1', '10', '2', 'é', 'é']), rng.pick([1, 'x', true, null, [1, 2], { k: 'v', j: 1 }, short(rng)])] as const);
  return JSON.stringify(Object.fromEntries(entries));
}

const docCases = [
  ...RAW_DOC_PAIRS.map(([fa, ba, fb, bb]) => docPair(fa, ba, fb, bb)),
  ...repeat(272, index => {
    const rng = createRng(16000 + index);
    const front = rng.chance(0.15) ? null : docJson(rng);
    const body = rng.chance(0.15) ? null : JSON.stringify(short(rng));
    const strategy = rng.int(0, 4);
    const parsed = front === null ? null : (JSON.parse(front) as Record<string, unknown>);
    if (strategy === 0) return docPair(front, body, front, body);
    if (strategy === 1 && parsed) return docPair(front, body, JSON.stringify(Object.fromEntries(rng.shuffle(Object.entries(parsed)))), body);
    if (strategy === 2) return docPair(front, body, front, body === null ? JSON.stringify(short(rng)) : JSON.stringify(NFD(JSON.parse(body) as string)));
    if (strategy === 3) return docPair(front, body, docJson(rng), body);
    return docPair(front, body, front, body === null ? null : JSON.stringify((JSON.parse(body) as string) + ' '));
  }),
];

function generic(rng: Rng, depth: number): unknown {
  const roll = rng.int(0, depth > 0 ? 7 : 4);
  if (roll === 0) return short(rng);
  if (roll === 1) return rng.pick([0, 1, -5, 42, 9007199254740993, 1e21]);
  if (roll === 2) return rng.chance(0.5);
  if (roll === 3) return null;
  if (roll === 4) return rng.pick([0.5, 1.25, -2.5, 1e-7]);
  if (roll === 5 || roll === 6) return repeat(rng.int(0, 3), () => generic(rng, depth - 1));
  return Object.fromEntries(repeat(rng.int(0, 4), () => [rng.pick(['a', 'b', 'c', '1', '10', '2', 'é', 'é', 'Z', 'z', '😀', '￿']), generic(rng, depth - 1)] as const));
}

function leafChange(rng: Rng, value: unknown): unknown {
  if (Array.isArray(value)) return value.length > 0 && rng.chance(0.7) ? value.map((item, i) => (i === 0 ? leafChange(rng, item) : item)) : [...value, 'extra'];
  if (value !== null && typeof value === 'object') {
    const entries = Object.entries(value as Record<string, unknown>);
    if (entries.length === 0) return { added: 1 };
    const [first, ...rest] = entries as [[string, unknown], ...[string, unknown][]];
    return Object.fromEntries([[first[0], leafChange(rng, first[1])], ...rest]);
  }
  if (typeof value === 'string') return rng.chance(0.5) ? value + ' ' : NFD(value) === value ? value + 'x' : NFD(value);
  if (typeof value === 'number') return value + 1;
  if (typeof value === 'boolean') return !value;
  return 0;
}

const computeHashCases = repeat(302, index => {
  const rng = createRng(17000 + index);
  const a = Object.fromEntries(repeat(rng.int(0, 4), () => [rng.pick(['k1', 'k2', 'x', '3', '20', 'é', 'é', 'Z']), generic(rng, 2)] as const));
  const strategy = rng.int(0, 3);
  const b = strategy === 0 ? a : strategy === 1 ? shuffleDeep(rng, a) : strategy === 2 ? leafChange(rng, a) : { ...a, extra: null };
  return [JSON.stringify(a), JSON.stringify(b), contentHash.computeContentHash(a) === contentHash.computeContentHash(b as Record<string, unknown>) ? 1 : 0];
});

write('hash.json', {
  aliasNames: ALIAS_NAMES,
  aliases: ALIASES,
  volume: recordPairs('volume', 14000, 302),
  brief: recordPairs('brief', 15000, 302),
  raw: rawRecordCases,
  doc: docCases,
  content: computeHashCases,
});

// brief scenes
const SUMMARIES = ['"a scene"', '""', '" "', '"\\u00a0"', '"\\ufeff"', '"\\u0085"', '"\\u200b"', '"\\t\\n"', '"é"', '1', 'null', 'true', '[]', '{}', '"x"'];
const POVS = ['"mira"', 'null', '""', '" "', '"\\u00a0"', '1', 'true', '[]', '{"a":1}', '"é"', '"\\u0085"'];
const TEXTS = ['"goal text"', '""', '" "', 'null', '1', 'true', '[]', '{}'];
const BEATS = ['["a","b"]', '[]', '[""]', '["a",1]', '[null]', '"a"', 'null', '{}', '[["a"]]', '1', '[" "]'];
const WORDS_VALUES = ['1', '5', '0', '-3', '1.5', '1e2', '1.0', '"5"', 'null', 'true', '1e400', '9007199254740993', '1e21', '-0', '0.5', '[]', '2.0e0', '0.1e1', '100000000000000000000000'];
const EXTRA_KEYS = ['mood', 'extra', '1', '0', '10', '2', '4294967295', '4294967294', '__proto__', 'é', 'é', "it's", 'q"t', '', 'Summary', 'POV', 'constructor', '😀', 'a b'];
const OTHER = ['null', '1', '"s"', 'true', '[]', '[1]', '{}', '"scene"', '-1.5'];

function keyText(key: string): string {
  return JSON.stringify(key);
}

function sceneText(rng: Rng): string {
  if (rng.chance(0.12)) return rng.pick(OTHER);
  const members: [string, string][] = [];
  const add = (key: string, values: string[], p: number): void => {
    if (rng.chance(p)) members.push([key, rng.pick(values)]);
  };
  add('summary', rng.chance(0.7) ? ['"a scene"', '"b"'] : SUMMARIES, 0.9);
  add('pov', rng.chance(0.6) ? ['"mira"', 'null'] : POVS, 0.5);
  add('goal', rng.chance(0.6) ? ['"g"'] : TEXTS, 0.3);
  add('obstacle', rng.chance(0.6) ? ['"o"'] : TEXTS, 0.3);
  add('turn', rng.chance(0.6) ? ['"t"'] : TEXTS, 0.3);
  add('beats', rng.chance(0.6) ? ['["a"]'] : BEATS, 0.3);
  add('estimatedWords', rng.chance(0.6) ? ['120', '1'] : WORDS_VALUES, 0.4);
  for (let i = rng.int(0, 3); i > 0 && rng.chance(0.5); i--) members.push([rng.pick(EXTRA_KEYS), rng.pick(OTHER)]);
  if (rng.chance(0.1) && members.length > 0) members.push(rng.pick(members));
  const ordered = rng.chance(0.5) ? members : rng.shuffle(members);
  return '{' + ordered.map(([key, value]) => keyText(key) + ':' + value).join(',') + '}';
}

const sceneCases = repeat(320, index => {
  const rng = createRng(18000 + index);
  const input = rng.chance(0.1) ? rng.pick(OTHER.concat(['{"summary":"a"}', '"scenes"'])) : '[' + repeat(rng.int(0, 3), () => sceneText(rng)).join(',') + ']';
  return [input, briefScenes.validateBriefScenes(JSON.parse(input))];
});

const listCases = repeat(305, index => {
  const rng = createRng(19000 + index);
  const values = repeat(rng.int(0, 6), () => (rng.chance(0.25) ? rng.pick(BLANKS) : short(rng)));
  if (values.length > 0 && rng.chance(0.4)) values.push(rng.pick(values));
  return [values, briefScenes.normalizeStringList(values)];
});

const normalizeCases = repeat(305, index => {
  const rng = createRng(20000 + index);
  const scenes = repeat(rng.int(0, 2), () => {
    const scene: Record<string, unknown> = { summary: short(rng) };
    if (rng.chance(0.7)) scene.pov = rng.chance(0.2) ? null : short(rng);
    for (const field of ['goal', 'obstacle', 'turn']) if (rng.chance(0.25)) scene[field] = short(rng);
    if (rng.chance(0.4)) scene.beats = repeat(rng.int(0, 3), () => short(rng));
    if (rng.chance(0.4)) scene.estimatedWords = rng.pick([0, 1, 5, 120, -4]);
    return scene;
  });
  return [scenes, briefScenes.normalizeBriefScenes(scenes)];
});

write('scenes.json', { validate: sceneCases, stringList: listCases, normalize: normalizeCases });

// bible manifest
const SECTIONS = ['project', 'world', 'power', 'plot', 'story_state', 'ai', 'lore'];
const SLUGS = [...manifest.BIBLE_MANIFEST.map((chapter: { slug: string }) => chapter.slug), 'supers-and-rifts', 'reader-promise', 'foundation', 'anything', '', 'Cast', 'cast', 'premise ', 'system-and-limits'];
const manifestPairs = repeat(320, index => {
  const rng = createRng(21000 + index);
  const section = rng.chance(0.85) ? rng.pick(SECTIONS) : rng.pick(['', 'Project', 'lore ', 'project/premise', 'wörld', 'power', 'story-state']);
  const slug = rng.chance(0.5) ? (rng.pick(manifest.BIBLE_MANIFEST) as { slug: string }).slug : rng.pick(SLUGS);
  return {
    section,
    slug,
    stage: manifest.chapterAt(section, slug)?.stage ?? null,
    required: manifest.requiredEntityTypesForSlug(section, slug),
  };
});

write('manifest.json', {
  stageOrder: manifest.BIBLE_STAGE_ORDER,
  chapters: manifest.BIBLE_MANIFEST,
  legacy: manifest.LEGACY_CHAPTER_SLUGS,
  rendered: manifest.renderManifest(),
  sectionTypes: [...SECTIONS, '', 'Project', 'lore ', 'project/premise', 'wörld', 'pow\u0065r', 'story-state', 'worl\u0064'].map(section => ({
    section,
    types: manifest.entityTypesForSection(section),
    bearing: manifest.isEntityBearingSection(section),
  })),
  cases: manifestPairs.map(entry => [entry.section, entry.slug, entry.stage, entry.required]),
});

// ledger successor
const KINDS = ['decision', 'direction', 'rejected', 'backlog', 'system'];
const SCOPES = ['never', 'not_now', 'not_this_version'];
const LTEXT = ['a', 'b', 'é', 'é', ' x ', '', '  ', ' y'];
const ltext = (rng: Rng): string => rng.pick(LTEXT);

const ledgerCases = repeat(302, index => {
  const rng = createRng(22000 + index);
  const rejected = rng.chance(0.4);
  const previous: Record<string, unknown> = { kind: rejected ? 'rejected' : rng.pick(KINDS), rejectedAlternatives: repeat(rng.int(0, 1), () => ltext(rng)), links: rng.chance(0.5) ? {} : { entityKeys: ['k'] } };
  if (rng.chance(0.6)) previous.why = ltext(rng);
  if (rng.chance(0.5)) previous.writerLine = ltext(rng);
  if (rng.chance(0.5)) previous.payload = { n: rng.int(0, 3) };
  if (rng.chance(0.4)) previous.stepKey = 'organise';
  if (rejected && rng.chance(0.7)) previous.ideaId = 'abc';
  if (rejected && rng.chance(0.7)) previous.rejectionScope = rng.pick(SCOPES);
  if (rejected && rng.chance(0.5)) previous.rejectionAnchor = rng.pick([{ volumeKey: 'volume_1' }, { states: {} }]);
  const input: Record<string, unknown> = { statement: ltext(rng) };
  if (rng.chance(0.55)) input.kind = rng.pick(['decision', 'direction', 'rejected', 'backlog']);
  if (rng.chance(0.5)) input.why = ltext(rng);
  if (rng.chance(0.5)) input.writerLine = ltext(rng);
  if (rng.chance(0.3)) input.rejectedAlternatives = repeat(rng.int(0, 2), () => ltext(rng));
  if (rng.chance(0.3)) input.payload = { replaced: true };
  else if (rng.chance(0.15)) input.payload = null;
  let out: Record<string, unknown>;
  try {
    const result = ledger.authorSuccessor({ why: null, writerLine: null, payload: null, stepKey: null, ideaId: null, rejectionScope: null, rejectionAnchor: null, ...previous }, input);
    out = { kind: result.kind, why: result.why, writerLine: result.writerLine, ra: result.rejectedAlternatives, payload: result.payload, links: result.links, stepKey: result.stepKey, idea: result.idea };
    for (const key of Object.keys(out)) if (out[key] === null || out[key] === undefined) delete out[key];
  } catch (error) {
    out = { error: (error as { code: string }).code };
  }
  return [previous, input, out];
});

const statusCases = [
  [false, null],
  [true, null],
  [true, 'Dropped'],
  [false, 'Dropped'],
  [true, ''],
].map(([superseded, reason]) => [superseded, reason, ledger.ledgerEntryStatus({ supersededAt: superseded ? new Date(1) : null, withdrawnReason: reason })]);

const ledgerMessage = (() => {
  try {
    ledger.authorSuccessor({ kind: 'direction' }, { kind: 'decision', statement: 'x' });
  } catch (error) {
    return (error as Error).message;
  }
  return null;
})();

write('ledger.json', { successor: ledgerCases, status: statusCases, message: ledgerMessage });

// vocabularies
write('vocab.json', {
  hookTypes: hookEnums.HOOK_TYPES,
  briefWriteModes: opSpecs.BRIEF_WRITE_MODES,
  contentModes: opSpecs.CONTENT_MODES,
  bibleSections: opSpecs.BIBLE_SECTIONS,
  entityTypes: opSpecs.ENTITY_TYPES,
  milestoneKinds: opSpecs.MILESTONE_KINDS,
  promiseKinds: opSpecs.PROMISE_KINDS,
  promiseStatuses: opSpecs.PROMISE_STATUSES,
  validationScopes: opSpecs.VALIDATION_SCOPES,
  volumeStates: enumSchemas.plan.volumeState.enumValues,
  threadStatuses: enumSchemas.story.threadStatus.enumValues,
  mysteryStatuses: enumSchemas.story.mysteryStatus.enumValues,
  milestoneStates: enumSchemas.knowledge.milestoneState.enumValues,
  ledgerKinds: enumSchemas.ledger.ledgerEntryKind.enumValues,
  ledgerDecidedBy: enumSchemas.ledger.ledgerDecidedBy.enumValues,
  ledgerRejectionScopes: enumSchemas.ledger.ledgerRejectionScope.enumValues,
  authorSupersedeKinds: ledgerTypes.AUTHOR_SUPERSEDE_KINDS,
  promiseStatusUnion: [...new Set([...enumSchemas.story.threadStatus.enumValues, ...enumSchemas.story.mysteryStatus.enumValues])],
  dbBibleSections: enumSchemas.bible.bibleSection.enumValues,
  dbEntityTypes: enumSchemas.knowledge.entityType.enumValues,
  dbMilestoneKinds: enumSchemas.knowledge.milestoneKind.enumValues,
  dbBriefWriteModes: enumSchemas.generation.briefWriteMode.enumValues,
});
process.exit(0);
