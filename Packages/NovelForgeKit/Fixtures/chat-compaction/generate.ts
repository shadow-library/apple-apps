import { plugin } from 'bun';
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// Run as: PLATFORM_REPO=<checkout> bun --tsconfig-override "$PLATFORM_REPO/apps/novel-forge-server/tsconfig.json" generate.ts
// Each scenario is a session the Swift test writes through typed records; the expected window, fold request and histories are the reference's own
// ChatCompactionService (compactIfNeeded, then buildHistory for both turn modes) over a fake database, with the model call scripted.
const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');

const server = join(platformRepo, 'apps/novel-forge-server/src');
const outDir = dirname(fileURLToPath(import.meta.url));
const classes = await import(join(server, 'classes/app-error-code.ts'));

const commonExports: Record<string, unknown> = {};
for (const file of readdirSync(join(server, 'common')).filter(name => name.endsWith('.ts') && !name.endsWith('.spec.ts') && name !== 'index.ts').sort()) {
  try {
    Object.assign(commonExports, await import(join(server, 'common', file)));
  } catch {
    continue;
  }
}
const paragraphs = await import(join(platformRepo, 'packages/sdk/src/prose-paragraphs.ts'));

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

const noop = () => undefined;
const columns = (table: string): unknown => new Proxy({}, { get: (_, column) => `${table}.${String(column)}` });
const schema = new Proxy({}, { get: (_, table) => columns(String(table)) });

plugin({
  name: 'chat-compaction-fixture-stubs',
  setup(build) {
    build.module('@server/classes', () => ({ exports: { AppErrorCode: classes.AppErrorCode }, loader: 'object' }));
    build.module('@server/common', () => ({ exports: commonExports, loader: 'object' }));
    build.module('@server/constants', () => ({ exports: { APP_NAME: 'fixture' }, loader: 'object' }));
    build.module('@server/database', () => ({ exports: { schema }, loader: 'object' }));
    build.module('@server/database/schemas', () => ({ exports: {}, loader: 'object' }));
    build.module('@shadow-library/sdk', () => ({ exports: { paragraphAt: paragraphs.paragraphAt }, loader: 'object' }));
    build.module('@shadow-library/app', () => ({ exports: { Injectable: () => (target: unknown) => target }, loader: 'object' }));
    build.module('@shadow-library/modules', () => ({ exports: { DatabaseService: class {} }, loader: 'object' }));
    build.module('js-tiktoken', () => ({ exports: { getEncoding: () => ({ encode: (text: string) => ({ length: estimateTokens(text) }) }) }, loader: 'object' }));
    build.module('drizzle-orm', () => ({
      exports: { and: noop, asc: noop, desc: noop, eq: noop, gt: noop, inArray: noop, isNotNull: noop, sql: noop },
      loader: 'object',
    }));
    build.onLoad({ filter: /modules\/ai\/graphs\/workflow-run\.service\.ts$/ }, () => ({ contents: 'export class WorkflowRunService {}', loader: 'js' }));
    build.onLoad({ filter: /modules\/ai\/model-router\.service\.ts$/ }, () => ({ contents: 'export class ModelRouterService {}', loader: 'js' }));
    build.onLoad({ filter: /modules\/plugins\/plugin-policy\.service\.ts$/ }, () => ({ contents: 'export class PluginPolicyService {}', loader: 'js' }));
    build.onLoad({ filter: /modules\/ai\/prompts\/index\.ts$/ }, () => ({
      contents: "import { chatCompactPrompt } from './chat-compact.prompt'; export const PROMPT_REGISTRY = { 'chat-compact': chatCompactPrompt };",
      loader: 'ts',
    }));
  },
});

const refinement = join(server, 'modules/refinement');
const compaction = await import(join(refinement, 'chat-compaction.service.ts'));
const hardLine = await import(join(server, 'modules/ai/hard-line.ts'));
const budgetMatch = /export const CHAT_HISTORY_BUDGET = ([\d_]+);/.exec(readFileSync(join(server, 'modules/ai/context/context-assembler.service.ts'), 'utf8'));
if (!budgetMatch?.[1]) throw new Error('CHAT_HISTORY_BUDGET not found');
const CHAT_HISTORY_BUDGET = Number(budgetMatch[1].replaceAll('_', ''));

function createRng(seed: number) {
  let state = seed | 0;
  const next = (): number => {
    state = (state + 0x6d2b79f5) | 0;
    let t = Math.imul(state ^ (state >>> 15), 1 | state);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  return {
    next,
    int: (min: number, max: number): number => min + Math.floor(next() * (max - min + 1)),
    chance: (p: number): boolean => next() < p,
    pick: <T>(items: readonly T[]): T => items[Math.floor(next() * items.length)] as T,
  };
}
const random = createRng(20261117);

const WORDS = ('the a of and to in he she it was had that with for on as at by from his her they there then when what which who would could '
  + 'lighthouse keeper stairs window grey sea sky morning lantern harbour captain letter promise winter river bridge silence shadow memory garden '
  + 'walked climbed whispered remembered carried opened closed turned waited listened wondered believed forgot answered followed slowly quietly').split(' ');
const ODD = ['Élodie', 'naïve café', 'été', '😀', '𠮷野家', '日本語の文章', 'line\r\nbreak', 'tab\there', 'nbsp space', ' sep', 'Ω≈ç√'];
// Supplied-scope hits refuse an author's message; background hits refuse an unrestricted fold; the standalone term refuses either.
const SUPPLIED_HIT = 'the schoolgirl looked sexy in the doorway';
const BACKGROUND_HIT = 'a child and intercourse in one line';
const STANDALONE_HIT = 'nothing but loli art';

const words = (count: number): string => Array.from({ length: count }, () => random.pick(WORDS)).join(' ');
// Dense in tokens and light in bytes: one-letter words cost a token each, so a long message stays a few kilobytes.
const DENSE = ['a', 'I', 'o', 'x', '7', '—', '😀', 'é', 'of'];
function text(size: 'short' | 'medium' | 'long'): string {
  if (size === 'long') return Array.from({ length: random.int(1800, 2200) }, () => random.pick(DENSE)).join(' ');
  const count = size === 'short' ? random.int(1, 10) : random.int(8, 28);
  let out = words(count);
  if (random.chance(0.3)) out = `${out} ${random.pick(ODD)}`;
  if (random.chance(0.15)) out = `${random.pick(ODD)} ${out}\n\n${words(random.int(3, 10))}`;
  return out;
}

type Mode = 'standard' | 'unrestricted';
interface Context {
  kind: 'passage'; chapter: number; draftId: string; revision: number; saveSeq: number; start: number; end: number; passageHash: string; quote: string; comment: string;
  firstParagraph: number; lastParagraph: number;
}
interface Message {
  ordinal: number;
  role: 'user' | 'assistant';
  content: string;
  contexts: Context[] | null;
  question: { question: string; answers: { title: string; why?: string }[] } | null;
  tokens: number | null;
  mode: Mode;
}

const hex = (): string => Array.from({ length: 64 }, () => '0123456789abcdef'[random.int(0, 15)]).join('');
function context(hit: string | null): Context {
  const start = random.int(0, 4000);
  const quote = hit && random.chance(0.5) ? hit : `${words(random.int(3, 15))}${random.chance(0.3) ? `\n${words(4)}` : ''}`;
  const first = random.int(1, 30);
  return {
    kind: 'passage', chapter: random.int(1, 40), draftId: `draft-${random.int(1, 9)}`, revision: random.int(1, 12), saveSeq: random.int(0, 5), start,
    end: start + quote.length, passageHash: hex(), quote, comment: hit && quote !== hit ? hit : random.chance(0.2) ? '' : words(random.int(2, 12)),
    firstParagraph: first, lastParagraph: first + random.int(0, 2),
  };
}

interface Profile {
  turns: [number, number];
  size: () => 'short' | 'medium' | 'long';
  unrestricted: number;
  hits: number;
}
const PROFILES: Profile[] = [
  { turns: [0, 4], size: () => 'short', unrestricted: 0, hits: 0 },
  { turns: [3, 8], size: () => random.pick(['short', 'medium'] as const), unrestricted: 0.1, hits: 0.1 },
  { turns: [6, 7], size: () => random.pick(['short', 'medium'] as const), unrestricted: 0, hits: 0 },
  { turns: [2, 6], size: () => (random.chance(0.35) ? 'long' : 'medium'), unrestricted: 0.15, hits: 0.15 },
  { turns: [8, 16], size: () => random.pick(['short', 'medium'] as const), unrestricted: 0.2, hits: 0.2 },
];

function messages(profile: Profile): Message[] {
  const out: Message[] = [];
  let longWritten = 0;
  const sized = (): string => {
    const size = profile.size();
    if (size !== 'long') return text(size);
    if (longWritten === 1) return text('medium');
    longWritten += 1;
    return text('long');
  };
  const turns = random.int(...profile.turns);
  for (let turn = 0; turn < turns; turn++) {
    const mode: Mode = random.chance(profile.unrestricted) ? 'unrestricted' : 'standard';
    const hit = random.chance(profile.hits) ? random.pick([SUPPLIED_HIT, BACKGROUND_HIT, STANDALONE_HIT]) : null;
    const contexts = random.chance(0.25) ? Array.from({ length: random.int(1, 3) }, () => context(hit)) : null;
    const content = contexts && random.chance(0.3) ? '' : hit && !contexts ? `${text('short')} ${hit}` : sized();
    out.push({ ordinal: out.length + 1, role: 'user', content, contexts, question: null, tokens: random.chance(0.35) ? random.int(0, 2500) : null, mode });
    if (random.chance(0.12)) continue;
    const replyHit = random.chance(profile.hits / 2) ? random.pick([SUPPLIED_HIT, BACKGROUND_HIT]) : null;
    const question = random.chance(0.2)
      ? { question: text('short'), answers: Array.from({ length: random.int(2, 4) }, () => (random.chance(0.3) ? { title: text('short'), why: words(5) } : { title: text('short') })) }
      : null;
    out.push({
      ordinal: out.length + 1, role: 'assistant', content: replyHit ? `${text('short')} ${replyHit}` : sized(), contexts: null, question,
      tokens: random.chance(0.35) ? random.int(0, 2500) : null, mode,
    });
  }
  return out;
}

// What the reference reads from the database: rows after the watermark, each reply's turn selection, and the latest compaction run.
interface World {
  session: { id: string; summary: string | null; summaryThroughOrdinal: number };
  rows: Record<string, unknown>[];
  selections: Map<string, Mode>;
  compactRuns: Mode[];
}
let world: World;

function query(fields: Record<string, unknown>) {
  const result = (): unknown[] => {
    if ('id' in fields) return [...world.selections].map(([id, contentMode]) => ({ id, costTier: 'balanced', contentMode }));
    const latest = world.compactRuns.at(-1);
    return latest ? [{ contentMode: latest }] : [];
  };
  const chain: Record<string, unknown> = {
    from: () => chain, where: () => chain, orderBy: () => chain, limit: () => chain,
    then: (resolve: (value: unknown) => unknown, reject: (reason: unknown) => unknown) => Promise.resolve(result()).then(resolve, reject),
  };
  return chain;
}
const db = {
  query: {
    chatMessages: {
      findMany: async () => world.rows.filter(row => (row.ordinal as number) > world.session.summaryThroughOrdinal).sort((a, b) => (a.ordinal as number) - (b.ordinal as number)),
    },
  },
  select: query,
  update: () => ({ set: () => ({ where: async () => undefined }) }),
};

interface Call {
  input: { priorSummary: string; transcript: string };
  requestText: string;
  referenceMode: Mode;
}
let call: Call | null;
let nativeMode: Mode;
let modelSummary: string;
let modelCalled: boolean;

// The router's hard line for an unrestricted call (model-router.service.ts:464, :710-719, :763), applied in the native fold's mode.
const modelRouter = {
  structured: async (prompt: any, input: { priorSummary: string; transcript: string }, _ctx: unknown, project: { contentMode: Mode }) => {
    const wire = await prompt.template.formatMessages(input);
    const human = wire.filter((message: any) => message.getType() === 'human').map((message: any) => message.content as string);
    if (human.length !== 1) throw new Error('chat-compact sends one human message');
    call = { input, requestText: human[0], referenceMode: project.contentMode };
    const unrestricted = nativeMode === 'unrestricted';
    const refuse = (screens: unknown[]) => {
      const hit = hardLine.screenTexts(screens);
      if (unrestricted && hit) throw hardLine.hardLineError(hit);
    };
    refuse(hardLine.inputScreens(input));
    refuse(hardLine.wireMessageTexts(wire).map((text: string) => ({ text, scope: 'background', source: 'The request' })));
    modelCalled = true;
    const output = { summary: modelSummary };
    refuse(hardLine.outputScreens(output, 'compact'));
    return output;
  },
};
const workflowRuns = {
  runChain: async (_project: bigint, _graph: string, _target: string, input: { contentMode: Mode }, body: (runId: string) => Promise<unknown>) => {
    const result = await body('compact-run');
    world.compactRuns.push(input.contentMode);
    return { runId: 'compact-run', result };
  },
};
const service = new compaction.ChatCompactionService({ getPostgresClient: () => db }, modelRouter, workflowRuns, { resolve: async () => ({ plugins: [], digest: '' }) });

const asMessages = (list: any[]) => list.map(message => ({ role: message.getType() === 'ai' ? 'assistant' : 'user', content: message.content as string }));

const scenarios: unknown[] = [];
let index = 0;
async function scenario(profile: Profile, options: { summaryChance: number; turnUnrestricted: number; novelUnrestricted: number; outputHit: number }) {
  const list = messages(profile);
  const through = list.length > 0 && random.chance(options.summaryChance) ? random.int(1, Math.max(1, Math.floor(list.length / 3))) : 0;
  const summary = through > 0 ? { text: random.chance(0.2) ? `${text('short')} ${random.pick(ODD)}` : text('medium'), mode: (random.chance(0.15) ? 'unrestricted' : 'standard') as Mode, through } : null;
  const novelMode: Mode = random.chance(options.novelUnrestricted) ? 'unrestricted' : 'standard';
  const turnMode: Mode = random.chance(options.turnUnrestricted) ? 'unrestricted' : novelMode;
  modelSummary = random.chance(options.outputHit) ? `${text('short')} ${STANDALONE_HIT}` : text('medium');
  const holdsUnrestricted = list.some(message => message.mode === 'unrestricted') || summary?.mode === 'unrestricted';
  nativeMode = turnMode === 'unrestricted' || novelMode === 'unrestricted' || holdsUnrestricted ? 'unrestricted' : 'standard';
  world = {
    session: { id: 'session', summary: summary?.text ?? null, summaryThroughOrdinal: summary?.through ?? 0 },
    rows: list.map(message => ({
      id: BigInt(message.ordinal), sessionId: 'session', ordinal: message.ordinal, role: message.role, content: message.content, contexts: message.contexts,
      question: message.question, tokens: message.tokens, runId: `run-${message.ordinal}`,
    })),
    selections: new Map(list.filter(message => message.role === 'assistant').map(message => [`run-${message.ordinal}`, message.mode])),
    compactRuns: summary ? [summary.mode] : [],
  };
  call = null;
  modelCalled = false;
  const verbatim = list.filter(message => message.ordinal > (summary?.through ?? 0)).map(message => message.ordinal);
  const compacted = await service.compactIfNeeded(1n, world.session, CHAT_HISTORY_BUDGET, { contentMode: novelMode }, { contentMode: turnMode, costTier: 'balanced' });
  const folded = call === null ? null : verbatim.slice(0, verbatim.length - 6);
  const outcome = call === null ? 'kept' : compacted.runId === undefined ? 'refused' : 'folded';
  const divergent = call !== null && call.referenceMode !== nativeMode;
  // A kept window of many messages renders as the folded ones do; leaving its histories out keeps the fixture small.
  const standard = asMessages(await service.buildHistory(world.session, { contentMode: novelMode }, 'standard', compacted.rows));
  const unrestricted = asMessages(await service.buildHistory(world.session, { contentMode: novelMode }, 'unrestricted', compacted.rows));
  // An unrestricted history equal to the standard one is written as null.
  const history = (divergent && outcome === 'folded') || (outcome === 'kept' && verbatim.length > 8)
    ? null
    : { standard, unrestricted: JSON.stringify(unrestricted) === JSON.stringify(standard) ? null : unrestricted };
  scenarios.push({
    name: `scenario-${index++}`, novelMode, turnMode, summary, messages: list, model: modelSummary,
    expected: { outcome, modelCalled, folded, request: call ? { ...call.input, text: call.requestText } : null, referenceMode: call?.referenceMode ?? null, nativeMode, history },
  });
}

const variants = [
  { summaryChance: 0, turnUnrestricted: 0, novelUnrestricted: 0, outputHit: 0 },
  { summaryChance: 0.6, turnUnrestricted: 0, novelUnrestricted: 0, outputHit: 0 },
  { summaryChance: 0.5, turnUnrestricted: 0.3, novelUnrestricted: 0.2, outputHit: 0.3 },
];
for (const profile of PROFILES) {
  for (const variant of variants) {
    for (let repeat = 0; repeat < 4; repeat++) await scenario(profile, variant);
  }
}

const summary = (key: string) => scenarios.filter((entry: any) => entry.expected.outcome === key).length;
if (summary('folded') < 10 || summary('refused') < 3 || summary('kept') < 10) throw new Error(`too few outcomes: ${summary('folded')} ${summary('refused')} ${summary('kept')}`);
writeFileSync(join(outDir, 'chat-compaction.json'), `${JSON.stringify({ historyBudget: CHAT_HISTORY_BUDGET, scenarios })}\n`);
