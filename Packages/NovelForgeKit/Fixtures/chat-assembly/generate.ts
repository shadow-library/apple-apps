import { plugin } from 'bun';
import { readdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// Run as: PLATFORM_REPO=<checkout> bun --tsconfig-override "$PLATFORM_REPO/apps/novel-forge-server/tsconfig.json" generate.ts
// Each scenario is a vault state the Swift test builds through typed records; the expected pack is the reference's forNovelChat over a fake database holding the same state.
const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');

const server = join(platformRepo, 'apps/novel-forge-server/src');
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

// The native token estimate (TokenBudget.swift), in place of o200k_base.
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

// The record states a not_this_version rejection is judged against: the scenario says which anchored record changed since.
const ANCHORED = 'anchored';
const EDITED = 'edited';
const changedRefs = new Set<string>();

plugin({
  name: 'chat-assembly-fixture-stubs',
  setup(build) {
    build.module('@server/common', () => ({ exports: commonExports, loader: 'object' }));
    build.module('@server/classes', () => ({ exports: { AppErrorCode: classes.AppErrorCode }, loader: 'object' }));
    build.module('js-tiktoken', () => ({ exports: { getEncoding: () => ({ encode: (text: string) => ({ length: estimateTokens(text) }) }) }, loader: 'object' }));
    build.onLoad({ filter: /modules\/refinement\/artifact-state\.ts$/ }, () => ({
      contents: `export const MISSING_ARTIFACT = { exists: false, revision: null, contentHash: null };
export async function loadArtifactStates(db, projectId, refs) { return Object.fromEntries(refs.map((ref) => [ref, globalThis.chatAssemblyState(ref)])); }
export async function loadCurrentRecords() { return new Map(); }`,
      loader: 'js',
    }));
  },
});
(globalThis as any).chatAssemblyState = (ref: string) => ({ exists: true, revision: null, contentHash: changedRefs.has(ref) ? EDITED : ANCHORED });

const contextDir = join(server, 'modules/ai/context');
const assemblerModule = await import(join(contextDir, 'context-assembler.service.ts'));
const exchange = await import(join(server, 'modules/refinement/chat-exchange.ts'));
const schemas = await import(join(server, 'database/schemas/index.ts'));

function createRng(seed: number): () => number {
  let state = seed | 0;
  return () => {
    state = (state + 0x6d2b79f5) | 0;
    let t = Math.imul(state ^ (state >>> 15), 1 | state);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const random = createRng(20261117);
const int = (min: number, max: number): number => min + Math.floor(random() * (max - min + 1));
const pick = <T>(items: readonly T[]): T => items[Math.floor(random() * items.length)] as T;
const WORDS = ('the a of and to in he she it was had that with for on as at by from his her they there then when what which who would could '
  + 'lighthouse keeper stairs window grey sea sky morning lantern harbour captain letter promise winter river bridge silence shadow memory garden '
  + 'walked climbed whispered remembered carried opened closed turned waited listened wondered believed forgot answered followed slowly quietly').split(' ');
const ODD = ['Élodie', 'naïve café', '😀', '𠮷野家', 'é', '日本語の文章', ' '];
const words = (count: number): string => Array.from({ length: count }, () => pick(WORDS)).join(' ');
const sentence = (count = int(4, 12)): string => {
  const text = words(count);
  return `${text.charAt(0).toUpperCase()}${text.slice(1)}${pick(['.', '.', '!', '?'])}`;
};
const paragraph = (sentences = int(1, 3)): string => Array.from({ length: sentences }, () => sentence()).join(' ');
const prose = (paragraphs: number, separator = '\n\n'): string => Array.from({ length: paragraphs }, () => paragraph()).join(separator);
const odd = (text: string): string => `${text} ${pick(ODD)}`;

// What the Swift test writes; field names follow the native records.
interface Spec {
  name: string;
  promptTokens: number;
  requestTokens: number;
  novel: null | { title: string | null; premise: string | null; brief: string | null; themes: string[] | null; theme: string | null; endingQuestion: string | null; ending: string | null; readerPromise: string | null; protagonist: string | null; opposition: string | null; writingStyle: string | null };
  notes: string | null;
  ledger: { kind: string; topic: string; statement: string; why: string | null; rejectedAlternatives: string[]; writerLine: string | null; decidedBy: string; idea: string | null; scope: string | null; anchorVolume: string | null; anchorRef: string | null; anchorChanged: boolean; progressStatus: string | null }[];
  volumes: { key: string; ordinal: number; title: string | null; objective: string | null; goalMet: boolean; editedAfter: boolean }[];
  threads: { key: string; summary: string | null; openedChapter: number | null; status: string; payoffWindow: number | null; payoffMilestone: string | null; payoffVolume: string | null; dormant: boolean }[];
  mysteries: { key: string; question: string; openedChapter: number | null; status: string; payoffWindow: number | null; payoffMilestone: string | null; payoffVolume: string | null; dormant: boolean }[];
  entities: { key: string; name: string; type: string; major: boolean }[];
  pages: { section: string; slug: string; title: string | null; body: string; revisions: number; editedAfter: boolean }[];
  secrets: string[];
  milestones: { key: string; label: string }[];
  finals: { chapter: number; title: string | null; summary: string | null; body: string; isolated: boolean; disclosed: string[]; viaDraft: boolean }[];
  drafts: { chapter: number; title: string | null; summary: string | null; body: string; isolated: boolean }[];
  plans: { chapter: number; title: string | null; body: string; chapterPurpose: string | null; direction: string | null; pov: string | null; scenes: { summary: string; pov: string | null }[]; ending: null | { hookType: string; emotionalBeat: string; openQuestion: string; handoffState: string }; contentMode: string | null; isEnding: boolean; guidance: string | null; writeMode: string; revisions: number; editedAfter: boolean }[];
  pendingProposals: number;
}

const entry = (fields: Partial<Spec['ledger'][number]> & { kind: string; topic: string; statement: string }): Spec['ledger'][number] => ({
  why: null, rejectedAlternatives: [], writerLine: null, decidedBy: 'author', idea: null, scope: null, anchorVolume: null, anchorRef: null, anchorChanged: false, progressStatus: null, ...fields,
});
const rejection = (idea: string, scope: string, extra: Partial<Spec['ledger'][number]> = {}): Spec['ledger'][number] =>
  entry({ kind: 'rejected', topic: `idea.${idea}`, statement: odd(sentence()), idea, scope, ...extra });
const novel = (overrides: Partial<NonNullable<Spec['novel']>> = {}): NonNullable<Spec['novel']> => ({
  title: words(3), premise: prose(2), brief: null, themes: ['loss', 'duty'], theme: sentence(), endingQuestion: sentence(), ending: null, readerPromise: sentence(),
  protagonist: 'mara', opposition: sentence(), writingStyle: null, ...overrides,
});
const plan = (chapter: number, overrides: Partial<Spec['plans'][number]> = {}): Spec['plans'][number] => ({
  chapter, title: words(3), body: paragraph(), chapterPurpose: sentence(), direction: null, pov: 'mara', scenes: [{ summary: sentence(), pov: 'mara' }, { summary: odd(sentence()), pov: null }],
  ending: { hookType: 'cliffhanger', emotionalBeat: words(2), openQuestion: sentence(), handoffState: sentence() }, contentMode: null, isEnding: false, guidance: null, writeMode: 'standard',
  revisions: 1, editedAfter: false, ...overrides,
});
const final = (chapter: number, overrides: Partial<Spec['finals'][number]> = {}): Spec['finals'][number] => ({
  chapter, title: words(3), summary: sentence(), body: prose(3), isolated: false, disclosed: [], viaDraft: false, ...overrides,
});
const thread = (key: string, overrides: Partial<Spec['threads'][number]> = {}): Spec['threads'][number] => ({
  key, summary: sentence(), openedChapter: int(1, 3), status: 'open', payoffWindow: null, payoffMilestone: null, payoffVolume: null, dormant: false, ...overrides,
});
const empty = (name: string, promptTokens = 3000, requestTokens = 400): Spec => ({
  name, promptTokens, requestTokens, novel: null, notes: null, ledger: [], volumes: [], threads: [], mysteries: [], entities: [], pages: [], secrets: [], milestones: [],
  finals: [], drafts: [], plans: [], pendingProposals: 0,
});

const specs: Spec[] = [];

specs.push({
  ...empty('no story'),
  ledger: [entry({ kind: 'decision', topic: 'voice.tone', statement: sentence(), why: sentence() }), entry({ kind: 'backlog', topic: 'later', statement: odd(sentence()) })],
  volumes: [{ key: 'v1', ordinal: 1, title: null, objective: sentence(), goalMet: false, editedAfter: false }],
  plans: [plan(1)],
});

specs.push({
  ...empty('notebook with lapsed rejections', 9000, 1200),
  novel: novel({ writingStyle: `Keep it close.\n\n${sentence()}` }),
  notes: `${prose(2)}\r\n\r\n${odd(paragraph())}`,
  ledger: [
    ...Array.from({ length: 30 }, (_, index) => entry({
      kind: index % 3 === 0 ? 'direction' : 'decision', topic: `topic.${index}`, statement: index % 7 === 0 ? odd(paragraph()) : sentence(),
      why: index % 2 === 0 ? sentence() : null, writerLine: index % 5 === 0 ? sentence() : null, rejectedAlternatives: index % 4 === 0 ? [words(3)] : [],
      decidedBy: index % 6 === 5 ? 'system' : 'author',
    })),
    rejection('never-idea', 'never'),
    rejection('now-idea', 'not_now', { anchorVolume: 'v2' }),
    rejection('then-idea', 'not_now', { anchorVolume: 'v1' }),
    rejection('kept-idea', 'not_this_version', { anchorRef: 'entity:mara', anchorChanged: false }),
    rejection('moved-idea', 'not_this_version', { anchorRef: 'entity:heir', anchorChanged: true }),
    entry({ kind: 'rejected', topic: 'plain', statement: sentence(), why: sentence() }),
    entry({ kind: 'system', topic: 'progress.ending', statement: 'Left undecided for now.', decidedBy: 'system', progressStatus: 'undecided' }),
    entry({ kind: 'backlog', topic: 'later.one', statement: sentence() }),
  ],
  volumes: [
    { key: 'v1', ordinal: 1, title: words(2), objective: sentence(), goalMet: true, editedAfter: false },
    { key: 'v2', ordinal: 2, title: words(2), objective: sentence(), goalMet: false, editedAfter: false },
    { key: 'v3', ordinal: 3, title: null, objective: null, goalMet: false, editedAfter: false },
  ],
  entities: [{ key: 'mara', name: 'Mara', type: 'character', major: true }, { key: 'heir', name: 'The heir', type: 'character', major: false }],
});

specs.push({
  ...empty('isolated latest chapter'),
  novel: novel({ ending: sentence(), brief: sentence(), themes: null }),
  secrets: ['ledger', 'tower'],
  entities: [{ key: 'mara', name: 'Mara', type: 'character', major: true }, { key: 'harbour', name: odd('The harbour'), type: 'place', major: false }],
  pages: [
    { section: 'world', slug: 'harbour', title: 'The Harbour', body: paragraph(), revisions: 1, editedAfter: false },
    { section: 'project', slug: 'timeline', title: null, body: paragraph(), revisions: 2, editedAfter: false },
  ],
  milestones: [{ key: 'rise', label: words(2) }],
  threads: [thread('lantern', { payoffWindow: 2 }), thread('letter', { dormant: true })],
  mysteries: [{ key: 'heir', question: odd(sentence()), openedChapter: 1, status: 'open', payoffWindow: null, payoffMilestone: 'rise', payoffVolume: null, dormant: false }],
  finals: [final(1, { disclosed: ['ledger'] }), final(2), final(3, { isolated: true })],
  plans: [plan(3), plan(4, { revisions: 3 })],
});

specs.push({
  ...empty('pending proposals and changes', 12000, 1500),
  novel: novel(),
  notes: paragraph(),
  volumes: [
    { key: 'v1', ordinal: 1, title: words(2), objective: sentence(), goalMet: false, editedAfter: true },
    { key: 'v2', ordinal: 2, title: words(2), objective: sentence(), goalMet: false, editedAfter: false },
  ],
  threads: [thread('oath', { payoffVolume: 'v1' }), thread('closed-one', { status: 'closed' })],
  pages: [
    { section: 'lore', slug: 'oaths', title: odd('Oaths'), body: paragraph(), revisions: 2, editedAfter: true },
    { section: 'world', slug: 'sea', title: null, body: paragraph(), revisions: 1, editedAfter: false },
  ],
  finals: [final(1, { viaDraft: true }), final(2, { viaDraft: true })],
  drafts: [{ chapter: 3, title: words(2), summary: sentence(), body: prose(4), isolated: false }],
  plans: [plan(3), plan(4, { revisions: 2, editedAfter: true, writeMode: 'external', guidance: sentence(), isEnding: true })],
  pendingProposals: 2,
});

specs.push({
  ...empty('budget pressure', 18000, 2600),
  novel: novel({ premise: prose(30), ending: prose(4), writingStyle: prose(8) }),
  notes: prose(3),
  ledger: Array.from({ length: 36 }, (_, index) => entry({ kind: index % 3 === 0 ? 'direction' : 'decision', topic: `topic.${index}`, statement: prose(2), why: sentence() })),
  volumes: Array.from({ length: 4 }, (_, index) => ({ key: `v${index + 1}`, ordinal: index + 1, title: `Volume ${index + 1}`, objective: prose(5), goalMet: index === 0, editedAfter: false })),
  threads: Array.from({ length: 24 }, (_, index) => thread(`t${String(index).padStart(2, '0')}`, { summary: paragraph(), payoffWindow: index % 3 === 0 ? int(1, 20) : null })),
  entities: Array.from({ length: 50 }, (_, index) => ({ key: `ent-${String(index).padStart(2, '0')}`, name: words(2), type: pick(['character', 'place', 'item']), major: index % 4 === 0 })),
  pages: Array.from({ length: 24 }, (_, index) => ({ section: 'lore', slug: `page-${String(index).padStart(2, '0')}`, title: index % 2 === 0 ? words(2) : null, body: paragraph(), revisions: 1, editedAfter: false })),
  secrets: Array.from({ length: 20 }, (_, index) => `fact-${String(index).padStart(2, '0')}`),
  milestones: Array.from({ length: 12 }, (_, index) => ({ key: `ms-${String(index).padStart(2, '0')}`, label: words(3) })),
  finals: Array.from({ length: 12 }, (_, index) => final(index + 1, { body: index === 11 ? prose(40) : prose(2), summary: paragraph() })),
  plans: [plan(13, { body: prose(12) })],
});

const contiguousFinals = (spec: Spec): number => {
  const finals = new Set(spec.finals.map((row) => row.chapter));
  let chapter = 0;
  while (finals.has(chapter + 1)) chapter += 1;
  return chapter;
};

function volumeStates(spec: Spec): Map<string, string> {
  const ordered = [...spec.volumes].sort((left, right) => left.ordinal - right.ordinal);
  const passed = ordered.reduce((last, volume, index) => (volume.goalMet ? index + 1 : last), 0);
  const active = ordered.findIndex((volume, index) => index >= passed && !volume.goalMet);
  return new Map(ordered.map((volume, index) => [volume.key, volume.goalMet ? 'goal_met' : index === active ? 'active' : 'not_started']));
}

function worldOf(spec: Spec): any {
  const states = volumeStates(spec);
  const disclosedIn = new Map<string, number>();
  for (const row of [...spec.finals].sort((left, right) => left.chapter - right.chapter)) for (const key of row.disclosed) if (!disclosedIn.has(key)) disclosedIn.set(key, row.chapter);
  const finalDrafts = spec.finals.filter((row) => row.viaDraft).map((row) => ({
    chapter: row.chapter, title: row.title, reviewStatus: 'final', summary: row.summary, isolated: row.isolated, staleReason: null, status: 'final', revision: 1, body: row.body, state: null,
  }));
  const drafts = spec.drafts.map((row) => ({ ...row, reviewStatus: 'needs_review', staleReason: null, status: 'draft', revision: 1, state: null }));
  const ledger = [
    ...(spec.notes === null ? [] : [{ kind: 'direction', topic: 'start.brief', statement: spec.notes, why: null, rejectedAlternatives: [], writerLine: null, decidedBy: 'author', ideaId: null, rejectionScope: null, rejectionAnchor: null, payload: null }]),
    ...spec.ledger.map((row) => ({
      kind: row.kind, topic: row.topic, statement: row.statement, why: row.why, rejectedAlternatives: row.rejectedAlternatives, writerLine: row.writerLine, decidedBy: row.decidedBy,
      ideaId: row.idea, rejectionScope: row.scope,
      rejectionAnchor: row.anchorVolume !== null ? { volumeKey: row.anchorVolume } : row.anchorRef !== null ? { states: { [row.anchorRef]: { exists: true, revision: null, contentHash: ANCHORED } } } : null,
      payload: row.progressStatus === null ? null : { status: row.progressStatus },
    })),
  ];
  return {
    project: spec.novel && {
      title: spec.novel.title, premise: spec.novel.premise, brief: spec.novel.brief, themes: spec.novel.themes, theme: spec.novel.theme, endingQuestion: spec.novel.endingQuestion,
      ending: spec.novel.ending, readerPromise: spec.novel.readerPromise, protagonistKey: spec.novel.protagonist, opposition: spec.novel.opposition, instructions: spec.novel.writingStyle,
      storyCurrentChapter: contiguousFinals(spec),
    },
    ledger,
    volumes: [...spec.volumes].sort((left, right) => left.ordinal - right.ordinal).map((row) => ({ volumeKey: row.key, ordinal: row.ordinal, title: row.title, objective: row.objective, state: states.get(row.key) })),
    threads: spec.threads.map((row) => ({ threadKey: row.key, status: row.status, summary: row.summary, openedChapter: row.openedChapter, lastAdvancedChapter: null, payoffWindow: row.payoffWindow, payoffMilestoneKey: row.payoffMilestone, payoffVolumeKey: row.payoffVolume, intentionallyOpen: row.dormant })),
    mysteries: spec.mysteries.map((row) => ({ mysteryKey: row.key, status: row.status, question: row.question, openedChapter: row.openedChapter, lastAdvancedChapter: null, payoffWindow: row.payoffWindow, payoffMilestoneKey: row.payoffMilestone, payoffVolumeKey: row.payoffVolume, intentionallyOpen: row.dormant })),
    entities: spec.entities.map((row) => ({ entityKey: row.key, name: row.name, type: row.type, significance: row.major ? 'major' : 'minor' })),
    pages: spec.pages.map((row) => ({ section: row.section, slug: row.slug, frontmatter: row.title === null ? null : { title: row.title } })),
    facts: spec.secrets.map((key) => ({ factKey: key, disclosedInChapter: disclosedIn.get(key) ?? null })),
    milestones: spec.milestones.map((row) => ({ milestoneKey: row.key, label: row.label, state: 'open' })),
    chapters: spec.finals.map((row) => ({ number: row.chapter, title: row.title, status: 'done', summary: row.summary, isolated: row.isolated, content: row.body })),
    drafts: [...finalDrafts, ...drafts].sort((left, right) => left.chapter - right.chapter),
    briefs: spec.plans.map((row) => ({
      chapter: row.chapter, title: row.title, chapterPurpose: row.chapterPurpose, direction: row.direction, body: row.body, pov: row.pov, scenes: row.scenes, endingContract: row.ending,
      claimedMilestones: [], contentMode: row.contentMode, isEnding: row.isEnding, guidance: row.guidance, revision: row.revisions, staleReason: null, writeMode: row.writeMode,
    })),
    changedVolumes: [...spec.volumes].sort((left, right) => left.ordinal - right.ordinal).filter((row) => row.editedAfter).map((row) => ({ volumeKey: row.key, revision: 'unnumbered' })),
    changedBriefs: spec.plans.filter((row) => row.editedAfter).map((row) => ({ chapter: row.chapter, revision: row.revisions })),
    changedDocs: spec.pages.filter((row) => row.editedAfter).map((row) => ({ section: row.section, slug: row.slug, revision: row.revisions })),
    continuity: [],
    pendingProposals: spec.pendingProposals,
  };
}

const projected = (record: any, columns?: any): any => (columns ? Object.fromEntries(Object.keys(columns).map((name) => [name, record[name] ?? null])) : record);

function makeDb(world: any): any {
  const pending = ['planned', 'stale'];
  const latest = commonExports.firstUnwrittenChapter(new Set(world.drafts.map((draft: any) => draft.chapter)), new Set(world.chapters.map((chapter: any) => chapter.number))) - 1;
  const next = latest + 1;
  const empty: any = new Proxy(() => empty, { get: (_, property) => (property === 'then' ? (resolve: (value: unknown[]) => void) => resolve([]) : empty), apply: () => empty });
  return {
    query: {
      projects: { findFirst: async () => world.project ?? undefined },
      decisionLedgerEntries: { findMany: async () => world.ledger },
      volumes: {
        findMany: async (args: any) => (args?.columns ? world.changedVolumes : world.volumes),
        findFirst: async () => world.volumes.find((volume: any) => volume.state === 'active'),
      },
      plotThreads: { findMany: async () => [...world.threads].filter((row: any) => row.status === 'open').sort((left: any, right: any) => (left.threadKey < right.threadKey ? -1 : 1)) },
      mysteries: { findMany: async () => [...world.mysteries].filter((row: any) => row.status === 'open').sort((left: any, right: any) => (left.mysteryKey < right.mysteryKey ? -1 : 1)) },
      entities: { findMany: async (args: any) => world.entities.map((row: any) => projected(row, args.columns)) },
      bibleDocuments: {
        findMany: async (args: any) => (args.columns?.revision ? world.changedDocs : [...world.pages].sort((left: any, right: any) => (left.section === right.section ? (left.slug < right.slug ? -1 : 1) : left.section < right.section ? -1 : 1)).map((row: any) => projected(row, args.columns))),
      },
      canonFacts: { findMany: async (args: any) => world.facts.map((row: any) => projected(row, args.columns)) },
      worldFacts: { findMany: async () => [] },
      milestones: { findMany: async (args: any) => world.milestones.map((row: any) => projected(row, args.columns)) },
      chapters: {
        findMany: async (args: any) => world.chapters.map((row: any) => projected(row, args.columns)),
        findFirst: async (args: any) => {
          const row = world.chapters.find((chapter: any) => chapter.number === latest);
          return row ? projected(row, args.columns) : undefined;
        },
      },
      drafts: {
        findMany: async (args: any) => world.drafts.map((row: any) => projected(row, args.columns)),
        findFirst: async (args: any) => {
          const row = world.drafts.find((draft: any) => draft.chapter === latest);
          return row ? projected(row, args.columns) : undefined;
        },
      },
      briefs: {
        findMany: async (args: any) => {
          if (args?.columns?.revision) return world.changedBriefs;
          if (args?.columns) {
            const call = pending.shift();
            if (call === 'planned') return world.briefs.map((row: any) => ({ chapter: row.chapter }));
            if (call === 'stale') return world.briefs.filter((row: any) => row.staleReason !== null).map((row: any) => ({ chapter: row.chapter }));
            throw new Error('an unexpected briefs query');
          }
          return world.briefs.filter((row: any) => row.chapter === latest || row.chapter === next);
        },
      },
      continuityProposals: { findMany: async () => world.continuity },
      finalizeReviews: { findMany: async () => [] },
    },
    $count: async (table: unknown) => (table === schemas.refinementProposals ? world.pendingProposals : 0),
    select: () => empty,
  };
}

const section = (value: any): any => ({
  key: value.key, tier: value.tier, segment: value.segment, tokens: value.tokens, truncated: value.truncated, sourceRefs: value.sourceRefs, rendered: value.rendered,
  required: Boolean(value.required), priority: value.priority ?? null,
});
const heldOf = (sections: Record<string, any>): [string, string, string][] => Object.entries(sections).map(([key, held]) => [key, held.digest, held.heading]);

const scenarios: unknown[] = [];
const packs: any[] = [];
for (const spec of specs) {
  changedRefs.clear();
  for (const row of spec.ledger) if (row.anchorRef !== null && row.anchorChanged) changedRefs.add(row.anchorRef);
  const assembler = Object.create(assemblerModule.ContextAssembler.prototype);
  assembler.db = makeDb(worldOf(spec));
  // Substitution: a native volume has no revision counter, so its changed line reads `volume:<key> has changed` (ChatPackChapters.swift changedSinceLines).
  const changedSince = assemblerModule.ContextAssembler.prototype.changedSince;
  assembler.changedSince = async (...args: unknown[]): Promise<string[]> =>
    (await changedSince.apply(assembler, args)).map((line: string) => line.replace(/^volume:(.+) is now at revision unnumbered$/u, 'volume:$1 has changed'));
  const pack = await assembler.forNovelChat(1n, new Date('2026-01-01T00:00:00Z'), { promptTokens: spec.promptTokens, requestTokens: spec.requestTokens, dryRun: true });
  packs.push(pack);
  scenarios.push({
    spec,
    expected: {
      sections: pack.sections.map(section), omitted: pack.omitted, usedTokens: pack.usedTokens, budgetTokens: pack.budgetTokens, renderedStable: pack.renderedStable,
      renderedVolatile: pack.renderedVolatile,
    },
  });
}

// chat-exchange.ts contextUpdate: a first turn, an unchanged one, and each pack against the previous scenario's held sections.
const updates = packs.flatMap((pack, index) => {
  const own = exchange.contextUpdate(pack).sections;
  const holdings: [string, Record<string, any> | undefined][] = [['opening', undefined], ['same', own]];
  if (index > 0) holdings.push(['previous', exchange.contextUpdate(packs[index - 1]).sections]);
  return holdings.map(([holding, held]) => {
    const update = exchange.contextUpdate(pack, held);
    return { scenario: index, holding, text: update.text, sections: heldOf(update.sections) };
  });
});

const sanitize = (value: unknown): unknown => JSON.parse(JSON.stringify(value, (_, item) => (typeof item === 'bigint' ? Number(item) : item)));
writeFileSync(join(outDir, 'chat-assembly.json'), `${JSON.stringify(sanitize({ scenarios, updates, historyAllowance: assemblerModule.NOVEL_CHAT_HISTORY_ALLOWANCE }))}\n`);
