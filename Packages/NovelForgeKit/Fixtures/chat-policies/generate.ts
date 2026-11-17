import { plugin } from 'bun';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');

const server = join(platformRepo, 'apps/novel-forge-server/src');
const outDir = dirname(fileURLToPath(import.meta.url));
const classes = await import(join(server, 'classes/app-error-code.ts'));
const progress = await import(join(server, 'common/progress.ts'));
const docTitle = await import(join(server, 'common/bible-doc-title.ts'));
const briefScenes = await import(join(server, 'common/brief-scenes.ts'));
const unlockCondition = await import(join(server, 'common/unlock-condition.ts'));
const paragraphs = await import(join(platformRepo, 'packages/sdk/src/prose-paragraphs.ts'));
const organise = await import(join(platformRepo, 'packages/sdk/src/organise.ts'));

const noop = () => undefined;
const columns = (table: string): unknown => new Proxy({}, { get: (_, column) => `${table}.${String(column)}` });
const schema = new Proxy({}, { get: (_, table) => columns(String(table)) });

plugin({
  name: 'chat-policies-fixture-stubs',
  setup(build) {
    build.module('@server/classes', () => ({ exports: { AppErrorCode: classes.AppErrorCode }, loader: 'object' }));
    build.module('@server/common', () => ({
      exports: { PROGRESS_ITEM_KEYS: progress.PROGRESS_ITEM_KEYS, deriveBibleDocTitle: docTitle.deriveBibleDocTitle, computeContentHash: noop,
        validateBriefScenes: briefScenes.validateBriefScenes,
        validateUnlockCondition: unlockCondition.validateUnlockCondition,
      },
      loader: 'object',
    }));
    build.module('@server/database', () => ({ exports: { schema }, loader: 'object' }));
    build.module('@server/database/schemas', () => ({ exports: {}, loader: 'object' }));
    build.module('@shadow-library/sdk', () => ({ exports: { paragraphAt: paragraphs.paragraphAt, TIMELINE_BAND_LABELS: organise.TIMELINE_BAND_LABELS }, loader: 'object' }));
    build.module('drizzle-orm', () => ({
      exports: {
        and: (...parts: unknown[]) => ({ and: parts }),
        eq: (column: string, value: unknown) => ({ column, value }),
        inArray: (column: string, values: unknown[]) => ({ column, values }),
        sql: noop,
      },
      loader: 'object',
    }));
  },
});

const refinement = join(server, 'modules/refinement');
const passage = await import(join(refinement, 'passage-context.ts'));
const anchor = await import(join(server, 'modules/generation/passage-anchor.ts'));
const question = await import(join(refinement, 'chat-question.ts'));
const proseIntent = await import(join(refinement, 'prose-intent.ts'));
const laterPlans = await import(join(refinement, 'later-plans-guard.ts'));
const plannerOnly = await import(join(refinement, 'planner-only-guard.ts'));
const selection = await import(join(refinement, 'chat-selection.ts'));
const defaults = await import(join(server, 'modules/ai/defaults.ts'));
const turnProposals = await import(join(refinement, 'turn-proposals.ts'));

const negationFixRequest = ((): ((warnings: string[]) => string) => {
  const source = readFileSync(join(refinement, 'chat.service.ts'), 'utf8');
  const head = 'function negationFixRequest(warnings: string[]): string {';
  const from = source.indexOf(head);
  if (from === -1) throw new Error('negationFixRequest not found');
  const end = source.indexOf('\n}\n', from);
  if (end === -1) throw new Error('negationFixRequest has no closing brace');
  const body = source.slice(from + head.length, end);
  return new Function('warnings', body) as (warnings: string[]) => string;
})();

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
    chance: p => next() < p,
    pick: items => items[Math.floor(next() * items.length)] as never,
  };
}

type Str = string | number[];
type Rec = Record<string, unknown>;

const encode = (value: string): Str => (value.isWellFormed() ? value : Array.from({ length: value.length }, (_, i) => value.charCodeAt(i)));
const write = (name: string, value: unknown): void => writeFileSync(join(outDir, name), JSON.stringify(value) + '\n');

const WORDS = [
  'lantern', 'marsh', 'oath', 'queen', 'Tower', '😀', '𠀀', 'café', 'éclair', 'Å', '王国', 'ひかり', 'ﬁre', 'straße', 'İstanbul', 'ΟΔΟΣ', 'the', 'a', "don't", 'mara’s', '42', '\u{1d11e}',
];
const SPACES = [' ', ' ', ' ', '  ', '\t', ' ', ' ', '　'];
const BREAKS = ['\n\n', '\n\n', '\n', '\r\n\r\n', '\r\n', '\n\n\n', ' ', '\n \n', '\r\r'];
const PUNCT = ['', '', '.', ',', '!', '…', '?', ' —', ';'];

function sentence(rng: Rng): string {
  const count = rng.int(1, 9);
  let text = '';
  for (let index = 0; index < count; index++) text += (index ? rng.pick(SPACES) : '') + rng.pick(WORDS) + rng.pick(PUNCT);
  return text;
}

function bodyText(rng: Rng): string {
  const count = rng.int(1, 8);
  let text = rng.chance(0.08) ? rng.pick(BREAKS) : '';
  for (let index = 0; index < count; index++) text += sentence(rng) + (index < count - 1 ? rng.pick(BREAKS) : rng.chance(0.3) ? rng.pick(BREAKS) : '');
  return text;
}

const COMMENTS = ['', ' ', 'tighten this', '  make it sadder\n', 'line one\nline two', 'crlf\r\nbreak', ' ﻿', '😀 why', 'é', '\n', ' \n spaced \n '];

function quoteSlice(rng: Rng, text: string): [number, number] {
  const units = text.length;
  if (units < 2) return [0, units];
  const start = rng.int(0, units - 1);
  const end = Math.min(units, start + rng.int(1, 60));
  return [start, end];
}

function wellFormedSlice(rng: Rng, text: string): [number, number] {
  for (let attempt = 0; attempt < 20; attempt++) {
    const [start, end] = quoteSlice(rng, text);
    if (text.slice(start, end).isWellFormed()) return [start, end];
  }
  return [0, text.length];
}

interface DraftRow {
  id: string;
  chapter: number;
  revision: number;
  saveSeq: number;
  body: string;
  isolated: boolean;
}

interface Revision {
  draftId: string;
  revision: number;
  body: string;
}

function runResolve(inputs: Rec[], drafts: DraftRow[], revisions: Revision[]): unknown {
  const fake = {
    query: {
      drafts: { findMany: async (options: { where: { and: Rec[] } }) => {
        const chapters = (options.where.and.find(part => part.column === 'drafts.chapter')?.values ?? []) as number[];
        return drafts.filter(draft => chapters.includes(draft.chapter));
      } },
      draftRevisions: { findFirst: async (options: { where: { and: Rec[] } }) => {
        const id = options.where.and.find(part => part.column === 'draftRevisions.draftId')?.value;
        const revision = options.where.and.find(part => part.column === 'draftRevisions.revision')?.value;
        const found = revisions.find(row => row.draftId === id && row.revision === revision);
        return found ? { body: found.body } : undefined;
      } },
    },
  };
  return (async () => {
    try {
      const contexts = await passage.resolvePassageContexts(fake, 1n, inputs);
      return { contexts: contexts.map(encodeContext) };
    } catch (error) {
      const failure = error as { code: string; message: string };
      return { error: failure.code, chapter: Number(/chapter (\d+)/i.exec(failure.message)?.[1]) };
    }
  })();
}

function encodeContext(context: Rec): Rec {
  return { ...context, quote: encode(context['quote'] as string), comment: encode(context['comment'] as string) };
}

function makeInput(chapter: number, draftId: string, revision: number, body: string, start: number, end: number, comment: string): Rec {
  const quote = body.slice(start, end);
  return {
    kind: 'passage',
    chapter,
    draftId,
    revision,
    saveSeq: 3,
    start,
    end,
    passageHash: anchor.passageHash(quote),
    quote: encode(quote),
    comment: encode(comment),
  };
}

type Resolve = { inputs: Rec[]; drafts: DraftRow[]; revisions: Revision[]; expected: unknown; unrepresentable?: true };

const resolves: Resolve[] = [];
const relocations: { body: Str; input: Rec; earlier: Str | null; expected: { start: number; end: number } | null }[] = [];

function decoded(value: unknown): string {
  return Array.isArray(value) ? String.fromCharCode(...(value as number[])) : (value as string);
}

function addRelocation(body: string, input: Rec, earlier: string | undefined): void {
  const live = { ...input, quote: decoded(input['quote']) };
  relocations.push({ body: encode(body), input, earlier: earlier === undefined ? null : encode(earlier), expected: passage.relocateQuote(body, live, earlier) });
}

async function addResolve(inputs: Rec[], drafts: DraftRow[], revisions: Revision[]): Promise<void> {
  const live = inputs.map(input => ({ ...input, quote: decoded(input['quote']), comment: decoded(input['comment']) }));
  const unrepresentable = live.some(input => !(input['comment'] as string).isWellFormed());
  resolves.push({ inputs, drafts, revisions, expected: await runResolve(live, drafts, revisions), ...(unrepresentable ? { unrepresentable: true as const } : {}) });
}

const mutations = ['same', 'prefix', 'suffix', 'delete', 'duplicate', 'replace', 'edit-before', 'swap-context', 'shorten', 'empty'] as const;

function mutate(rng: Rng, kind: (typeof mutations)[number], body: string, start: number, end: number): string {
  const quote = body.slice(start, end);
  switch (kind) {
    case 'same': return body;
    case 'prefix': return sentence(rng) + '\n\n' + body;
    case 'suffix': return body + rng.pick(BREAKS) + sentence(rng);
    case 'delete': return body.slice(0, start) + body.slice(end);
    case 'duplicate': return body + '\n\n' + quote;
    case 'replace': return body.slice(0, start) + sentence(rng) + body.slice(end);
    case 'edit-before': return body.slice(0, Math.max(0, start - 3)) + 'XY' + body.slice(Math.max(0, start - 3));
    case 'swap-context': return sentence(rng) + ' ' + quote + ' ' + sentence(rng);
    case 'shorten': return body.slice(0, Math.max(0, Math.floor((start + end) / 2)));
    case 'empty': return '';
  }
}

async function generatePassages(): Promise<void> {
  const rng = createRng(0x70a55a6e);
  for (let index = 0; index < 120; index++) {
    const earlier = bodyText(rng);
    let [start, end] = wellFormedSlice(rng, earlier);
    if (rng.chance(0.35)) {
      while (start > 0 && /\s/.test(earlier[start - 1] as string) && rng.chance(0.8)) start--;
      while (end < earlier.length && /\s/.test(earlier[end] as string) && rng.chance(0.8)) end++;
    }
    const kind = rng.pick(mutations);
    const current = mutate(rng, kind, earlier, start, end).toWellFormed();
    const draftRevision = rng.int(1, 6);
    const inputRevision = rng.chance(0.5) ? draftRevision : rng.int(1, draftRevision);
    const useSnapshot = rng.chance(0.75);
    const input = makeInput(rng.int(1, 4), '11', inputRevision, earlier, start, end, rng.pick(COMMENTS));
    if (rng.chance(0.1)) input['passageHash'] = anchor.passageHash(decoded(input['quote']) + 'x');
    if (rng.chance(0.05)) input['end'] = (input['end'] as number) + 1;
    const drafts: DraftRow[] = [{ id: '11', chapter: input['chapter'] as number, revision: draftRevision, saveSeq: rng.int(0, 40), body: current, isolated: rng.chance(0.05) }];
    if (rng.chance(0.2)) drafts.push({ id: '12', chapter: (input['chapter'] as number) + 1, revision: 2, saveSeq: 0, body: bodyText(rng), isolated: false });
    if (rng.chance(0.07)) input['draftId'] = '99';
    const revisions: Revision[] = useSnapshot ? [{ draftId: '11', revision: inputRevision, body: earlier }] : [];
    await addResolve([input], drafts, revisions);
    addRelocation(current, input, inputRevision < draftRevision && useSnapshot ? earlier : undefined);
    if (rng.chance(0.3)) addRelocation(current, input, earlier);
    if (rng.chance(0.15)) addRelocation(current, input, undefined);
  }
}

async function handcraftedPassages(): Promise<void> {
  const body = 'Alpha beta.\n\nThe 😀 lamp burned low. She walked on.\r\n\r\nCafé éclair 𠀀 end.\n\nTail.';
  const draft = (patch: Partial<DraftRow> = {}): DraftRow => ({ id: '5', chapter: 2, revision: 4, saveSeq: 9, body, isolated: false, ...patch });
  const at = (text: string): [number, number] => [body.indexOf(text), body.indexOf(text) + text.length];
  const input = (text: string, patch: Rec = {}, revision = 4): Rec => {
    const [start, end] = at(text);
    return { ...makeInput(2, '5', revision, body, start, end, 'note'), ...patch };
  };

  await addResolve([], [draft()], []);
  await addResolve([input('lamp burned low.')], [draft()], []);
  await addResolve([input('😀 lamp')], [draft()], []);
  await addResolve([input('\r\n\r\nCafé')], [draft()], []);
  await addResolve([input('  Café éclair 𠀀 end.\n\n'.trim())], [draft()], []);
  await addResolve([input('lamp'), input('Tail.', { comment: '  trimmed comment \n' })], [draft()], []);
  await addResolve([input('Alpha'), input('Tail.', { chapter: 3 })], [draft()], []);
  await addResolve([input('Alpha', { draftId: '6' })], [draft()], []);
  await addResolve([input('Alpha')], [draft({ isolated: true })], []);
  await addResolve([input('Alpha', { quote: '   ', end: 6 })], [draft()], []);
  await addResolve([input('Alpha', { passageHash: 'bad' })], [draft()], []);
  await addResolve([input('Alpha', { end: 3 })], [draft()], []);
  await addResolve([input('Alpha', { comment: [0x68, 0x69, 0xd83d] })], [draft()], []);
  await addResolve([input('Tail.'), input('Alpha', { comment: [0xdc00] })], [draft({ isolated: true })], []);

  const shifted = 'Intro line.\n\n' + body;
  await addResolve([input('lamp burned low.', {}, 3)], [draft({ body: shifted })], []);
  await addResolve([input('lamp burned low.', {}, 3)], [draft({ body: shifted })], [{ draftId: '5', revision: 3, body }]);
  const twice = body + '\n\n' + 'lamp burned low.';
  await addResolve([input('lamp burned low.', {}, 3)], [draft({ body: twice })], []);
  await addResolve([input('lamp burned low.', {}, 3)], [draft({ body: twice })], [{ draftId: '5', revision: 3, body }]);
  await addResolve([input('lamp burned low.', {}, 3)], [draft({ body: body.replace('lamp burned low.', 'x') })], [{ draftId: '5', revision: 3, body }]);

  const split = body.indexOf('😀') + 1;
  const half = body.slice(split - 3, split);
  const [halfStart, halfEnd] = [split - 3, split];
  await addResolve(
    [{ kind: 'passage', chapter: 2, draftId: '5', revision: 4, saveSeq: 1, start: halfStart, end: halfEnd, passageHash: anchor.passageHash(half), quote: encode(half), comment: encode('c') }],
    [draft()],
    [],
  );
  const tailHalf = body.slice(split, split + 4);
  await addResolve(
    [{ kind: 'passage', chapter: 2, draftId: '5', revision: 4, saveSeq: 1, start: split, end: split + 4, passageHash: anchor.passageHash(tailHalf), quote: encode(tailHalf), comment: encode('c') }],
    [draft()],
    [],
  );
  await addResolve(
    [{ kind: 'passage', chapter: 2, draftId: '5', revision: 3, saveSeq: 1, start: halfStart, end: halfEnd, passageHash: anchor.passageHash(half), quote: encode(half), comment: encode('c') }],
    [draft({ body: shifted })],
    [{ draftId: '5', revision: 3, body }],
  );
  await addResolve(
    [{ kind: 'passage', chapter: 2, draftId: '5', revision: 4, saveSeq: 1, start: halfStart, end: halfEnd, passageHash: anchor.passageHash(half), quote: encode(half), comment: encode('c') }, input('Tail.', { chapter: 9 })],
    [draft()],
    [],
  );

  const paragraphs3 = 'One.\n\nTwo two.\n\n   Three three.\n\nFour.';
  const spanned = paragraphs3.slice(paragraphs3.indexOf('Two'), paragraphs3.indexOf('Four') + 4);
  const paddedQuote = '\n\n' + spanned + '\n\n';
  const paddedBody = 'One.' + paddedQuote;
  const paddedStart = 4;
  await addResolve(
    [{ kind: 'passage', chapter: 1, draftId: '1', revision: 1, saveSeq: 0, start: paddedStart, end: paddedStart + paddedQuote.length, passageHash: anchor.passageHash(paddedQuote), quote: paddedQuote, comment: '  c  ' }],
    [{ id: '1', chapter: 1, revision: 1, saveSeq: 0, body: paddedBody, isolated: false }],
    [],
  );
  await addResolve(
    [{ kind: 'passage', chapter: 1, draftId: '1', revision: 1, saveSeq: 0, start: 0, end: 4, passageHash: anchor.passageHash('One.'), quote: 'One.', comment: '' }],
    [{ id: '1', chapter: 1, revision: 1, saveSeq: 0, body: 'One.', isolated: false }],
    [],
  );
  await addResolve(
    [{ kind: 'passage', chapter: 1, draftId: '1', revision: 1, saveSeq: 0, start: 0, end: 4, passageHash: anchor.passageHash('One.'), quote: 'One.', comment: '' }],
    [{ id: '1', chapter: 1, revision: 1, saveSeq: 0, body: '', isolated: false }],
    [],
  );
}

function contextRecord(rng: Rng): Rec {
  const quote = rng.pick(['The lamp', 'a\nb', 'x\r\ny\nz', '😀', ' padded ', 'line\n\nline', '', 'é']);
  return {
    kind: 'passage',
    chapter: rng.int(1, 30),
    draftId: String(rng.int(1, 9)),
    revision: rng.int(1, 12),
    saveSeq: rng.int(0, 99),
    start: rng.int(0, 5000),
    end: rng.int(0, 9000),
    passageHash: 'h',
    quote: encode(quote),
    comment: encode(rng.pick(['', 'change this', 'two\nlines', 'cr\r\nlf', '  ', '😀 note'])),
    firstParagraph: rng.int(1, 8),
    lastParagraph: rng.int(1, 8),
  };
}

function renderCases(): Rec[] {
  const rng = createRng(0x2e17d3);
  const contents = ['', ' ', 'Please tighten.', '  spaced  ', 'two\nlines', ' ', '﻿ ', 'crlf\r\nline', '😀 emoji', 'é', '\n\n'];
  const cases: Rec[] = [];
  for (let index = 0; index < 60; index++) {
    const shape = rng.int(0, 5);
    const contexts = shape === 0 ? null : shape === 1 ? [] : Array.from({ length: rng.int(1, 4) }, () => contextRecord(rng));
    const content = rng.pick(contents);
    const live = contexts === null ? null : contexts.map(context => ({ ...context, quote: decoded(context['quote']), comment: decoded(context['comment']) }));
    cases.push({
      content: encode(content),
      contexts,
      undefinedContexts: contexts === null && rng.chance(0.5),
      rendered: encode(passage.renderTurnContent(content, live)),
      authorWords: encode(passage.authorWords(content, live)),
      screens: passage.turnScreens(content, live ?? undefined).map((screen: Rec) => ({ ...screen, text: encode(screen['text'] as string) })),
    });
  }
  return cases;
}

function questionCases(): Rec {
  const rng = createRng(0x51e57);
  const keys = [...progress.PROGRESS_ITEM_KEYS] as string[];
  const allowedPools: string[][] = [keys, [], [''], ['premise'], ['premise', 'theme'], [...keys, '']];
  const titles = ['Keep the oath', 'Break it', '  ', '', ' ', ' ', 'A very long option title that goes on and on and on past the sixty character history clip', '😀 Fire', 'éclair', 5, null, true, ['x']];
  const whys = ['Because.', '', 'Because. Also this one is quite long, which matters nowhere here.', 5, null, ['x'], { a: 1 }];
  const answer = (): unknown => {
    const shape = rng.int(0, 9);
    if (shape === 0) return rng.pick([null, 'text', 4, [], true]);
    const out: Rec = { title: rng.pick(titles) };
    if (rng.chance(0.5)) out['why'] = rng.pick(whys);
    if (rng.chance(0.4)) out['tradeOff'] = rng.pick(whys);
    if (rng.chance(0.4)) out['recommended'] = rng.pick([true, false, 'true', 1, null]);
    if (rng.chance(0.15)) out['extra'] = 1;
    return out;
  };
  const questionTexts = [
    'Which way?', '  ', '', 'What should the oath cost the queen? It must matter. Think about the marsh and the river and the tower and the lantern and all of it together.',
    '日本語の質問です。これは長い。' + 'あ'.repeat(170), 'ends with a very long unbroken run ' + 'x'.repeat(190), 'Sentence one. Sentence two! Sentence three? ' + 'word '.repeat(40), 'é 😀?', 7, null,
  ];
  const sanitize: Rec[] = [];
  const history: Rec[] = [];
  const goodTitles = titles.filter(title => typeof title === 'string' && title.trim().length > 0);
  const goodAnswer = (): Rec => {
    const out: Rec = { title: rng.pick(goodTitles) };
    if (rng.chance(0.5)) out['why'] = rng.pick(whys);
    if (rng.chance(0.4)) out['tradeOff'] = rng.pick(whys);
    if (rng.chance(0.4)) out['recommended'] = rng.pick([true, false, 'true', 1, null]);
    return out;
  };
  const candidate = (): unknown => {
    if (rng.chance(0.45)) {
      const out: Rec = { question: rng.pick(questionTexts.filter(text => typeof text === 'string' && text.trim().length > 0)) };
      if (rng.chance(0.5)) out['why'] = rng.pick(whys);
      out['answers'] = Array.from({ length: rng.int(1, 5) }, goodAnswer);
      if (rng.chance(0.6)) out['progressKey'] = rng.pick([...keys, 'unknown', '', 'Premise']);
      if (rng.chance(0.1)) out['extra'] = [1];
      return out;
    }
    const shape = rng.int(0, 11);
    if (shape === 0) return rng.pick([null, 'text', 4, [], true, [{ question: 'q' }]]);
    const out: Rec = {};
    if (rng.chance(0.93)) out['question'] = rng.pick(questionTexts);
    if (rng.chance(0.5)) out['why'] = rng.pick(whys);
    if (rng.chance(0.93)) out['answers'] = shape === 1 ? rng.pick([null, 'ab', {}, 3]) : Array.from({ length: rng.int(0, 5) }, answer);
    if (rng.chance(0.5)) out['progressKey'] = rng.pick([...keys, 'unknown', '', 5, null, 'Premise']);
    if (rng.chance(0.1)) out['extra'] = [1];
    return out;
  };
  for (let index = 0; index < 110; index++) {
    const value = candidate();
    const allowed = rng.pick(allowedPools);
    const text = JSON.stringify(value);
    sanitize.push({ candidate: text, allowed, expected: JSON.stringify(question.sanitizeChatQuestion(value, allowed) ?? null) });
    history.push({ question: text, expected: question.renderQuestionForHistory(value) });
  }
  sanitize.push({ candidate: null, allowed: keys, expected: 'null' });
  history.push({ question: null, expected: null });
  return { wire: JSON.stringify(question.CHAT_QUESTION_WIRE_SCHEMA), sanitize, history };
}

function opPool(rng: Rng): Rec {
  const ops = [
    'draft.update', 'draft.remove', 'draft.rewrite_passage', 'action.revise_draft', 'action.approve_draft', 'action.judge_draft', 'action.finalize', 'brief.update', 'premise.update',
    'action.generate_chapter', 'fact.upsert', 'bible_document.upsert', 'unknown.op', 'DRAFT.UPDATE', 5, null,
  ];
  const op: Rec = { op: rng.pick(ops) };
  if (rng.chance(0.75)) op['chapter'] = rng.pick([1, 2, 3, 5, 5.5, 0, -1, '2', null, 1e21]);
  if (rng.chance(0.4)) op['upTo'] = rng.pick([1, 2, 3, 4, 10, '3', null, 2.5]);
  return op;
}

function proseIntentCases(): Rec {
  const rng = createRng(0x9120);
  const cases: Rec[] = [];
  for (let index = 0; index < 70; index++) {
    const changeSet = Array.from({ length: rng.int(0, 7) }, () => opPool(rng));
    const { kept, withheld } = proseIntent.withoutProseEditOps(changeSet);
    cases.push({
      changeSet,
      isProse: changeSet.map(op => proseIntent.isProseEditOp(op)),
      issues: proseIntent.proseEditIssues(changeSet),
      note: proseIntent.proseWithheldNote(changeSet),
      kept: kept.map((op: Rec) => changeSet.indexOf(op)),
      withheld,
    });
  }
  cases.push({ changeSet: null, isProse: [], issues: proseIntent.proseEditIssues(undefined), note: proseIntent.proseWithheldNote([]), kept: [], withheld: 0 });
  return {
    ops: [...proseIntent.PROSE_EDIT_OPS],
    notes: { withheld: proseIntent.PROSE_EDIT_WITHHELD_NOTE, passage: proseIntent.PASSAGE_EDIT_WITHHELD_NOTE },
    cases,
  };
}

const SECTIONS = ['project', 'story_state', 'plot', 'world', 'power', 'lore', 'ai'];
const SLUGS = ['timeline', 'open-questions', 'volume-plan', 'volumes', 'escalation-map', 'premise', 'later-plans', 'my_plans', 'future--events', 'notes', 'harbour', 'plan', 'roadmap-2', 'story-plans', 'what-happens-next'];
const TITLES = [
  'Plans', 'The plans', 'my plan', 'Our planned chapters', 'Story roadmap', "Author's plans", 'authors plan', 'Authors plans', 'Upcoming events', 'Future plans', 'Later arcs', 'future beats',
  'What happens next', 'what happens later', 'Battle plans of the north', 'The future city', 'plansible', 'Plan', 'PLANNED', 'The  plans', 'The\tplans', 'Later events', 'Planetfall', 'Roadmap.',
  'Harbour', '  Plans  ', 'The Plans of Mara', 'ｐlans', 'author’s plans',
];
const BODIES = [
  '# Plans\n\nlater', '# The harbour\n\ntext', 'no heading', '#\nPlans\nmore', '#  \nBattle plans', '## Plans', '#Plans', 'intro\n# Roadmap\nx', 'intro\r\n# Roadmap\r\nx', '# Roadmap\r\n',
  'a # Roadmap', '# \t \n', '#  Future plans ', '   # Plans', '#\n\n\n', '# Plans more', '\n# Planned', 'x # Plans', '# 😀 plans', '# ', '#\t', '# a\n# Plans',
  'intro\n#', 'intro#', '#', 'a\r# Plans', '\r#\rPlans', 'a\u2028#\u2028Plans', 'a\u2029# Plans', '# Plans\u2028# Roadmap', '#\u2029', '# One\n# Roadmap\n# Plans', '#\n#\nPlans',
];

function planOp(rng: Rng): Rec {
  const op: Rec = { op: rng.chance(0.85) ? 'bible_document.upsert' : rng.pick(['bible_document.remove', 'brief.update', 'action.organise_notes', 'fact.upsert']) };
  if (rng.chance(0.93)) op['section'] = rng.chance(0.95) ? rng.pick(SECTIONS) : rng.pick([5, null]);
  if (rng.chance(0.93)) op['slug'] = rng.chance(0.95) ? rng.pick(SLUGS) : rng.pick([5, null]);
  const frontmatter = rng.int(0, 5);
  if (frontmatter === 0) op['frontmatter'] = { title: rng.pick(TITLES) };
  else if (frontmatter === 1) op['frontmatter'] = { title: rng.pick(['', '   ', 5, null]) };
  else if (frontmatter === 2) op['frontmatter'] = rng.pick([null, [], 'Plans', 3, {}]);
  if (rng.chance(0.7)) op['body'] = rng.chance(0.9) ? rng.pick(BODIES) : rng.pick([5, null]);
  return op;
}

function laterPlanCases(): Rec {
  const rng = createRng(0x1a7e6);
  const leads = [
    'Here are my notes for the story.', '  here are my notes for the story. A hero', '\n\tOrganise my notes', 'ORGANIZE MY NOTES please', 'organise my notes', 'Please organise my notes', 'here are my notes',
    ' ﻿here are my notes for the story.', 'İ organise my notes', 'organise  my notes', '', '   ', 'Here are my notes for the story!', 'organize my notes ', ' organise my notes',
  ];
  const issues: Rec[] = [];
  const pages: Rec[] = [];
  for (let index = 0; index < 110; index++) {
    const changeSet = Array.from({ length: rng.int(0, 5) }, () => planOp(rng));
    if (rng.chance(0.1)) changeSet.splice(0, changeSet.length, { op: 'action.organise_notes' });
    const organiseRequest = rng.chance(0.3);
    const absent = rng.chance(0.05);
    issues.push({ changeSet: absent ? null : changeSet, organiseRequest, expected: laterPlans.laterPlanIssues(absent ? undefined : changeSet, organiseRequest) });
    for (const op of changeSet) pages.push({ op, expected: laterPlans.writesPlansOnWriterPage(op) });
  }
  const routing: Rec[] = [];
  const replies = ['Done.', '', 'Line\nbreak', '😀'];
  for (let index = 0; index < 30; index++) {
    const shape = rng.int(0, 4);
    const output: Rec = { reply: rng.pick(replies) };
    if (shape !== 0) output['changeSet'] = shape === 1 ? [{ op: 'action.organise_notes' }] : shape === 2 ? [] : Array.from({ length: rng.int(1, 4) }, () => planOp(rng));
    if (rng.chance(0.4)) output['question'] = { question: 'Which?' };
    for (const mode of ['none', 'card', 'start']) routing.push({ output, mode, expected: laterPlans.withLaterPlansRouted(output, mode) });
  }
  return {
    leads: leads.map(message => ({ message: encode(message), expected: laterPlans.isNotesOrganiseRequest(message) })),
    routing: [false, true].flatMap(request => ['auto', 'manual'].flatMap(mode => [false, true].map(discussing => ({ request, mode, discussing, expected: laterPlans.organiseRouting(request, mode, discussing) })))),
    issues,
    pages,
    staged: routing,
    constants: {
      headings: laterPlans.LATER_BAND_HEADINGS,
      organiseOp: laterPlans.ORGANISE_NOTES_OP,
      routedNote: laterPlans.ORGANISE_ROUTED_NOTE,
      cardNote: laterPlans.ORGANISE_CARD_NOTE,
      withheldNote: laterPlans.PLANS_WITHHELD_NOTE,
    },
  };
}

function plannerOnlyCases(): Rec {
  const tools = ['get_notes', 'get_bible_document', 'get_entity', 'get_draft', '', 'GET_NOTES'];
  const argsPool: unknown[] = [
    undefined, null, 'x', 5, [], {}, { section: 'project', slug: 'timeline' }, { section: 'project', slug: 'open-questions' }, { section: 'project', slug: 'premise' },
    { section: 'story_state', slug: 'volumes' }, { section: 'project' }, { slug: 'timeline' }, { section: 5, slug: 'timeline' }, { section: 'project', slug: null }, { section: 'Project', slug: 'timeline' },
    { section: 'project', slug: 'timeline', extra: 1 },
  ];
  const reads = tools.flatMap(tool => argsPool.map(args => ({ tool, args: args === undefined ? { absent: true } : { value: args }, expected: plannerOnly.readsPlannerOnlyPage(tool, args) })));
  const warnings = [[], ['a'], [plannerOnly.PLANNER_ONLY_WARNING], ['a', plannerOnly.PLANNER_ONLY_WARNING, 'b'], [plannerOnly.PLANNER_ONLY_WARNING + ' '], ['This turn drew on your notes']];
  const turns = [false, true].flatMap(read => warnings.map(list => ({ warnings: list, read, expected: plannerOnly.chatTurnWarnings(list, read) })));
  return { reads, turns, warning: plannerOnly.PLANNER_ONLY_WARNING, tools: [plannerOnly.PLANNER_ONLY_LOOKUP_TOOL, plannerOnly.AUTHOR_NOTES_LOOKUP_TOOL] };
}

function selectionCases(): Rec {
  const modes = [undefined, 'standard', 'unrestricted'];
  const tiers = [undefined, 'economy', 'balanced', 'performant'];
  const projects: unknown[] = [undefined, {}, ...modes.flatMap(contentMode => tiers.map(costTier => ({ contentMode, costTier })))];
  const chosen: Rec[] = [];
  for (const contentMode of modes) {
    for (const costTier of tiers) {
      for (const project of projects) {
        const turn = { ...(contentMode ? { contentMode } : {}), ...(costTier ? { costTier } : {}) };
        chosen.push({ turn, project: project ?? null, expected: selection.chatSelection(turn, project) });
      }
    }
  }
  const raws = [null, 'economy', 'balanced', 'performant', 'standard', 'unrestricted', 'Economy', '', 'économy', 5, 'economy '];
  const stored = raws.flatMap(costTier => raws.map(contentMode => ({ costTier, contentMode, expected: selectionFromRow({ costTier, contentMode }) })));
  return { graph: selection.CHAT_TURN_GRAPH, defaultCostTier: defaults.DEFAULT_COST_TIER, chosen, stored };
}

function selectionFromRow(row: { costTier: unknown; contentMode: unknown }): Rec {
  return {
    ...(defaults.isCostTier(row.costTier) ? { costTier: row.costTier } : {}),
    ...(defaults.isContentMode(row.contentMode) ? { contentMode: row.contentMode } : {}),
  };
}

function noteCases(): Rec {
  const names = ['HELD_FOR_REVIEW_NOTE', 'WRITER_READ_HELD_NOTE', 'APPLY_FAILED_NOTE', 'UNLINKED_NOTE', 'CARDS_UNSAVED_NOTE', 'IDEAS_DROPPED_NOTE', 'ORGANISE_STARTED_NOTE', 'ORGANISE_BUSY_NOTE', 'ORGANISE_REFUSED_NOTE'];
  const lists = [[], ['a'], ['one', 'two'], ['multi\nline', 'crlf\r\nline'], ['', ' '], ['😀 astral', 'é'], ['x'.repeat(300)]];
  return {
    notes: Object.fromEntries(names.map(name => [name, turnProposals[name]])),
    negationFix: lists.map(warnings => ({ warnings, expected: negationFixRequest(warnings) })),
  };
}

await handcraftedPassages();
await generatePassages();

write('passage.json', { resolves, relocations, render: renderCases(), constants: { maxContexts: passage.MAX_PASSAGE_CONTEXTS, maxQuote: passage.MAX_PASSAGE_QUOTE_CHARS, maxComment: passage.MAX_PASSAGE_COMMENT_CHARS, heading: passage.PASSAGE_COMMENTS_HEADING } });
write('question.json', questionCases());
write('prose-intent.json', proseIntentCases());
write('later-plans.json', laterPlanCases());
write('planner-only.json', plannerOnlyCases());
write('selection.json', selectionCases());
write('notes.json', noteCases());
