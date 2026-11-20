import { plugin } from 'bun';
import { readdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// Run as: PLATFORM_REPO=<checkout> bun --tsconfig-override "$PLATFORM_REPO/apps/novel-forge-server/tsconfig.json" generate.ts
// Each scenario is a vault state the Swift test builds through typed records; the expected pack is the reference's forOutline (and, for plan scenarios, ChapterPlanService.plan up to its model call) over a fake database holding the same state.
// A scenario with `retrieval` gives the assembler a retrieval service that answers every search with those hits (or rejects), and records the queries it was asked.
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

// Continuation states list their keys in code-unit order: the vault stores them as unordered members and renders them sorted.
const overrides = { nearest: async (_chapter: number): Promise<string | null> => null, planState: async (): Promise<unknown> => ({}) };

plugin({
  name: 'outline-pack-fixture-stubs',
  setup(build) {
    build.module('@server/common', () => ({ exports: commonExports, loader: 'object' }));
    build.module('@server/classes', () => ({ exports: { AppErrorCode: classes.AppErrorCode }, loader: 'object' }));
    build.module('js-tiktoken', () => ({ exports: { getEncoding: () => ({ encode: (text: string) => ({ length: estimateTokens(text) }) }) }, loader: 'object' }));
  },
});
commonExports.nearestVolumeKey = (_db: unknown, _projectId: bigint, chapter: number) => overrides.nearest(chapter);
commonExports.loadPlanState = () => overrides.planState();

const assemblerModule = await import(join(server, 'modules/ai/context/context-assembler.service.ts'));
const catalogModule = await import(join(server, 'modules/ai/context/catalog.service.ts'));
const planModule = await import(join(server, 'modules/actions/chapter-plan.service.ts'));

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
const pick = <T>(items: readonly T[]): T => items[Math.floor(random() * items.length)] as T;
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
const odd = (text: string): string => `${text} ${pick(ODD)}`;

type Unlock = { all: Record<string, unknown>[] } | null;
interface Spec {
  name: string;
  mode: 'pack' | 'plan';
  chapter: number;
  budgetTokens: number | null;
  span: { start: number; end: number } | null;
  insertAfter: number | null;
  volume: { key: string | null } | null;
  ledger: { kind: string; topic: string; statement: string; why: string | null; rejectedAlternatives: string[]; writerLine: string | null; decidedBy: string; progressStatus: string | null }[];
  volumes: { key: string; ordinal: number; title: string | null; objective: string | null; goalMet: boolean }[];
  threads: { key: string; summary: string | null; openedChapter: number | null; status: string; payoffWindow: number | null; payoffMilestone: string | null; payoffVolume: string | null; dormant: boolean }[];
  mysteries: { key: string; question: string; openedChapter: number | null; status: string; payoffWindow: number | null; payoffMilestone: string | null; payoffVolume: string | null; dormant: boolean }[];
  entities: { key: string; name: string; type: string; major: boolean; body: string | null; notes: string | null; status: string | null }[];
  pages: { section: string; slug: string; title: string | null; body: string }[];
  secrets: { key: string; text: string; revealChapter: number | null; unlock: Unlock; source: string; terms: string[]; writerNote: string | null }[];
  milestones: { key: string; label: string; subject: string | null }[];
  finals: { chapter: number; title: string | null; summary: string | null; body: string; isolated: boolean; disclosed: string[]; claims: string[]; state: Record<string, unknown> | null }[];
  drafts: { chapter: number; title: string | null; summary: string | null; body: string; isolated: boolean; state: Record<string, unknown> | null }[];
  plans: { chapter: number; title: string | null; body: string; volume: string | null; isEnding: boolean; claims: string[]; ending: { openQuestion: string; handoffState: string } | null }[];
  knowledge: { fact: string; entity: string; chapter: number }[];
  retrieval: { prose: { chapter: number; text: string }[]; lore: { kind: string; refKey: string; text: string }[]; fails: boolean } | null;
}

const entry = (fields: Partial<Spec['ledger'][number]> & { kind: string; topic: string; statement: string }): Spec['ledger'][number] => ({
  why: null, rejectedAlternatives: [], writerLine: null, decidedBy: 'author', progressStatus: null, ...fields,
});
const final = (chapter: number, overrides: Partial<Spec['finals'][number]> = {}): Spec['finals'][number] => ({
  chapter, title: words(3), summary: sentence(), body: prose(3), isolated: false, disclosed: [], claims: [], state: null, ...overrides,
});
const plan = (chapter: number, overrides: Partial<Spec['plans'][number]> = {}): Spec['plans'][number] => ({
  chapter, title: words(3), body: paragraph(), volume: 'v1', isEnding: false, claims: [], ending: { openQuestion: sentence(), handoffState: sentence() }, ...overrides,
});
const thread = (key: string, overrides: Partial<Spec['threads'][number]> = {}): Spec['threads'][number] => ({
  key, summary: sentence(), openedChapter: int(1, 3), status: 'open', payoffWindow: null, payoffMilestone: null, payoffVolume: null, dormant: false, ...overrides,
});
const secret = (key: string, overrides: Partial<Spec['secrets'][number]> = {}): Spec['secrets'][number] => ({
  key, text: sentence(), revealChapter: null, unlock: null, source: 'manual', terms: [], writerNote: null, ...overrides,
});
const entity = (key: string, type: string, major: boolean, overrides: Partial<Spec['entities'][number]> = {}): Spec['entities'][number] => ({
  key, name: words(2), type, major, body: paragraph(), notes: null, status: null, ...overrides,
});
const empty = (name: string, chapter: number, mode: Spec['mode'] = 'pack'): Spec => ({
  name, mode, chapter, budgetTokens: null, span: null, insertAfter: null, volume: null, ledger: [], volumes: [], threads: [], mysteries: [], entities: [], pages: [], secrets: [],
  milestones: [], finals: [], drafts: [], plans: [], knowledge: [], retrieval: null,
});
const timeline = { section: 'project', slug: 'timeline', title: null, body: `# Timeline\n\n## Early on\n\n${paragraph()}\n\n## The ending\n\n${paragraph()}` };

const specs: Spec[] = [];

specs.push({
  ...empty('first chapter', 1, 'plan'),
  ledger: [entry({ kind: 'decision', topic: 'voice.tone', statement: sentence(), why: sentence(), writerLine: sentence() }), entry({ kind: 'direction', topic: 'start.brief', statement: prose(2) })],
  volumes: [{ key: 'v1', ordinal: 1, title: words(2), objective: sentence(), goalMet: false }],
  entities: [entity('mara', 'character', true), entity('harbour', 'location', false, { notes: sentence(), body: null, status: 'planned' })],
  pages: [{ section: 'project', slug: 'premise', title: null, body: `# Premise\n\n${paragraph()}` }, { section: 'world', slug: 'sea', title: 'The Sea', body: paragraph() }, timeline],
  secrets: [secret('tower', { revealChapter: 5, terms: ['tower', 'bell'] }), secret('heir', { unlock: { all: [{ chapter: 3 }] } })],
  milestones: [{ key: 'rise', label: words(2), subject: 'mara' }],
  plans: [plan(1, { claims: ['rise'] }), plan(2)],
});

specs.push({
  ...empty('mid volume', 7, 'plan'),
  ledger: [
    ...Array.from({ length: 8 }, (_, index) => entry({ kind: index % 3 === 0 ? 'direction' : 'decision', topic: `topic.${index}`, statement: index % 4 === 0 ? odd(paragraph()) : sentence(), why: index % 2 === 0 ? sentence() : null, rejectedAlternatives: index % 3 === 1 ? [words(3)] : [], decidedBy: index % 5 === 4 ? 'system' : 'author' })),
    entry({ kind: 'rejected', topic: 'plain', statement: sentence(), why: sentence() }),
    entry({ kind: 'backlog', topic: 'later.one', statement: sentence() }),
    entry({ kind: 'system', topic: 'progress.ending', statement: 'Left undecided for now.', decidedBy: 'system', progressStatus: 'undecided' }),
  ],
  volumes: [{ key: 'v1', ordinal: 1, title: 'One', objective: prose(2), goalMet: false }, { key: 'v2', ordinal: 2, title: null, objective: sentence(), goalMet: false }],
  threads: [thread('lantern', { payoffWindow: 5 }), thread('letter', { dormant: true, openedChapter: 1 }), thread('oath', { payoffVolume: 'v1' }), thread('closed-one', { status: 'closed' })],
  mysteries: [{ key: 'heir', question: odd(sentence()), openedChapter: 2, status: 'open', payoffWindow: null, payoffMilestone: 'rise', payoffVolume: null, dormant: false }],
  entities: [entity('mara', 'character', true), entity('heir', 'character', false), entity('law', 'power_rule', false, { body: prose(2) }), entity('sea', 'location', true, { body: prose(6) })],
  pages: [{ section: 'project', slug: 'premise', title: null, body: `# Premise\n\n${paragraph()}` }, { section: 'lore', slug: 'oaths', title: odd('Oaths'), body: paragraph() }, { section: 'plot', slug: 'escalation-map', title: null, body: paragraph() }, timeline],
  secrets: [secret('tower', { revealChapter: 9, terms: ['tower'], writerNote: sentence() }), secret('ledger', { revealChapter: 2 }), secret('seed-fact', { source: 'seed' }), secret('late', { unlock: { all: [{ milestone: 'rise' }, { volume: 'v2' }] } })],
  milestones: [{ key: 'rise', label: words(2), subject: 'mara' }, { key: 'fall', label: words(2), subject: null }, { key: 'turn', label: words(3), subject: null }],
  finals: [
    final(1), final(2, { disclosed: ['ledger'], claims: ['rise'] }), final(3), final(4),
    final(5, { isolated: true }), final(6, { state: { mood: words(2), open_threads: ['lantern'], place: sentence() } }),
  ],
  drafts: [],
  plans: [plan(7, { claims: ['fall'] }), plan(8, { claims: ['turn'] })],
  knowledge: [{ fact: 'tower', entity: 'mara', chapter: 3 }],
});

specs.push({
  ...empty('volume end', 13, 'plan'),
  ledger: [entry({ kind: 'decision', topic: 'ending.shape', statement: sentence() })],
  volumes: [{ key: 'v1', ordinal: 1, title: 'One', objective: sentence(), goalMet: true }, { key: 'v2', ordinal: 2, title: 'Two', objective: prose(2), goalMet: false }],
  threads: [thread('lantern', { payoffVolume: 'v1', openedChapter: 1 })],
  entities: [entity('mara', 'character', true)],
  secrets: [secret('tower', { revealChapter: 14 }), secret('gate', { unlock: { all: [{ volume: 'v2' }] } })],
  milestones: [{ key: 'rise', label: words(2), subject: null }],
  finals: Array.from({ length: 11 }, (_, index) => final(index + 1, { claims: index === 3 ? ['rise'] : [], disclosed: index === 5 ? ['tower'] : [] })),
  drafts: [{ chapter: 12, title: words(2), summary: sentence(), body: prose(4), isolated: false, state: { place: sentence() } }],
  plans: [plan(12, { volume: 'v1' }), plan(13, { volume: 'v2' }), plan(14, { volume: 'v2', isEnding: true })],
});

specs.push({ ...empty('no milestones and an unplanned chapter', 3, 'plan'), volumes: [], finals: [final(1), final(2)] });

specs.push({
  ...empty('many threads under budget pressure', 25, 'plan'),
  budgetTokens: 9_000,
  ledger: Array.from({ length: 20 }, (_, index) => entry({ kind: 'decision', topic: `topic.${index}`, statement: prose(1), why: sentence() })),
  volumes: [{ key: 'v1', ordinal: 1, title: 'One', objective: prose(3), goalMet: false }],
  threads: Array.from({ length: 70 }, (_, index) => thread(`t${String(index).padStart(2, '0')}`, { summary: paragraph(), openedChapter: int(1, 20), payoffWindow: index % 4 === 0 ? int(5, 30) : null })),
  mysteries: Array.from({ length: 20 }, (_, index) => ({ key: `m${String(index).padStart(2, '0')}`, question: paragraph(), openedChapter: int(1, 20), status: 'open', payoffWindow: null, payoffMilestone: null, payoffVolume: null, dormant: index % 7 === 0 })),
  entities: Array.from({ length: 180 }, (_, index) => entity(`ent-${String(index).padStart(3, '0')}`, pick(['character', 'location', 'item', 'faction']), index % 5 === 0, { body: prose(2) })),
  pages: Array.from({ length: 40 }, (_, index) => ({ section: pick(['lore', 'world', 'plot', 'power']), slug: `page-${String(index).padStart(2, '0')}`, title: index % 2 === 0 ? words(2) : null, body: prose(2) })),
  secrets: Array.from({ length: 40 }, (_, index) => secret(`fact-${String(index).padStart(2, '0')}`, { revealChapter: index % 3 === 0 ? int(26, 60) : null, text: prose(1), terms: index % 4 === 0 ? [words(1)] : [] })),
  milestones: Array.from({ length: 8 }, (_, index) => ({ key: `ms-${index}`, label: words(3), subject: null })),
  finals: Array.from({ length: 60 }, (_, index) => final(index + 1, { summary: index % 3 === 0 ? 'Short.' : paragraph() })).filter((row) => row.chapter < 25),
  plans: [plan(25, { claims: ['ms-0'] })],
});

specs.push({
  ...empty('pack for a span and an insert', 7),
  span: { start: 7, end: 9 },
  insertAfter: 6,
  volume: { key: 'v1' },
  ledger: [entry({ kind: 'decision', topic: 'voice.tone', statement: sentence() })],
  volumes: [{ key: 'v1', ordinal: 1, title: 'One', objective: sentence(), goalMet: false }, { key: 'v2', ordinal: 2, title: 'Two', objective: sentence(), goalMet: false }],
  entities: [entity('mara', 'character', true), entity('law', 'power_rule', false, { body: prose(3) })],
  pages: [timeline],
  secrets: [secret('tower', { revealChapter: 8, terms: ['tower'] }), secret('late', { revealChapter: 12 }), secret('chapterly', { unlock: { all: [{ chapter: 7 }] } }), secret('later', { unlock: { all: [{ chapter: 9 }, { ending: true }] } })],
  milestones: [{ key: 'rise', label: words(2), subject: null }],
  finals: [final(1, { isolated: true }), final(2), final(3), final(4), final(5), final(6)],
  plans: [plan(8, { volume: 'v1' }), plan(12, { volume: 'v2', isEnding: true })],
});

specs.push({ ...empty('pack with a draft ending, no timeline and a short budget', 4), budgetTokens: 600, volume: { key: null }, finals: [final(1), final(2)], drafts: [{ chapter: 3, title: words(2), summary: sentence(), body: prose(5), isolated: false, state: null }] });

const SECRET_MARK = 'ZEBRAQUILL';
specs.push({
  ...empty('after an isolated final chapter', 6, 'plan'),
  volumes: [{ key: 'v1', ordinal: 1, title: 'One', objective: sentence(), goalMet: false }],
  entities: [entity('mara', 'character', true)],
  secrets: [secret('tower', { revealChapter: 9 })],
  finals: [final(1), final(2), final(3), final(4), final(5, { isolated: true, title: `${SECRET_MARK} title`, summary: `${SECRET_MARK} summary.`, body: `${prose(2)}\n\n${SECRET_MARK} body paragraph.`, state: { mood: `${SECRET_MARK} state` } })],
  plans: [plan(6)],
  knowledge: [{ fact: 'tower', entity: 'mara', chapter: 2 }],
});
specs.push({
  ...empty('after an isolated draft', 5, 'plan'),
  volumes: [{ key: 'v1', ordinal: 1, title: 'One', objective: sentence(), goalMet: false }],
  finals: [final(1), final(2), final(3, { isolated: true, summary: `${SECRET_MARK} summary.`, title: `${SECRET_MARK} title` })],
  drafts: [{ chapter: 4, title: `${SECRET_MARK} title`, summary: `${SECRET_MARK} summary.`, body: `${prose(2)}\n\n${SECRET_MARK} body paragraph.`, isolated: true, state: { mood: `${SECRET_MARK} state` } }],
  plans: [plan(5)],
});
specs.push({
  ...empty('a reached milestone that is a mystery payoff', 4, 'plan'),
  volumes: [{ key: 'v1', ordinal: 1, title: 'One', objective: null, goalMet: false }],
  mysteries: [{ key: 'heir', question: sentence(), openedChapter: 1, status: 'open', payoffWindow: null, payoffMilestone: 'rise', payoffVolume: null, dormant: false }],
  milestones: [{ key: 'rise', label: words(2), subject: null }, { key: 'fall', label: words(2), subject: null }],
  finals: [final(1), final(2, { claims: ['rise'] }), final(3)],
  plans: [plan(4)],
});
specs.push({
  ...empty('entity budget binds with no catalog ceiling', 3),
  budgetTokens: 400_000,
  entities: Array.from({ length: 160 }, (_, index) => entity(`ent-${String(index).padStart(3, '0')}`, pick(['character', 'location', 'item']), index % 6 === 0, { body: prose(7) })),
  finals: [final(1), final(2)],
});
specs.push({
  ...empty('mid-size budget trims chapters then mysteries', 52),
  budgetTokens: 11_400,
  entities: Array.from({ length: 150 }, (_, index) => entity(`ent-${String(index).padStart(3, '0')}`, pick(['character', 'location']), index % 5 === 0, { body: prose(7) })),
  threads: Array.from({ length: 30 }, (_, index) => thread(`t${String(index).padStart(2, '0')}`, { summary: paragraph() })),
  mysteries: Array.from({ length: 40 }, (_, index) => ({ key: `m${String(index).padStart(2, '0')}`, question: paragraph(), openedChapter: int(1, 20), status: 'open', payoffWindow: null, payoffMilestone: null, payoffVolume: null, dormant: false })),
  pages: Array.from({ length: 20 }, (_, index) => ({ section: 'lore', slug: `page-${String(index).padStart(2, '0')}`, title: words(2), body: prose(2) })),
  finals: Array.from({ length: 51 }, (_, index) => final(index + 1, { title: words(6), summary: words(5) })),
});

specs.push({ ...(specs.at(-1) as Spec), name: 'a smaller trim stops partway through the chapters', budgetTokens: 12_100 });

type Recall = NonNullable<Spec['retrieval']>;
const recalled = (prose: Recall['prose'], lore: Recall['lore'], fails = false): Recall => ({ prose, lore, fails });
const recallWorld = (name: string, chapter: number, mode: Spec['mode'] = 'pack'): Spec => ({
  ...empty(name, chapter, mode),
  ledger: [entry({ kind: 'decision', topic: 'voice.tone', statement: sentence() })],
  volumes: [{ key: 'v1', ordinal: 1, title: 'One', objective: `${sentence()}\n${sentence()}\n\n${paragraph()}`, goalMet: false }],
  entities: [entity('mara', 'character', true), entity('sea', 'location', false)],
  pages: [{ section: 'world', slug: 'sea', title: 'The Sea', body: paragraph() }],
  finals: Array.from({ length: chapter - 1 }, (_, index) => final(index + 1)),
  plans: [plan(chapter)],
});

specs.push({
  ...recallWorld('pack with retrieved prose and lore', 4),
  retrieval: recalled(
    [{ chapter: 2, text: paragraph() }, { chapter: 1, text: odd(paragraph()) }, { chapter: 3, text: prose(2) }],
    [{ kind: 'character', refKey: 'mara', text: `${words(2)}\n${sentence()}` }, { kind: 'bible_doc', refKey: 'world/sea', text: odd(paragraph()) }],
  ),
});
specs.push({ ...recallWorld('plan with retrieved lore and no prose', 3, 'plan'), retrieval: recalled([], [{ kind: 'character', refKey: 'sea', text: paragraph() }]) });
specs.push({
  ...recallWorld('retrieved prose gives way to the budget before lore', 4),
  budgetTokens: 900,
  retrieval: recalled(Array.from({ length: 5 }, (_, index) => ({ chapter: (index % 3) + 1, text: prose(6) })), [{ kind: 'character', refKey: 'mara', text: sentence() }]),
});
specs.push({
  ...recallWorld('retrieval takes only what a full catalog leaves', 4),
  budgetTokens: 3_000,
  entities: Array.from({ length: 120 }, (_, index) => entity(`ent-${String(index).padStart(3, '0')}`, 'character', index % 4 === 0, { body: prose(2) })),
  retrieval: recalled([{ chapter: 1, text: prose(3) }], [{ kind: 'character', refKey: 'ent-000', text: prose(3) }]),
});
specs.push({ ...recallWorld('a failed retrieval leaves the pack without it', 3), retrieval: recalled([{ chapter: 1, text: paragraph() }], [], true) });
{
  const base = recallWorld('an objective whose first line is empty searches nothing', 3);
  specs.push({ ...base, volumes: [{ key: 'v1', ordinal: 1, title: 'One', objective: `\n${sentence()}`, goalMet: false }], retrieval: recalled([{ chapter: 1, text: paragraph() }], []) });
}
{
  const base = recallWorld('no objective searches nothing', 3);
  specs.push({ ...base, volumes: [{ key: 'v1', ordinal: 1, title: 'One', objective: null, goalMet: false }], retrieval: recalled([{ chapter: 1, text: paragraph() }], []) });
}

const volumeStates = (spec: Spec): Map<string, string> => {
  const ordered = [...spec.volumes].sort((left, right) => left.ordinal - right.ordinal);
  const passed = ordered.reduce((last, volume, index) => (volume.goalMet ? index + 1 : last), 0);
  const active = ordered.findIndex((volume, index) => index >= passed && !volume.goalMet);
  return new Map(ordered.map((volume, index) => [volume.key, volume.goalMet ? 'goal_met' : index === active ? 'active' : 'not_started']));
};

function worldOf(spec: Spec): any {
  const states = volumeStates(spec);
  const reached = new Map<string, number>();
  for (const row of [...spec.finals].sort((left, right) => left.chapter - right.chapter)) for (const key of row.claims) if (!reached.has(key)) reached.set(key, row.chapter);
  const planned = new Map<string, number>();
  for (const row of [...spec.plans].sort((left, right) => left.chapter - right.chapter)) for (const key of row.claims) if (!planned.has(key)) planned.set(key, row.chapter);
  const facts = [...spec.secrets].sort((left, right) => (left.key < right.key ? -1 : 1)).map((row, index) => ({
    id: BigInt(index + 1), factKey: row.key, text: row.text, revealChapter: row.revealChapter, unlock: row.unlock, source: row.source, terms: row.terms, writerNote: row.writerNote, plannedChapter: null,
  }));
  const drafts = [
    ...spec.finals.map((row) => ({ chapter: row.chapter, body: row.body, summary: row.summary, state: row.state, isolated: row.isolated, staleReason: null })),
    ...spec.drafts.map((row) => ({ chapter: row.chapter, body: row.body, summary: row.summary, state: row.state, isolated: row.isolated, staleReason: null })),
  ];
  const briefs = [
    ...spec.plans.map((row) => ({
      chapter: row.chapter, title: row.title, body: row.body, volumeKey: row.volume, isEnding: row.isEnding, claimedMilestones: row.claims, knowledgeContract: null, staleReason: null,
      endingContract: row.ending, hidden: false,
    })),
    ...spec.finals.filter((row) => row.claims.length > 0).map((row) => ({
      chapter: row.chapter, title: null, body: '', volumeKey: null, isEnding: false, claimedMilestones: row.claims, knowledgeContract: null, staleReason: null, endingContract: null, hidden: true,
    })),
  ].map((row, index) => ({ ...row, id: BigInt(index + 1) }));
  const milestones = [...spec.milestones].sort((left, right) => (left.key < right.key ? -1 : 1)).map((row, index) => ({
    id: BigInt(index + 1), milestoneKey: row.key, label: row.label, subjectEntityKey: row.subject, state: reached.has(row.key) ? 'reached' : planned.has(row.key) ? 'planned' : 'open',
    plannedChapter: planned.get(row.key) ?? null, reachedChapter: reached.get(row.key) ?? null,
  }));
  return {
    chapters: spec.finals.map((row) => ({ number: row.chapter, title: row.title, status: 'done', summary: row.summary, isolated: row.isolated, content: row.body })),
    drafts,
    briefs,
    volumes: [...spec.volumes].sort((left, right) => left.ordinal - right.ordinal).map((row) => ({ volumeKey: row.key, ordinal: row.ordinal, title: row.title, objective: row.objective, state: states.get(row.key) })),
    threads: [...spec.threads].sort((left, right) => (left.key < right.key ? -1 : 1)).map((row) => ({ threadKey: row.key, status: row.status, summary: row.summary, openedChapter: row.openedChapter, lastAdvancedChapter: null, payoffWindow: row.payoffWindow, payoffMilestoneKey: row.payoffMilestone, payoffVolumeKey: row.payoffVolume, intentionallyOpen: row.dormant })),
    mysteries: [...spec.mysteries].sort((left, right) => (left.key < right.key ? -1 : 1)).map((row) => ({ mysteryKey: row.key, status: row.status, question: row.question, openedChapter: row.openedChapter, lastAdvancedChapter: null, payoffWindow: row.payoffWindow, payoffMilestoneKey: row.payoffMilestone, payoffVolumeKey: row.payoffVolume, intentionallyOpen: row.dormant })),
    entities: [...spec.entities].sort((left, right) => (left.key < right.key ? -1 : 1)).map((row) => ({ entityKey: row.key, name: row.name, type: row.type, significance: row.major ? 'major' : 'minor', body: row.body, notes: row.notes, status: row.status })),
    pages: spec.pages.map((row) => ({ section: row.section, slug: row.slug, frontmatter: row.title === null ? null : { title: row.title }, body: row.body })),
    facts,
    revealed: facts.filter((row) => spec.knowledge.some((known) => known.fact === row.factKey)).map((row) => ({ factId: row.id })),
    milestones,
    ledger: spec.ledger.map((row) => ({
      kind: row.kind, topic: row.topic, statement: row.statement, why: row.why, rejectedAlternatives: row.rejectedAlternatives, writerLine: row.writerLine, decidedBy: row.decidedBy,
      ideaId: null, rejectionScope: null, rejectionAnchor: null, payload: row.progressStatus === null ? null : { status: row.progressStatus }, links: {},
    })),
  };
}

const paramsOf = (where: any, out: unknown[] = []): unknown[] => {
  if (!where || typeof where !== 'object') return out;
  if (where.constructor?.name === 'Param') out.push(where.value);
  if (Array.isArray(where.queryChunks)) for (const chunk of where.queryChunks) paramsOf(chunk, out);
  return out;
};
const projected = (record: any, columns?: any): any => (columns ? Object.fromEntries(Object.keys(columns).map((name) => [name, record[name] ?? null])) : record);

function makeDb(world: any, chapter: number): any {
  const empty: any = new Proxy(() => empty, { get: (_, property) => (property === 'then' ? (resolve: (value: unknown[]) => void) => resolve([]) : empty), apply: () => empty });
  const visibleBriefs = world.briefs.filter((row: any) => !row.hidden);
  return {
    query: {
      projects: { findFirst: async () => ({}) },
      decisionLedgerEntries: { findMany: async () => world.ledger },
      volumes: {
        findMany: async (args: any) => (args?.columns ? world.volumes.map((row: any) => projected(row, args.columns)) : world.volumes),
        findFirst: async (args: any) => {
          const keys = paramsOf(args?.where);
          return world.volumes.find((row: any) => keys.includes(row.volumeKey));
        },
      },
      plotThreads: { findMany: async (args: any) => (paramsOf(args?.where).includes('open') ? world.threads.filter((row: any) => row.status === 'open') : world.threads) },
      mysteries: { findMany: async (args: any) => (paramsOf(args?.where).includes('open') ? world.mysteries.filter((row: any) => row.status === 'open') : world.mysteries) },
      entities: {
        findMany: async (args: any) => (args?.columns ? world.entities.filter((row: any) => row.type === 'character').map((row: any) => projected(row, args.columns)) : world.entities),
      },
      bibleDocuments: {
        findMany: async (args: any) => (args?.columns?.frontmatter ? world.pages : world.pages.filter((row: any) => row.section === 'project' && row.slug === 'timeline').map((row: any) => projected(row, args.columns))),
      },
      canonFacts: { findMany: async (args: any) => world.facts.map((row: any) => projected(row, args?.columns)) },
      characterKnowledge: { findMany: async () => world.revealed },
      worldFacts: { findMany: async () => [] },
      milestones: { findMany: async (args: any) => world.milestones.map((row: any) => projected(row, args?.columns)) },
      chapters: {
        findMany: async (args: any) => {
          if (args?.limit === 3) return world.chapters.filter((row: any) => row.number < chapter).sort((left: any, right: any) => right.number - left.number).slice(0, 3).map((row: any) => projected(row, args.columns));
          return world.chapters.map((row: any) => projected(row, args?.columns));
        },
        findFirst: async (args: any) => {
          const row = world.chapters.find((candidate: any) => candidate.number === chapter - 1);
          return row ? projected(row, args?.columns) : undefined;
        },
      },
      drafts: {
        findFirst: async (args: any) => {
          const row = world.drafts.find((candidate: any) => candidate.chapter === chapter - 1);
          return row ? projected(row, args?.columns) : undefined;
        },
      },
      briefs: {
        findFirst: async (args: any) => {
          const numbers = paramsOf(args?.where).filter((value) => typeof value === 'number');
          return visibleBriefs.find((row: any) => numbers.includes(row.chapter));
        },
        findMany: async () => visibleBriefs.filter((row: any) => row.chapter === chapter - 1 || row.chapter === chapter + 1).sort((left: any, right: any) => left.chapter - right.chapter),
      },
      finalizeReviews: { findMany: async () => [] },
    },
    insert: () => ({ values: () => ({ onConflictDoNothing: () => ({ returning: async () => [{ id: 1n }] }) }) }),
    select: () => empty,
  };
}

const section = (value: any): any => ({
  key: value.key, tier: value.tier, segment: value.segment, tokens: value.tokens, truncated: value.truncated, sourceRefs: value.sourceRefs, rendered: value.rendered,
  required: Boolean(value.required), priority: value.priority ?? null,
});

class Captured extends Error {
  constructor(readonly vars: Record<string, string>) {
    super('captured');
  }
}

const scenarios: unknown[] = [];
for (const spec of specs) {
  const world = worldOf(spec);
  const db = makeDb(world, spec.chapter);
  overrides.nearest = async (chapter: number) => {
    const planned = world.briefs.filter((row: any) => row.volumeKey !== null);
    const before = planned.filter((row: any) => row.chapter <= chapter).sort((left: any, right: any) => right.chapter - left.chapter)[0];
    if (before?.volumeKey) return before.volumeKey;
    return planned.filter((row: any) => row.chapter > chapter).sort((left: any, right: any) => left.chapter - right.chapter)[0]?.volumeKey ?? null;
  };
  overrides.planState = async () => ({
    plans: world.briefs, milestones: world.milestones, milestoneRows: world.milestones, volumeOrdinals: new Map(world.volumes.map((row: any) => [row.volumeKey, row.ordinal])),
    facts: world.facts, frontier: 0,
  });
  const catalogService = Object.create(catalogModule.CatalogService.prototype);
  catalogService.db = db;
  catalogService.logger = { info: () => undefined };
  const assembler = Object.create(assemblerModule.ContextAssembler.prototype);
  assembler.db = db;
  assembler.logger = { info: () => undefined, warn: () => undefined };
  assembler.catalogService = catalogService;
  const queries: string[] = [];
  if (spec.retrieval !== null) {
    const { prose: proseHits, lore: loreHits, fails } = spec.retrieval;
    assembler.retrievalService = {
      searchProseAndLore: async (_projectId: bigint, query: string) => {
        queries.push(query);
        if (fails) throw new Error('the index is unavailable');
        return {
          prose: proseHits.map((hit) => ({ text: hit.text, score: 0.5, metadata: { chapter: hit.chapter } })),
          lore: loreHits.map((hit) => ({ text: hit.text, score: 0.5, metadata: { kind: hit.kind, refKey: hit.refKey } })),
        };
      },
    };
  }
  let expected: any;
  if (spec.mode === 'pack') {
    const options: any = { dryRun: true, span: spec.span ?? undefined, insertAfter: spec.insertAfter ?? undefined };
    if (spec.budgetTokens !== null) options.budgetTokens = spec.budgetTokens;
    if (spec.volume !== null) options.volumeKey = spec.volume.key;
    const pack = await assembler.forOutline(1n, spec.chapter, options);
    expected = { sections: pack.sections.map(section), omitted: pack.omitted, usedTokens: pack.usedTokens, budgetTokens: pack.budgetTokens, rendered: pack.rendered };
  } else {
    const service = Object.create(planModule.ChapterPlanService.prototype);
    service.db = db;
    service.logger = { info: () => undefined, warn: () => undefined };
    service.contextAssembler = assembler;
    service.pluginPolicy = { resolve: async () => undefined };
    service.modelRouter = { structured: async (_prompt: unknown, vars: Record<string, string>) => { throw new Captured(vars); } };
    if (spec.budgetTokens !== null) {
      const forOutline = assembler.forOutline.bind(assembler);
      assembler.forOutline = (projectId: bigint, chapter: number, options: any) => forOutline(projectId, chapter, { ...options, budgetTokens: spec.budgetTokens });
    }
    try {
      await service.plan(1n, { chapter: spec.chapter }, 'run');
      throw new Error('the plan call never reached the model');
    } catch (error) {
      if (!(error instanceof Captured)) throw error;
      expected = { catalog: error.vars.catalog, obligations: error.vars.obligations, milestones: error.vars.milestones, endingNote: error.vars.endingNote };
    }
  }
  if (spec.retrieval !== null) expected.queries = queries;
  scenarios.push({ spec, expected });
}

writeFileSync(join(outDir, 'outline-pack.json'), `${JSON.stringify({ scenarios, budget: assemblerModule.OUTLINE_BUDGET, timelineCap: assemblerModule.OUTLINE_TIMELINE_CAP })}\n`);
