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

plugin({
  name: 'chat-context-fixture-stubs',
  setup(build) {
    build.module('@server/common', () => ({ exports: commonExports, loader: 'object' }));
    build.module('@server/classes', () => ({ exports: { AppErrorCode: classes.AppErrorCode }, loader: 'object' }));
    build.module('js-tiktoken', () => ({ exports: { getEncoding: () => ({ encode: (text: string) => ({ length: estimateTokens(text) }) }) }, loader: 'object' }));
  },
});

const contextDir = join(server, 'modules/ai/context');
const chat = await import(join(contextDir, 'novel-chat-context.ts'));
const packRender = await import(join(contextDir, 'pack-render.ts'));
const sectionsModule = await import(join(contextDir, 'sections.ts'));
const assemblerModule = await import(join(contextDir, 'context-assembler.service.ts'));
const policyModule = await import(join(server, 'modules/bible/fact/writer-disclosure-policy.ts'));
const writing = await import(join(server, 'modules/ai/prompts/writing-instructions.ts'));
const rejections = await import(join(server, 'modules/refinement/idea-rejections.ts'));
const schemas = await import(join(server, 'database/schemas/index.ts'));

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

const rng = createRng(20260721);

const WORDS = ('the a of and to in he she it was had were that with for on as at by from his her they them there then when what which who would could should '
  + 'lighthouse keeper stairs window grey sea sky morning lantern harbour captain letter promise winter river bridge silence shadow memory garden kitchen mother brother '
  + 'walked climbed whispered remembered carried opened closed turned waited listened wondered believed forgot answered followed slowly quietly suddenly always never '
  + 'old young cold long narrow bright empty heavy small distant familiar broken careful quiet').split(' ');
const ODD = ['日本語の文章', '灯塔守护者', 'Élodie', 'naïve café', 'Ünïcode', '😀', '👩‍👩‍👧', '𠮷野家', 'é', 'ﬁne', ' ', '　', ' ', 'Ω≈ç√'];
const KEY_PARTS = ['mara', 'heir', 'ledger', 'tower', 'ünï', 'key_two', 'Alpha', 'beta', 'ζeta', 'x', '日本', 'A', 'b'];

const words = (count: number): string => Array.from({ length: count }, () => rng.pick(WORDS)).join(' ');
const sentence = (count = rng.int(4, 14)): string => {
  const text = words(count);
  return `${text.charAt(0).toUpperCase()}${text.slice(1)}${rng.pick(['.', '.', '!', '?'])}`;
};
const paragraph = (sentences = rng.int(1, 4)): string => Array.from({ length: sentences }, () => sentence()).join(' ');
const prose = (paragraphs: number, separator = '\n\n'): string => Array.from({ length: paragraphs }, () => paragraph()).join(separator);
const odd = (): string => rng.pick(ODD);
const messy = (text: string): string => (rng.chance(0.35) ? `${text} ${odd()}` : rng.chance(0.15) ? `${odd()}  ${text}` : text);
const maybe = <T>(p: number, value: () => T): T | null => (rng.chance(p) ? value() : null);
const dense = (tokens: number): string => {
  const letters = Array.from({ length: Math.ceil(tokens / 1.1) }, (_, index) => `${'abcdefghij'[rng.int(0, 9)]}${index % 80 === 79 ? '.\n\n' : index % 9 === 8 ? '.' : ''}`);
  return letters.join(' ');
};

const blank = (): string => rng.pick(['', ' ', '\n', '\t  ', ' ', '﻿']);
const key = (): string => `${rng.pick(KEY_PARTS)}${rng.chance(0.5) ? `_${rng.pick(KEY_PARTS)}` : ''}${rng.chance(0.3) ? rng.int(1, 99) : ''}`;
const shuffled = <T>(items: readonly T[]): T[] => {
  const copy = [...items];
  for (let index = copy.length - 1; index > 0; index--) {
    const other = rng.int(0, index);
    [copy[index], copy[other]] = [copy[other] as T, copy[index] as T];
  }
  return copy;
};

const sanitize = (value: unknown): unknown => JSON.parse(JSON.stringify(value, (_, item) => (typeof item === 'bigint' ? Number(item) : item)));
const strip = (text: string): string => text.replace(/[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]/g, '');
const hasLoneSurrogate = (text: string): boolean => strip(text) !== text;

const section = (value: any): any => ({
  key: value.key,
  tier: value.tier,
  segment: value.segment,
  tokens: value.tokens,
  truncated: value.truncated,
  sourceRefs: value.sourceRefs,
  rendered: value.rendered,
  required: Boolean(value.required),
  priority: value.priority ?? null,
});

const KINDS = ['decision', 'direction', 'rejected', 'backlog', 'system'] as const;
const SCOPES = ['never', 'not_now', 'not_this_version'] as const;
const VOLUME_STATES = ['not_started', 'active', 'goal_met'] as const;
const MILESTONE_STATES = ['open', 'planned', 'reached'] as const;
const REVIEWS = ['needs_review', 'approved', 'final'] as const;
const fixture: Record<string, unknown> = {};

const LABEL_KEYS = [...sectionsModule.CORE_SECTION_KEYS, 'plugin_extra', 'x', 'two_words_here', 'ünï_key', 'a__b'];
fixture.labels = LABEL_KEYS.map((labelKey: string) => ({ key: labelKey, rendered: sectionsModule.renderSection(labelKey, `body of ${labelKey}\nsecond line`) }));
fixture.labels.push(...[''].map((labelKey) => ({ key: labelKey, rendered: sectionsModule.renderSection(labelKey, '') })));

fixture.joins = Array.from({ length: 5 }, () => {
  const sections = Array.from({ length: rng.int(0, 4) }, (_, index) => ({
    key: `s${index}`,
    tier: 'working',
    segment: rng.pick(['stable', 'volatile']),
    tokens: 1,
    truncated: false,
    sourceRefs: [],
    rendered: messy(prose(rng.int(1, 2))),
    required: false,
    priority: null,
  }));
  const split = sectionsModule.splitSegments(sections);
  return { sections, joined: sectionsModule.joinSections(sections), stable: split.renderedStable, volatile: split.renderedVolatile };
});

fixture.fits = Array.from({ length: 10 }, (_, index) => {
  const content = index % 6 === 0 ? words(rng.int(1, 8)) : index % 6 === 1 ? dense(rng.int(100, 600)) : messy(prose(rng.int(1, 6)));
  const base = packRender.makeSection(rng.pick(['story', 'handoff', 'prev_ending', 'custom_key']), content, rng.pick(['canonical', 'approved_intent', 'working']), ['chapter:3']);
  const cap = rng.pick([0, 1, 5, 20, 40, 60, 100, 250, 600, 5000]);
  return { section: section(base), cap, expected: section(packRender.fitToCap(base, cap)) };
});

function storyCase(): any {
  const long = rng.chance(0.08);
  const story = {
    title: maybe(0.8, () => messy(words(rng.int(1, 5)))),
    premise: rng.chance(0.15) ? blank() : maybe(0.85, () => (long ? dense(rng.int(1300, 1700)) : messy(prose(rng.int(1, 4))))),
    brief: maybe(0.5, () => messy(paragraph())),
    themes: Array.from({ length: rng.int(0, 4) }, () => messy(words(rng.int(1, 3)))),
    theme: maybe(0.6, () => (rng.chance(0.08) ? dense(rng.int(450, 600)) : messy(sentence()))),
    endingQuestion: maybe(0.6, () => (rng.chance(0.15) ? blank() : messy(sentence()))),
    ending: rng.chance(0.2) ? blank() : maybe(0.65, () => (rng.chance(0.08) ? dense(rng.int(350, 450)) : messy(paragraph()))),
    readerPromise: maybe(0.6, () => messy(sentence())),
    protagonistKey: maybe(0.6, key),
    opposition: maybe(0.5, () => messy(sentence())),
    authorInstructions: maybe(0.5, () => (rng.chance(0.08) ? dense(rng.int(450, 600)) : messy(paragraph()))),
  };
  return { story, expected: chat.renderNovelStory(story) };
}
fixture.story = [
  ...Array.from({ length: 14 }, storyCase),
  ...[
    { title: null, premise: '', brief: 'fallback brief', themes: [], theme: null, endingQuestion: null, ending: null, readerPromise: null, protagonistKey: null, opposition: null, authorInstructions: null },
    { title: null, premise: null, brief: 'fallback brief', themes: ['a', 'b'], theme: null, endingQuestion: null, ending: '   ', readerPromise: null, protagonistKey: null, opposition: null, authorInstructions: ' ' },
    { title: null, premise: null, brief: null, themes: [], theme: null, endingQuestion: null, ending: null, readerPromise: null, protagonistKey: null, opposition: null, authorInstructions: null },
  ].map((story) => ({ story, expected: chat.renderNovelStory(story) })),
];

const NOTES = [
  '',
  '   ',
  'one paragraph only',
  'first\n\nsecond',
  'first\n \nsecond\n\t\nthird',
  'first\r\n\r\nsecond',
  'first second\n\nthird',
  '\n\nleading and trailing\n\n',
  'a\n\n\n\nb',
  ' \n\n ',
  'α β　γ\n\n日本語 の 文章\n\n😀 😀 😀',
  'word\n \nword word\n\nword',
];
for (let index = 0; index < 8; index++) NOTES.push(Array.from({ length: rng.int(1, 9) }, () => messy(paragraph())).join(rng.pick(['\n\n', '\n  \n', '\n\n\n'])));
fixture.notes = NOTES.map((notes) => ({ notes, paragraphs: chat.notesParagraphs(notes), expected: chat.renderNotesPointer(notes) }));

fixture.progress = Array.from({ length: 16 }, (_, index) => {
  const items = index === 0 ? [] : Array.from({ length: rng.int(1, 9) }, () => ({ status: rng.pick(['open', 'answered', 'undecided', 'dismissed']), label: messy(words(rng.int(1, 4))) }));
  if (index === 1) for (const item of items) item.status = 'dismissed';
  return { items, expected: chat.renderProgress(items) };
});

fixture.volumes = Array.from({ length: 14 }, (_, index) => {
  const count = index === 0 ? 0 : rng.int(1, 6);
  const volumes = shuffled(Array.from({ length: count }, (_, ordinal) => ({
    volumeKey: `vol-${key()}`,
    ordinal: ordinal + 1 + (rng.chance(0.2) ? 0 : 0),
    title: maybe(0.7, () => messy(words(rng.int(1, 4)))),
    objective: rng.chance(0.15) ? blank() : maybe(0.7, () => messy(sentence())),
    state: rng.pick(VOLUME_STATES),
  })));
  if (index % 5 === 2) for (const volume of volumes) volume.state = 'goal_met';
  if (index % 5 === 3) for (const volume of volumes) volume.state = 'not_started';
  if (index === 4 && volumes.length > 1) volumes[1]!.ordinal = volumes[0]!.ordinal;
  return { volumes, expected: chat.renderVolumeGoals(volumes) };
});

function ledgerEntry(): any {
  const kind = rng.pick(KINDS);
  const idea = kind === 'rejected' && rng.chance(0.65);
  const pad = rng.chance(0.2);
  return {
    kind,
    topic: rng.pick(['pacing', 'voice.tone', 'ending', 'cast.mara', 'idea.alpha', 'tone', 'start.brief', 'progress.premise', 'progress.ending', 'ünï.topic']),
    statement: pad ? `${sentence()}\n\n  ${sentence()} ${sentence()}\t${sentence()} ${prose(2)}` : messy(sentence(rng.int(3, 30))),
    why: rng.chance(0.1) ? '' : maybe(0.5, () => messy(sentence())),
    rejectedAlternatives: Array.from({ length: rng.chance(0.3) ? rng.int(1, 3) : 0 }, () => messy(words(rng.int(2, 6)))),
    writerLine: rng.chance(0.1) ? '' : maybe(0.3, () => messy(sentence())),
    decidedBy: rng.pick(['author', 'author', 'system']),
    ideaId: idea ? `idea-${rng.int(1000, 9999)}` : rng.chance(0.05) ? '' : null,
    rejectionScope: idea ? rng.pick(SCOPES) : rng.chance(0.05) ? rng.pick(SCOPES) : null,
  };
}
const ledgerEntries = (count: number): any[] => Array.from({ length: count }, ledgerEntry);

const astralStatement = (offset: number): string => `${'x'.repeat(offset)}😀${'y'.repeat(40)} and more words to pass the limit of a turned down line of text, enough`;
const notebookCases: { entries: any[]; maxTokens?: number }[] = [
  { entries: [] },
  { entries: [{ ...ledgerEntry(), kind: 'direction', topic: 'start.brief' }] },
  { entries: [{ ...ledgerEntry(), kind: 'decision', topic: 'progress.premise' }, { ...ledgerEntry(), kind: 'decision', topic: 'progress.' }] },
  ...Array.from({ length: 6 }, () => ({ entries: ledgerEntries(rng.int(1, 8)) })),
  ...Array.from({ length: 1 }, () => ({ entries: ledgerEntries(rng.int(14, 18)) })),
  ...Array.from({ length: 1 }, () => ({ entries: ledgerEntries(rng.int(36, 40)).map((entry) => ({ ...entry, statement: dense(rng.int(20, 60)) })) })),
];
const baseMedium = ledgerEntries(8);
for (const maxTokens of [0, 400, 100000]) notebookCases.push({ entries: baseMedium, maxTokens });
const rejectedIdeas = (count: number): any[] =>
  Array.from({ length: count }, (_, index) => ({
    kind: 'rejected',
    topic: 'idea.x',
    statement: `${sentence()}   ${index}\n${sentence()}`,
    why: 'a reason that is never shown',
    rejectedAlternatives: [],
    writerLine: null,
    decidedBy: 'author',
    ideaId: `idea-${index}`,
    rejectionScope: SCOPES[index % 3],
  }));
notebookCases.push({ entries: rejectedIdeas(3) }, { entries: rejectedIdeas(10) }, { entries: rejectedIdeas(11) }, { entries: rejectedIdeas(14) });
notebookCases.push({ entries: [{ ...rejectedIdeas(1)[0], statement: 'a'.repeat(160) }] }, { entries: [{ ...rejectedIdeas(1)[0], statement: 'a'.repeat(161) }] });
notebookCases.push({ entries: [{ ...rejectedIdeas(1)[0], statement: '日'.repeat(200) }] }, { entries: [{ ...rejectedIdeas(1)[0], statement: `  ${'b'.repeat(159)} 　 c \n` }] });
for (const offset of [157, 158, 159, 100]) notebookCases.push({ entries: [{ ...rejectedIdeas(1)[0], statement: astralStatement(offset) }] });
fixture.notebook = notebookCases.map(({ entries, maxTokens }) => {
  const expected = maxTokens === undefined ? chat.renderNotebook(entries) : chat.renderNotebook(entries, maxTokens);
  return { entries, maxTokens: maxTokens ?? null, expected: strip(expected), loneSurrogate: hasLoneSurrogate(expected) };
});

const sweepLedger = ledgerEntries(5).map((entry) => ({ ...entry, statement: sentence(rng.int(2, 6)), kind: rng.pick(['decision', 'direction', 'backlog']), why: null, writerLine: null, rejectedAlternatives: [] }));
sweepLedger.push({ ...rejectedIdeas(1)[0], statement: sentence(4) });
const longSweepLedger = sweepLedger.slice(0, 3).map((entry) => ({ ...entry, statement: sentence(rng.int(14, 20)) }));
fixture.notebookSweeps = [
  { entries: sweepLedger, from: 20, count: 64 },
  { entries: longSweepLedger, from: 36, count: 40 },
].map(({ entries, from, count }) => ({
  entries,
  runs: Array.from({ length: count }, (_, index) => ({ maxTokens: from + index, expected: chat.renderNotebook(entries, from + index) })),
}));

const sweepLines = [
  [`${words(3)}`, `${words(4)}.`, '日本語の文章', `${words(2)} 😀`, words(5), 'a'],
  Array.from({ length: 7 }, (_, index) => `line ${index} ${words(rng.int(1, 3))}`),
];
fixture.fitLines = sweepLines.map((lines) => ({
  lines,
  leftOut: 'open promises — get_plot_threads lists them all',
  runs: Array.from({ length: 44 }, (_, index) => ({ maxTokens: 24 + index, expected: chat.fitLines(lines, 24 + index, 'open promises — get_plot_threads lists them all') })),
}));

function thread(index: number): any {
  const hasWindow = rng.chance(0.4);
  return {
    threadKey: `t${index}-${key()}`,
    status: rng.chance(0.8) ? 'open' : rng.pick(['closed', 'dropped']),
    summary: rng.chance(0.15) ? blank() : maybe(0.8, () => messy(sentence())),
    openedChapter: maybe(0.85, () => rng.int(1, 20)),
    lastAdvancedChapter: maybe(0.6, () => rng.int(1, 25)),
    payoffWindow: hasWindow ? rng.int(1, 30) : null,
    payoffMilestoneKey: rng.chance(0.2) ? rng.pick(['m1', 'm2', 'm3']) : rng.chance(0.03) ? '' : null,
    payoffVolumeKey: rng.chance(0.2) ? rng.pick(['v1', 'v2']) : null,
    intentionallyOpen: rng.chance(0.12),
  };
}
function mystery(index: number): any {
  const base = thread(index);
  return {
    mysteryKey: `m${index}-${key()}`,
    status: base.status === 'closed' ? 'resolved' : base.status,
    question: messy(sentence()),
    openedChapter: base.openedChapter,
    lastAdvancedChapter: base.lastAdvancedChapter,
    payoffWindow: base.payoffWindow,
    payoffMilestoneKey: base.payoffMilestoneKey,
    payoffVolumeKey: base.payoffVolumeKey,
    intentionallyOpen: base.intentionallyOpen,
  };
}
const promiseOf = (kind: string, row: any): any => ({
  kind,
  key: kind === 'thread' ? row.threadKey : row.mysteryKey,
  isOpen: row.status === 'open',
  text: kind === 'thread' ? row.summary : row.question,
  openedChapter: row.openedChapter,
  lastAdvancedChapter: row.lastAdvancedChapter,
  payoffWindow: row.payoffWindow,
  payoffMilestoneKey: row.payoffMilestoneKey,
  payoffVolumeKey: row.payoffVolumeKey,
  intentionallyOpen: row.intentionallyOpen,
});
const promiseInputs = (threads: any[], mysteries: any[]): any[] => [...threads.map((row) => promiseOf('thread', row)), ...mysteries.map((row) => promiseOf('mystery', row))];

fixture.promises = Array.from({ length: 14 }, (_, index) => {
  const count = index < 3 ? [0, 1, 2][index]! : index > 11 ? rng.int(22, 26) : rng.int(2, 14);
  const threads = Array.from({ length: Math.ceil(count / 2) }, (_, item) => thread(item));
  const mysteries = Array.from({ length: Math.floor(count / 2) }, (_, item) => mystery(item));
  const next = rng.int(1, 32);
  const milestones = [['m1', rng.pick(MILESTONE_STATES)], ['m2', rng.pick(MILESTONE_STATES)]] as [string, string][];
  const volumes = [['v1', rng.pick(VOLUME_STATES)], ['v2', rng.pick(VOLUME_STATES)]] as [string, string][];
  const expected = chat.renderPromises(threads, mysteries, next, new Map(milestones), new Map(volumes));
  return { promises: promiseInputs(threads, mysteries), next, milestones, volumes, expected };
});
fixture.payoff = Array.from({ length: 24 }, (_, index) => {
  const window = rng.chance(0.5) ? rng.int(0, 20) : null;
  const milestone = index % 3 === 0 ? rng.pick(['m1', '', null]) : null;
  const volume = index % 4 === 0 ? rng.pick(['v1', '', null]) : null;
  return { window, milestone, volume, expected: chat.payoffLabel(window, milestone, volume) };
});

function inventoryCase(size: number): any {
  const entities = Array.from({ length: size }, () => ({ entityKey: rng.chance(0.1) ? 'dup' : key(), name: messy(words(rng.int(1, 3))), type: rng.pick(['character', 'place', 'item', 'faction']), significance: rng.pick(['major', 'minor']) }));
  const pages = Array.from({ length: Math.ceil(size / 2) }, () => ({
    section: rng.pick(['project', 'plot', 'world', 'power', 'lore', 'story_state', 'ai']),
    slug: rng.pick(['premise', 'timeline', 'open-questions', 'reader-promise', 'volume-plan', `page-${rng.int(1, 40)}`, 'ünï_slug']),
    frontmatter: rng.chance(0.4) ? { title: messy(words(rng.int(1, 4))) } : rng.chance(0.1) ? { title: '  ' } : null,
  }));
  if (size > 0) pages.push({ section: 'project', slug: 'timeline', frontmatter: null }, { section: 'project', slug: 'open-questions', frontmatter: { title: 'Open questions' } });
  const facts = Array.from({ length: size }, () => ({ factKey: key(), disclosedInChapter: rng.chance(0.5) ? rng.int(1, 30) : null }));
  const milestones = Array.from({ length: Math.ceil(size / 3) }, (_, item) => ({ milestoneKey: `ms-${item}-${key()}`, label: messy(words(rng.int(1, 4))), state: rng.pick(MILESTONE_STATES) }));
  const expected = chat.renderInventory({ entities, pages, facts, worldFacts: [], milestones });
  return { entities: entities.map(({ significance, ...rest }) => ({ ...rest, isMajor: significance === 'major' })), pages, facts, milestones, expected };
}
fixture.inventory = [0, 1, 2, 4, 8, 14, 22, 30].flatMap((size) => [inventoryCase(size), ...(size > 3 && size < 10 ? [inventoryCase(size)] : [])]);
function briefRow(chapter: number): any {
  const contract = rng.pick([
    null,
    {},
    { hookType: 'cliffhanger' },
    { hookType: messy(words(2)), emotionalBeat: messy(words(3)), openQuestion: messy(sentence()), handoffState: messy(sentence()) },
    { hookType: '', openQuestion: 'x' },
  ]);
  return {
    chapter,
    title: maybe(0.8, () => messy(words(rng.int(1, 4)))),
    chapterPurpose: maybe(0.7, () => (rng.chance(0.1) ? blank() : messy(sentence()))),
    direction: maybe(0.5, () => messy(sentence())),
    body: rng.chance(0.1) ? blank() : messy(paragraph()),
    pov: maybe(0.6, () => messy(words(rng.int(1, 2)))),
    scenes: Array.from({ length: rng.chance(0.3) ? 0 : rng.int(1, 4) }, () => ({ summary: messy(sentence()), pov: rng.chance(0.5) ? messy(words(1)) : rng.chance(0.2) ? '' : null })),
    endingContract: contract,
    claimedMilestones: Array.from({ length: rng.chance(0.4) ? rng.int(1, 3) : 0 }, () => `m${rng.int(1, 9)}`),
    contentMode: maybe(0.3, () => rng.pick(['standard', 'mature', ''])),
    isEnding: rng.chance(0.15),
    guidance: maybe(0.3, () => messy(sentence())),
    revision: rng.int(1, 12),
    staleReason: rng.chance(0.25) ? rng.pick(['an earlier chapter changed', 'the premise moved']) : rng.chance(0.05) ? '' : null,
    writeMode: rng.chance(0.2) ? 'external' : 'standard',
  };
}
const briefInput = (row: any): any => ({ ...row, revision: String(row.revision) });

function chapterRow(number: number, isolated = rng.chance(0.12)): any {
  return { number, title: rng.chance(0.15) ? '' : maybe(0.8, () => messy(words(rng.int(1, 4)))), status: 'done', summary: rng.chance(0.1) ? blank() : maybe(0.7, () => messy(rng.chance(0.25) ? paragraph() : sentence())), isolated };
}
function draftRow(chapter: number, isolated = rng.chance(0.12)): any {
  return {
    chapter,
    title: maybe(0.8, () => messy(words(rng.int(1, 4)))),
    reviewStatus: rng.pick(REVIEWS),
    summary: rng.chance(0.1) ? blank() : maybe(0.7, () => messy(paragraph())),
    isolated,
    staleReason: rng.chance(0.2) ? rng.pick(['an ancestor changed', '']) : null,
  };
}
const chapterInput = ({ status, ...rest }: any): any => rest;
const draftInput = ({ reviewStatus, ...rest }: any): any => ({ ...rest, review: reviewStatus });

const walled = (row: any): any => packRender.walledOff(row, undefined);

function chapterCase(finals: number, extraDrafts: number, overlap: number): any {
  const first = rng.chance(0.3) ? rng.int(1, 3) : 1;
  const chapters = Array.from({ length: finals }, (_, index) => chapterRow(first + index + (rng.chance(0.08) ? 1 : 0)));
  const seen = new Set<number>();
  const uniqueChapters = chapters.filter((row) => (seen.has(row.number) ? false : (seen.add(row.number), true)));
  const top = uniqueChapters.length > 0 ? Math.max(...uniqueChapters.map((row) => row.number)) : 0;
  const drafts = [
    ...Array.from({ length: extraDrafts }, (_, index) => draftRow(top + 1 + index)),
    ...uniqueChapters.slice(0, overlap).map((row) => draftRow(row.number)),
  ];
  const planned = Array.from({ length: rng.int(0, 5) }, () => rng.int(1, top + 6));
  const next = chat.nextChapterNumber(uniqueChapters, drafts);
  const briefs = [briefRow(next - 1), briefRow(next)].filter(() => rng.chance(0.75));
  const readableChapters = uniqueChapters.map(walled);
  const readableDrafts = drafts.map(walled);
  return {
    chapters: uniqueChapters.map(chapterInput),
    drafts: drafts.map(draftInput),
    planned,
    briefs: briefs.map(briefInput),
    next,
    walledChapters: readableChapters.filter((row, position) => uniqueChapters[position]!.isolated).map(({ number, title, summary }: any) => ({ number, title, summary })),
    walledDrafts: readableDrafts.filter((row, position) => drafts[position]!.isolated).map(({ chapter, title, summary }: any) => ({ chapter, title, summary })),
    index: chat.renderChapterIndex(readableChapters, readableDrafts, planned),
    handoff: chat.renderHandoff(readableChapters, readableDrafts, briefs),
  };
}
fixture.chapters = [
  chapterCase(0, 0, 0),
  chapterCase(0, 1, 0),
  chapterCase(1, 0, 0),
  chapterCase(1, 0, 1),
  chapterCase(3, 1, 1),
  ...Array.from({ length: 5 }, () => chapterCase(rng.int(0, 9), rng.int(0, 3), rng.int(0, 3))),
  ...Array.from({ length: 2 }, () => chapterCase(rng.int(38, 45), rng.int(0, 2), rng.int(0, 5))),
  chapterCase(44, 1, 4),
];

fixture.awaiting = Array.from({ length: 24 }, (_, index) => {
  const awaiting = {
    continuity: index % 4 === 0 ? [] : shuffled(Array.from({ length: rng.int(0, 4) }, () => rng.int(1, 30))),
    asking: index % 3 === 0 ? [] : Array.from({ length: rng.int(0, 3) }, () => ({ chapter: rng.int(1, 12), open: rng.int(1, 3) })),
    answered: index % 5 === 0 ? [] : shuffled(Array.from({ length: rng.int(0, 3) }, () => rng.int(1, 30))),
  };
  return { awaiting, expected: chat.renderAwaitingAuthor(awaiting) };
});

const planner = policyModule.WriterDisclosurePolicy.planner();
function endingCase(spec: { row?: any; draft?: any; chapter?: number; cap?: number }): any {
  const chapter = spec.chapter ?? rng.int(1, 30);
  const cap = spec.cap ?? 700;
  const result = packRender.previousEnding({ chapter, row: spec.row, draft: spec.draft, bridge: undefined, rawIsolated: false, disclosure: planner, caps: { ending: cap, state: 800 } });
  if (result.state !== null) throw new Error('an ending case carried a continuation state');
  return { chapter, cap, row: spec.row ?? null, draft: spec.draft ?? null, expected: result.ending ? section(result.ending) : null };
}
const longProse = (): string => dense(rng.int(560, 700));
const rowOf = (content: string | null, isolated = false): any => ({ status: 'done', isolated, content, summary: maybe(0.5, () => messy(paragraph())) });
const draftOf = (body: string | null, isolated = false, staleReason: string | null = null): any => ({ body, summary: maybe(0.5, () => messy(paragraph())), state: null, isolated, staleReason });
const endingSpecs: any[] = [
  {},
  { row: rowOf('') },
  { row: rowOf(null) },
  { row: rowOf('A short ending.') },
  { row: rowOf(prose(3)) },
  { row: rowOf(longProse()) },
  { row: rowOf(dense(1100)) },
  { row: rowOf(longProse()), cap: 120 },
  { row: rowOf(longProse()), cap: 5 },
  { row: rowOf(longProse()), cap: 0 },
  { row: rowOf(`${words(700).replace(/ /g, '')}`) },
  { row: rowOf('日本語の文章です。'.repeat(250)) },
  { row: rowOf(`${prose(2)}\n\n\n\n${prose(2)}\n\n${odd()}\n\n😀😀😀`) },
  { row: rowOf(prose(2), true) },
  { row: rowOf(prose(2), true), draft: draftOf(prose(2), true) },
  { row: rowOf(longProse()), draft: draftOf(longProse(), false, 'stale') },
  { draft: draftOf(null) },
  { draft: draftOf('') },
  { draft: draftOf(prose(2)) },
  { draft: draftOf(longProse()) },
  { draft: draftOf(longProse()), cap: 150 },
  { draft: draftOf(prose(2), false, 'an ancestor changed') },
  { draft: draftOf(prose(2), false, '') },
  { draft: draftOf(longProse(), false, 'stale'), cap: 40 },
  { draft: draftOf(prose(2), true) },
  { draft: draftOf(prose(2), true, 'stale') },
  { draft: draftOf(null, true) },
  { draft: draftOf(`${'z'.repeat(3000)}`) },
];
for (let index = 0; index < 2; index++) endingSpecs.push(index % 2 === 0 ? { row: rowOf(messy(longProse())) } : { draft: draftOf(messy(prose(rng.int(1, 40))), false, rng.chance(0.3) ? 'stale' : null) });
fixture.endings = endingSpecs.map(endingCase);

interface World {
  project: any | null;
  ledger: any[];
  volumes: any[];
  threads: any[];
  mysteries: any[];
  entities: any[];
  pages: any[];
  facts: any[];
  milestones: any[];
  chapters: any[];
  drafts: any[];
  briefs: any[];
  changedVolumes: any[];
  changedBriefs: any[];
  changedDocs: any[];
  continuity: any[];
  pendingProposals: number;
}

const projected = (record: any, columns?: any): any => (columns ? Object.fromEntries(Object.keys(columns).map((name) => [name, record[name] ?? null])) : record);

function makeDb(world: World, briefCalls: ('planned' | 'stale')[]): any {
  const pending = [...briefCalls];
  const written = new Set(world.drafts.map((draft) => draft.chapter));
  const finalized = new Set(world.chapters.map((chapter) => chapter.number));
  const latest = commonExports.firstUnwrittenChapter(written, finalized) - 1;
  const next = latest + 1;
  const empty: any = new Proxy(() => empty, { get: (_, property) => (property === 'then' ? (resolve: (value: unknown[]) => void) => resolve([]) : empty), apply: () => empty });
  return {
    query: {
      projects: { findFirst: async () => world.project ?? undefined },
      decisionLedgerEntries: { findMany: async () => world.ledger },
      volumes: {
        findMany: async (args: any) => (args?.columns ? world.changedVolumes : world.volumes),
        findFirst: async () => world.volumes.find((volume) => volume.state === 'active'),
      },
      plotThreads: { findMany: async () => world.threads.filter((row) => row.status === 'open') },
      mysteries: { findMany: async () => world.mysteries.filter((row) => row.status === 'open') },
      entities: { findMany: async (args: any) => world.entities.map((row) => projected(row, args.columns)) },
      bibleDocuments: { findMany: async (args: any) => (args.columns?.revision ? world.changedDocs : world.pages.map((row) => projected(row, args.columns))) },
      canonFacts: { findMany: async (args: any) => world.facts.map((row) => projected(row, args.columns)) },
      worldFacts: { findMany: async () => [] },
      milestones: { findMany: async (args: any) => world.milestones.map((row) => projected(row, args.columns)) },
      chapters: {
        findMany: async (args: any) => world.chapters.map((row) => projected(row, args.columns)),
        findFirst: async (args: any) => {
          const row = world.chapters.find((chapter) => chapter.number === latest);
          return row ? projected(row, args.columns) : undefined;
        },
      },
      drafts: {
        findMany: async (args: any) => {
          if (args.columns.reviewStatus && args.columns.title) return world.drafts.map((row) => projected(row, args.columns));
          if (args.columns.status) return [...world.drafts].sort((left, right) => left.chapter - right.chapter).map((row) => projected(row, args.columns));
          return [];
        },
        findFirst: async (args: any) => {
          const row = world.drafts.find((draft) => draft.chapter === latest);
          return row ? projected(row, args.columns) : undefined;
        },
      },
      briefs: {
        findMany: async (args: any) => {
          if (args?.columns?.revision) return world.changedBriefs;
          if (args?.columns) {
            const call = pending.shift();
            if (call === 'planned') return world.briefs.map((row) => ({ chapter: row.chapter }));
            if (call === 'stale') return world.briefs.filter((row) => row.staleReason !== null).map((row) => ({ chapter: row.chapter }));
            throw new Error('an unexpected briefs query');
          }
          return world.briefs.filter((row) => row.chapter === latest || row.chapter === next);
        },
      },
      continuityProposals: { findMany: async () => world.continuity },
      finalizeReviews: { findMany: async () => [] },
    },
    $count: async (table: unknown) => (table === schemas.refinementProposals ? world.pendingProposals : 0),
    select: () => empty,
  };
}

function assemblerOf(db: any): any {
  const instance = Object.create(assemblerModule.ContextAssembler.prototype);
  instance.db = db;
  return instance;
}

const SESSION_START = new Date('2026-01-01T00:00:00Z');

function worldOf(options: { scale: number; isolatedLatest?: boolean; draftOnly?: boolean; noProject?: boolean; chapters?: number; pending?: boolean }): World {
  const { scale } = options;
  const volumes = Array.from({ length: rng.int(0, 3) }, (_, index) => ({
    volumeKey: `v${index + 1}`,
    ordinal: index + 1,
    title: maybe(0.7, () => messy(words(rng.int(1, 3)))),
    objective: rng.chance(0.15) ? blank() : maybe(0.8, () => messy(scale > 2 ? prose(rng.int(10, 16)) : sentence())),
    state: rng.pick(VOLUME_STATES),
    revision: rng.int(1, 9),
  }));
  const finals = options.chapters ?? rng.int(0, 6);
  const chapters = Array.from({ length: finals }, (_, index) => chapterRow(index + 1, options.isolatedLatest && index === finals - 1 ? true : rng.chance(0.1)));
  const chapterRecords = chapters.map((row) => ({ ...row, content: row.isolated ? prose(2) : messy(prose(rng.int(1, scale > 2 ? 30 : 4))) }));
  const draftChapters = options.draftOnly || (rng.chance(0.5) && !options.isolatedLatest) ? [finals + 1] : [];
  const drafts = [
    ...draftChapters.map((chapter) => ({ ...draftRow(chapter, options.draftOnly && options.isolatedLatest ? true : rng.chance(0.1)), status: 'draft', revision: rng.int(1, 5), body: prose(rng.int(1, 3)), state: null })),
    ...(finals > 0 && rng.chance(0.4) ? [{ ...draftRow(finals, false), reviewStatus: 'final', status: 'final', revision: 2, body: prose(1), state: null }] : []),
  ];
  const latestRow = chapterRecords.find((row) => row.number === finals);
  if (options.draftOnly && latestRow) {
    drafts.push({ ...draftRow(finals, options.isolatedLatest ?? false), status: 'draft', revision: 1, body: prose(rng.int(1, 3)), state: null });
    chapterRecords.splice(chapterRecords.indexOf(latestRow), 1);
  }
  const next = commonExports.firstUnwrittenChapter(new Set(drafts.map((draft) => draft.chapter)), new Set(chapterRecords.map((row) => row.number)));
  const pages = Array.from({ length: rng.int(0, 6 * scale) }, () => ({
    section: rng.pick(['project', 'plot', 'world', 'power', 'lore', 'story_state', 'ai']),
    slug: rng.pick(['premise', 'timeline', 'open-questions', 'reader-promise', `page-${rng.int(1, 60)}`, 'ünï_slug']),
    frontmatter: rng.chance(0.4) ? { title: messy(words(rng.int(1, 4))) } : null,
  })).sort((left, right) => (left.section === right.section ? (left.slug < right.slug ? -1 : left.slug > right.slug ? 1 : 0) : left.section < right.section ? -1 : 1));
  const volumeKeys = [...volumes.map((volume) => volume.volumeKey), 'v-gone'];
  const ledger = [
    ...ledgerEntries(rng.int(0, 7 * scale)).map((entry) => ({ ...entry, rejectionAnchor: entry.rejectionScope === 'not_now' ? { volumeKey: rng.pick(volumeKeys) } : null })),
    ...(rng.chance(0.6) ? [{ ...ledgerEntry(), kind: 'direction', topic: 'start.brief', statement: rng.pick(NOTES), ideaId: null, rejectionScope: null, rejectionAnchor: null }] : []),
  ];
  const briefChapters = [...new Set([next - 1, next, ...Array.from({ length: rng.int(0, 4) }, () => rng.int(1, next + 4))])].filter((chapter) => chapter > 0);
  const briefs = briefChapters.filter(() => rng.chance(0.8)).map(briefRow);
  return {
    project: options.noProject
      ? null
      : {
          title: maybe(0.8, () => messy(words(rng.int(1, 5)))),
          premise: rng.chance(0.1) ? '' : maybe(0.85, () => (scale > 2 ? prose(rng.int(46, 52)) : messy(prose(rng.int(1, 3))))),
          brief: maybe(0.4, () => messy(paragraph())),
          themes: rng.chance(0.8) ? Array.from({ length: rng.int(0, 4) }, () => messy(words(rng.int(1, 2)))) : null,
          theme: maybe(0.6, () => messy(sentence())),
          endingQuestion: maybe(0.6, () => messy(sentence())),
          ending: maybe(0.6, () => messy(paragraph())),
          readerPromise: maybe(0.6, () => messy(sentence())),
          protagonistKey: maybe(0.6, key),
          opposition: maybe(0.5, () => messy(sentence())),
          instructions: maybe(0.6, () => messy(scale > 2 ? prose(rng.int(10, 14)) : paragraph())),
          storyCurrentChapter: finals,
        },
    ledger,
    volumes,
    threads: Array.from({ length: rng.int(0, 4 * scale) }, (_, index) => thread(index)),
    mysteries: Array.from({ length: rng.int(0, 4 * scale) }, (_, index) => mystery(index)),
    entities: Array.from({ length: rng.int(0, 10 * scale) }, () => ({ entityKey: key(), name: messy(words(rng.int(1, 3))), type: rng.pick(['character', 'place', 'item']), significance: rng.pick(['major', 'minor']) })),
    pages,
    facts: Array.from({ length: rng.int(0, 8 * scale) }, () => ({ factKey: key(), disclosedInChapter: rng.chance(0.5) ? rng.int(1, 20) : null })),
    milestones: Array.from({ length: rng.int(0, 5 * scale) }, (_, index) => ({ milestoneKey: `m${index}-${key()}`, label: messy(words(rng.int(1, 4))), state: rng.pick(MILESTONE_STATES) })),
    chapters: chapterRecords,
    drafts,
    briefs,
    changedVolumes: volumes.filter(() => rng.chance(0.3)).map((volume) => ({ volumeKey: volume.volumeKey, revision: volume.revision })),
    changedBriefs: briefs.filter(() => rng.chance(0.3)).map((brief) => ({ chapter: brief.chapter, revision: brief.revision })),
    changedDocs: pages.filter(() => rng.chance(0.3)).map((page) => ({ section: page.section, slug: page.slug, revision: rng.int(1, 8) })),
    continuity: options.pending || rng.chance(0.3) ? Array.from({ length: rng.int(1, 3) }, () => ({ chapter: rng.int(1, 9) })) : [],
    pendingProposals: options.pending || rng.chance(0.3) ? rng.int(1, 6) : 0,
  };
}
function thinUp(world: World): World {
  heavyUp(world);
  world.ledger = world.ledger.slice(0, 34).concat(world.ledger.slice(-1));
  world.volumes = [];
  world.threads = [];
  world.mysteries = [];
  world.entities = [];
  world.pages = [];
  world.facts = [];
  world.milestones = [];
  world.briefs = [{ ...briefRow(latestOf(world).next), body: dense(500), staleReason: null }];
  world.changedBriefs = [];
  world.changedVolumes = [];
  world.changedDocs = Array.from({ length: 40 }, (_, index) => ({ section: 'lore', slug: `page-${String(index).padStart(3, '0')}`, revision: 3 }));
  return world;
}

function heavyUp(world: World): World {
  const dull = { ideaId: null, rejectionScope: null, rejectionAnchor: null, why: null, writerLine: null, rejectedAlternatives: [] as string[] };
  const notes = world.ledger.find((entry) => entry.topic === 'start.brief') ?? { ...ledgerEntry(), kind: 'direction', topic: 'start.brief', statement: prose(3), ...dull };
  Object.assign(world.project ?? {}, {
    premise: dense(1500),
    ending: dense(500),
    theme: dense(300),
    instructions: dense(700),
    themes: ['loss', 'duty', 'the sea'],
    storyCurrentChapter: world.chapters.length,
  });
  world.ledger = [
    ...Array.from({ length: 40 }, (_, index) => ({ ...ledgerEntry(), ...dull, kind: index % 3 === 0 ? 'direction' : 'decision', decidedBy: 'author', topic: `topic.${index}`, statement: dense(rng.int(40, 80)) })),
    ...Array.from({ length: 6 }, (_, index) => ({ ...ledgerEntry(), ...dull, kind: 'backlog', topic: `later.${index}`, statement: dense(30) })),
    notes,
  ];
  world.volumes = Array.from({ length: 4 }, (_, index) => ({ volumeKey: `v${index + 1}`, ordinal: index + 1, title: `Volume ${index + 1}`, objective: dense(400), state: VOLUME_STATES[Math.min(index, 2)], revision: index + 1 }));
  world.threads = Array.from({ length: 28 }, (_, index) => ({ ...thread(index), status: 'open' }));
  world.mysteries = Array.from({ length: 10 }, (_, index) => ({ ...mystery(index), status: 'open' }));
  world.entities = Array.from({ length: 60 }, (_, index) => ({ entityKey: `ent-${index}-${key()}`, name: messy(words(2)), type: 'character', significance: index % 4 === 0 ? 'major' : 'minor' }));
  world.pages = Array.from({ length: 30 }, (_, index) => ({ section: 'lore', slug: `page-${String(index).padStart(3, '0')}`, frontmatter: index % 2 === 0 ? { title: words(2) } : null }));
  world.facts = Array.from({ length: 30 }, (_, index) => ({ factKey: `fact-${index}-${key()}`, disclosedInChapter: index % 2 === 0 ? index : null }));
  world.milestones = Array.from({ length: 20 }, (_, index) => ({ milestoneKey: `ms-${String(index).padStart(2, '0')}`, label: words(3), state: MILESTONE_STATES[index % 3] }));
  world.changedVolumes = world.volumes.map((volume) => ({ volumeKey: volume.volumeKey, revision: volume.revision }));
  world.changedDocs = world.pages.slice(0, 24).map((page) => ({ section: page.section, slug: page.slug, revision: 3 }));
  world.changedBriefs = world.briefs.map((brief) => ({ chapter: brief.chapter, revision: brief.revision }));
  for (const brief of world.briefs) {
    brief.body = dense(250);
    brief.guidance = dense(60);
  }
  const latestRow = world.chapters.find((chapter) => chapter.number === world.chapters.length);
  if (latestRow && !latestRow.isolated) latestRow.content = dense(2500);
  return world;
}

const ledgerInput = (entry: any): any => ({
  kind: entry.kind,
  topic: entry.topic,
  statement: entry.statement,
  why: entry.why,
  rejectedAlternatives: entry.rejectedAlternatives,
  writerLine: entry.writerLine,
  decidedBy: entry.decidedBy,
  ideaId: entry.ideaId,
  rejectionScope: entry.rejectionScope,
});
const volumeInput = (row: any): any => ({ volumeKey: row.volumeKey, ordinal: row.ordinal, title: row.title, objective: row.objective, state: row.state });

function latestOf(world: World): { latest: number; next: number } {
  const next = commonExports.firstUnwrittenChapter(new Set(world.drafts.map((draft) => draft.chapter)), new Set(world.chapters.map((chapter) => chapter.number)));
  return { latest: next - 1, next };
}

function pipelineInput(world: World): any {
  return {
    storyCurrentChapter: world.project?.storyCurrentChapter ?? 0,
    drafts: [...world.drafts].sort((left, right) => left.chapter - right.chapter).map((draft) => ({ chapter: draft.chapter, review: draft.reviewStatus })),
    staleBriefChapters: world.briefs.filter((brief) => brief.staleReason !== null).map((brief) => brief.chapter),
    pendingProposals: world.pendingProposals,
    awaiting: { continuity: world.continuity.map((row) => row.chapter), asking: [], answered: [] },
  };
}

const changesInput = (world: World): any => ({
  volumes: world.changedVolumes.map((row) => ({ volumeKey: row.volumeKey, revision: String(row.revision) })),
  briefs: world.changedBriefs.map((row) => ({ chapter: row.chapter, revision: String(row.revision) })),
  docs: world.changedDocs.map((row) => ({ section: row.section, slug: row.slug, revision: String(row.revision) })),
});

async function packCase(world: World, promptTokens: number, requestTokens: number): Promise<any> {
  const db = makeDb(world, ['planned', 'stale']);
  const { latest, next } = latestOf(world);
  const filtered = await rejections.withoutLapsedRejections(db, 1n, world.ledger);
  const nextBrief = world.briefs.find((brief) => brief.chapter === next);
  const progress = world.project
    ? commonExports
        .computeProgress(
          commonExports.progressFieldsFrom(world.project, world.volumes, { chapter: next, brief: nextBrief ? { staleReason: nextBrief.staleReason } : undefined }),
          commonExports.progressOverridesFrom(world.ledger),
        )
        .map((item: any) => ({ status: item.status, label: item.label }))
    : null;
  const pack = await assemblerOf(db).forNovelChat(1n, SESSION_START, { promptTokens, requestTokens, dryRun: true });
  const row = world.chapters.find((chapter) => chapter.number === latest);
  const draft = world.drafts.find((candidate) => candidate.chapter === latest);
  const inputs = {
    story: world.project
      ? {
          title: world.project.title,
          premise: world.project.premise,
          brief: world.project.brief,
          themes: Array.isArray(world.project.themes) ? world.project.themes.filter((theme: unknown) => typeof theme === 'string') : [],
          theme: world.project.theme,
          endingQuestion: world.project.endingQuestion,
          ending: world.project.ending,
          readerPromise: world.project.readerPromise,
          protagonistKey: world.project.protagonistKey,
          opposition: world.project.opposition,
          authorInstructions: writing.writingInstructionAdditions(world.project.instructions) || null,
        }
      : null,
    progress,
    ledger: filtered.map(ledgerInput),
    authorNotes: world.ledger.find((entry) => entry.topic === 'start.brief')?.statement ?? null,
    volumes: world.volumes.map(volumeInput),
    promises: promiseInputs(world.threads.filter((row) => row.status === 'open'), world.mysteries.filter((row) => row.status === 'open')),
    entities: world.entities.map(({ significance, ...rest }) => ({ ...rest, isMajor: significance === 'major' })),
    pages: world.pages,
    facts: world.facts,
    milestones: world.milestones,
    chapters: world.chapters.map(chapterInput).map(({ content, ...rest }: any) => rest),
    drafts: world.drafts.map((draftRecord) => draftInput({ chapter: draftRecord.chapter, title: draftRecord.title, reviewStatus: draftRecord.reviewStatus, summary: draftRecord.summary, isolated: draftRecord.isolated, staleReason: draftRecord.staleReason })),
    plannedChapters: world.briefs.map((brief) => brief.chapter),
    briefs: world.briefs.filter((brief) => brief.chapter === latest || brief.chapter === next).map(briefInput),
    latestChapter: row ? { content: row.content, summary: row.summary, isolated: row.isolated } : null,
    latestDraft: draft ? { body: draft.body, summary: draft.summary, isolated: draft.isolated, staleReason: draft.staleReason } : null,
    pipeline: pipelineInput(world),
    changes: changesInput(world),
  };
  return {
    inputs: sanitize(inputs),
    promptTokens,
    requestTokens,
    expected: {
      sections: pack.sections.map(section),
      omitted: pack.omitted,
      usedTokens: pack.usedTokens,
      budgetTokens: pack.budgetTokens,
      renderedLength: pack.rendered.length,
    },
  };
}

const packWorlds: { world: World; prompt: number; request: number }[] = [];
const addPack = (options: Parameters<typeof worldOf>[0], prompt: number, request: number): void => {
  packWorlds.push({ world: worldOf(options), prompt, request });
};
addPack({ scale: 1, chapters: 0 }, 3000, 400);
addPack({ scale: 1, chapters: 3 }, 3000, 400);
addPack({ scale: 1, chapters: 4, isolatedLatest: true }, 3000, 400);
packWorlds.push({ world: heavyUp(worldOf({ scale: 1, chapters: 32 })), prompt: 18000, request: 2000 });
packWorlds.push({ world: thinUp(worldOf({ scale: 1, chapters: 6 })), prompt: 18000, request: 2000 });
addPack({ scale: 2, chapters: 3, draftOnly: true }, 3000, 400);
addPack({ scale: 1, chapters: 2, draftOnly: true, isolatedLatest: true }, 3000, 400);
addPack({ scale: 2, noProject: true, chapters: 2 }, 3000, 400);
addPack({ scale: 2, chapters: 5, pending: true }, 12000, 1500);

fixture.packs = [];
for (const { world, prompt, request } of packWorlds) (fixture.packs as unknown[]).push(await packCase(world, prompt, request));

fixture.pipeline = [];
fixture.changes = [];
for (let index = 0; index < 14; index++) {
  const world = worldOf({ scale: 1, chapters: rng.int(0, 8), pending: index % 3 === 0 });
  const db = makeDb(world, ['stale']);
  const status = await assemblerOf(db).renderPipelineStatus(1n, world.project?.storyCurrentChapter ?? 0);
  (fixture.pipeline as unknown[]).push({ pipeline: sanitize(pipelineInput(world)), expected: status });
  const changed = await assemblerOf(makeDb(world, [])).changedSince(1n, SESSION_START);
  (fixture.changes as unknown[]).push({ changes: sanitize(changesInput(world)), expected: changed });
}

fixture.constants = {
  requestBudget: chat.NOVEL_CHAT_REQUEST_BUDGET,
  packFloor: chat.NOVEL_CHAT_PACK_FLOOR,
  packMargin: chat.NOVEL_CHAT_PACK_MARGIN,
  messageAllowance: chat.NOVEL_CHAT_MESSAGE_ALLOWANCE,
  historyAllowance: assemblerModule.NOVEL_CHAT_HISTORY_ALLOWANCE,
  caps: chat.NOVEL_CHAT_SECTION_CAPS,
  labels: { ending: chat.ENDING_PLANNER_ONLY_LABEL, endingQuestion: chat.ENDING_QUESTION_PLANNER_ONLY_LABEL, laterVolume: chat.LATER_VOLUME_GOAL_LABEL },
  previousEndingTail: packRender.PREV_ENDING_TAIL,
  turnedDownLimit: chat.TURNED_DOWN_LIMIT,
};

writeFileSync(join(outDir, 'chat-context.json'), `${JSON.stringify(sanitize(fixture))}\n`);
