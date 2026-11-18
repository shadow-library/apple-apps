import { plugin } from 'bun';
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// Run as: PLATFORM_REPO=<checkout> bun --tsconfig-override "$PLATFORM_REPO/apps/novel-forge-server/tsconfig.json" generate.ts
// Depends on the working copy of the platform checkout, not its last commit (none of the files read here had uncommitted edits when this was written).
// The pure renderers are called as the reference defines them; the parts of ContextAssembler.forChapter that render inline are sliced out of its source and run on plain inputs.
const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');

const server = join(platformRepo, 'apps/novel-forge-server/src');
const outDir = dirname(fileURLToPath(import.meta.url));
const classes = await import(join(server, 'classes/app-error-code.ts'));
const realCommon = await import('@shadow-library/common');

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

const rawSources = new WeakMap<RegExp, string>();
globalThis.RegExp = new Proxy(RegExp, {
  construct(target, args) {
    const made = Reflect.construct(target, args) as RegExp;
    if (typeof args[0] === 'string') rawSources.set(made, args[0]);
    return made;
  },
}) as RegExpConstructor;

const common: Record<string, unknown> = {};

plugin({
  name: 'writer-pack-render-stubs',
  setup(build) {
    build.module('drizzle-orm', () => ({
      exports: Object.fromEntries(['and', 'between', 'eq', 'gt', 'inArray', 'isNotNull', 'isNull', 'lt', 'lte', 'notInArray', 'or', 'sql', 'asc', 'desc'].map(name => [name, () => ({})])),
      loader: 'object',
    }));
    build.module('@server/database', () => ({ exports: { schema: new Proxy({}, { get: () => ({}) }) }, loader: 'object' }));
    build.module('@server/database/schemas', () => ({ exports: new Proxy({}, { get: () => ({}) }) as Record<string, unknown>, loader: 'object' }));
    build.module('@server/classes', () => ({ exports: { AppErrorCode: classes.AppErrorCode }, loader: 'object' }));
    build.module('@server/constants', () => ({ exports: { APP_NAME: 'fixture' }, loader: 'object' }));
    build.module('@shadow-library/common', () => ({ exports: { ...realCommon, Logger: { getLogger: () => ({ warn() {}, info() {}, error() {}, debug() {} }) }, Config: { get: () => undefined } }, loader: 'object' }));
    build.module('@shadow-library/class-schema', () => ({
      exports: { Field: () => () => {}, Schema: () => () => {}, EnumType: { create: (name: string, values: string[]) => ({ name, values }) } },
      loader: 'object',
    }));
    build.module('@server/common', () => ({ exports: common, loader: 'object' }));
    build.module('js-tiktoken', () => ({ exports: { getEncoding: () => ({ encode: (text: string) => ({ length: estimateTokens(text) }) }) }, loader: 'object' }));
    build.onResolve({ filter: /\/chapter-shift$/ }, () => ({ path: 'chapter-shift', namespace: 'stub' }));
    build.onResolve({ filter: /finalize-review\/isolation-bridge$/ }, () => ({ path: 'isolation-bridge', namespace: 'stub' }));
    build.onLoad({ filter: /^chapter-shift$/, namespace: 'stub' }, () => ({ contents: 'export const shiftChapterNumber = () => 0;', loader: 'js' }));
    build.onLoad({ filter: /^isolation-bridge$/, namespace: 'stub' }, () => ({ contents: 'export const bridgedSummary = () => null;', loader: 'js' }));
  },
});

for (const file of ['reveal-term', 'term-text', 'brief-volume', 'plan-world', 'unlock-condition', 'open-canon', 'knowledge-contract', 'reveal-rule', 'bible-doc-title', 'brief-body', 'progress']) {
  Object.assign(common, await import(join(server, `common/${file}.ts`)));
}

const contextDir = join(server, 'modules/ai/context');
const writerContext = await import(join(contextDir, 'writer-context.ts'));
const packRender = await import(join(contextDir, 'pack-render.ts'));
const sectionsModule = await import(join(contextDir, 'sections.ts'));
const writerBrief = await import(join(contextDir, 'writer-brief.ts'));
const knowledgeView = await import(join(server, 'modules/bible/fact/knowledge-view.ts'));
const disclosure = await import(join(server, 'modules/bible/fact/writer-disclosure-policy.ts'));
const ledgerSections = await import(join(server, 'modules/ledger/ledger-sections.ts'));
const assemblerSource = await Bun.file(join(contextDir, 'context-assembler.service.ts')).text();

function between(source: string, start: string, end: string): string {
  const from = source.indexOf(start);
  if (from === -1 || source.indexOf(start, from + 1) !== -1) throw new Error(`marker missing or repeated: ${start}`);
  const to = source.indexOf(end, from);
  if (to === -1) throw new Error(`marker missing: ${end}`);
  return source.slice(from, to);
}

const transpiler = new Bun.Transpiler({ loader: 'ts' });
const dependencies: Record<string, unknown> = {
  WRITER_SECTION_CAPS: writerContext.WRITER_SECTION_CAPS,
  WRITER_OPTIONAL_PRIORITY: writerContext.WRITER_OPTIONAL_PRIORITY,
  fitToCap: packRender.fitToCap,
  fitFacts: packRender.fitFacts,
  subjectsFirst: packRender.subjectsFirst,
  sizedSectionCeiling: packRender.sizedSectionCeiling,
  makeSection: packRender.makeSection,
  allowedCluesSection: packRender.allowedCluesSection,
  renderKnownFacts: knowledgeView.renderKnownFacts,
  renderChapterReveals: knowledgeView.renderChapterReveals,
  renderReaderKnows: knowledgeView.renderReaderKnows,
  renderHiddenConstraints: knowledgeView.renderHiddenConstraints,
  withWriterNotes: knowledgeView.withWriterNotes,
  writerLinesSection: ledgerSections.writerLinesSection,
};

const reserveSource = between(assemblerSource, 'const reserve = (section: ContextSection', 'const prevIsolated');
const previousSource = between(assemblerSource, 'if (previous.ending) reserveDerived(', 'if (currentVolume?.objective)');
const knowledgeSource = between(assemblerSource, 'if (knowledgeContract) {', 'const refs = chapterWriterRefs(brief);').replace(
  'const view = await loadKnowledgeView(this.db, projectId, chapter, knowledgeContract);',
  '',
);
const writerLinesSource = between(assemblerSource, 'const writerLines = writerLinesSection(ledger, disclosure);', 'const plugins = pluginContextSections');
if (knowledgeSource.includes('loadKnowledgeView')) throw new Error('the knowledge block still loads the view');

function slice(body: string): (context: Record<string, unknown>) => { sections: any[]; reservations: any[]; derivedCuts: any[] } {
  const code = transpiler.transformSync(`function run(context) {
    const { view, chapterCast, disclosure, knowledgeContract, previous, ledger } = context;
    const reservations = [];
    const sections = [];
    const derivedCuts = [];
    ${reserveSource}
    ${body}
    return { sections, reservations, derivedCuts };
  }`);
  const names = Object.keys(dependencies);
  const factory = new Function(...names, `${code}\nreturn run;`);
  return factory(...names.map(name => dependencies[name])) as never;
}

const runPrevious = slice(previousSource);
const runKnowledge = slice(knowledgeSource);
const runWriterLines = slice(writerLinesSource);

function createRng(seed: number): () => number {
  let state = seed | 0;
  return () => {
    state = (state + 0x6d2b79f5) | 0;
    let t = Math.imul(state ^ (state >>> 15), 1 | state);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const rng = createRng(0x77a1c3);
const int = (min: number, max: number): number => min + Math.floor(rng() * (max - min + 1));
const pick = <T,>(items: readonly T[]): T => items[int(0, items.length - 1)] as T;

const WORDS = ['salt', 'tide', 'lantern', 'harbour', 'ledger', 'weir', 'causeway', 'brine', 'oath', 'keeper', 'ferry', 'chalk', 'ember', 'gull', 'mooring', 'signal', 'winter', 'orchard', 'bell', 'quarry'];
const NAMES = ['Ines', 'Oren', 'Maren', 'Tavish', 'Lio', 'Sabine', 'Corvin', 'Edda'];
const CJK = '灯塔守护者在潮水退去之前点亮了最后一盏灯。';
const sentence = (subject: string, count: number): string => `${subject} walks the causeway past the drying racks and the brine pans. `.repeat(count);
const phrase = (min: number, max: number): string => Array.from({ length: int(min, max) }, () => pick(WORDS)).join(' ');
const prose = (sentences: number): string =>
  Array.from({ length: sentences }, () => `${pick(NAMES)} ${pick(['crossed', 'watched', 'carried', 'counted', 'sealed'])} the ${phrase(2, 5)}${pick(['.', '.', '!', '?'])}`).join(' ');

interface Fact {
  factKey: string;
  text: string;
  constraintNote?: string | null;
  writerNote?: string | null;
  terms?: string[] | null;
  allowedClues?: string[] | null;
  subjects?: string[] | null;
}

interface PolicySpec {
  chapter: number;
  lockedFacts: Fact[];
  plannerOnly: string[];
  plannerPages: string[];
}

const NO_POLICY: PolicySpec = { chapter: 5, lockedFacts: [], plannerOnly: [], plannerPages: [] };
const SECRET: Fact = {
  factKey: 'ferryman_heir',
  text: 'The ferryman is the drowned heir of the tide court',
  constraintNote: 'Never name the heir before the flood scene',
  writerNote: 'The ferryman deflects any talk of family.',
  terms: ['tide court'],
  allowedClues: ['A salt-stained signet ring on the ferryman'],
  subjects: ['ferryman'],
};
const WITH_SECRET: PolicySpec = { chapter: 5, lockedFacts: [SECRET], plannerOnly: ['The lighthouse was never abandoned'], plannerPages: [] };

function policyOf(spec: PolicySpec) {
  return new disclosure.WriterDisclosurePolicy({
    chapter: spec.chapter,
    lockedFacts: spec.lockedFacts,
    plannerOnly: spec.plannerOnly,
    plannerPages: spec.plannerPages,
    volumeOrdinals: new Map(),
    currentVolumeOrdinal: null,
  });
}

function withheldOf(policy: { withheld: ReadonlyMap<string, number> }): [string, number][] {
  return [...policy.withheld.entries()].sort((left, right) => (left[0] < right[0] ? -1 : 1));
}

function sectionOut(section: any): Record<string, unknown> | null {
  if (!section) return null;
  return {
    key: section.key,
    tier: section.tier,
    segment: section.segment,
    tokens: section.tokens,
    truncated: section.truncated,
    sourceRefs: section.sourceRefs,
    rendered: section.rendered,
    required: section.required ?? false,
    priority: section.priority ?? null,
  };
}

function reservationOut(reservation: any): Record<string, unknown> {
  return { name: reservation.name, tokens: reservation.tokens, cap: reservation.cap, fromPlan: reservation.fromPlan ?? false };
}

function rendered(result: { sections: any[]; reservations: any[]; derivedCuts: any[] }, policy: any): Record<string, unknown> {
  return {
    sections: result.sections.map(sectionOut),
    reservations: result.reservations.map(reservationOut),
    omitted: result.derivedCuts.map(cut => ({ key: cut.key, tokens: cut.tokens })),
    withheld: withheldOf(policy),
  };
}

const volumeSpecs: { id: string; volumes: any[]; maxTokens: number; policy: PolicySpec | null }[] = [];
const longVolume = (ordinal: number): any => ({
  ordinal,
  title: `Tide ${ordinal}`,
  goal: sentence('The goal', 10),
  chapters: Array.from({ length: 4 }, (_, i) => ({ number: ordinal * 10 + i, summary: sentence(`Chapter ${ordinal * 10 + i}`, 10) })),
});
const finalizedVolume = (ordinal: number, from: number, to: number): any => ({
  ordinal,
  title: `Tide ${ordinal}`,
  goal: `Goal of tide ${ordinal}.`,
  chapters: Array.from({ length: to - from + 1 }, (_, i) => ({ number: from + i, summary: `Chapter ${from + i} settles the matter of tide ${ordinal}. It leaves a mark.` })),
});
volumeSpecs.push(
  { id: 'spec-two-volumes', volumes: [finalizedVolume(1, 1, 3), finalizedVolume(2, 4, 7)], maxTokens: 1_500, policy: null },
  { id: 'spec-one-volume-from-goal-met', volumes: [{ ordinal: 1, title: 'Tide 1', goal: 'Goal of tide 1.', chapters: [{ number: 1, summary: 'The tide settles at last. It leaves a mark.' }] }], maxTokens: 1_500, policy: null },
  { id: 'spec-script-without-spaces', volumes: [{ ordinal: 1, title: '潮', goal: null, chapters: [{ number: 1, summary: CJK.repeat(12) }] }], maxTokens: 1_000, policy: null },
  { id: 'spec-six-long-volumes', volumes: Array.from({ length: 6 }, (_, i) => longVolume(i + 1)), maxTokens: 800, policy: null },
  {
    id: 'spec-single-chapter-and-empty',
    volumes: [
      { ordinal: 1, title: 'Tide 1', goal: null, chapters: [{ number: 1, summary: 'The oath is sworn.' }] },
      { ordinal: 2, title: 'Tide 2', goal: 'Break the oath.', chapters: [] },
    ],
    maxTokens: 1_000,
    policy: null,
  },
  { id: 'no-volumes', volumes: [], maxTokens: 1_500, policy: null },
  { id: 'only-empty-volume', volumes: [{ ordinal: 3, title: 'Tide 3', goal: 'Nothing yet.', chapters: [] }], maxTokens: 1_500, policy: null },
  { id: 'zero-budget', volumes: [finalizedVolume(1, 1, 3)], maxTokens: 0, policy: null },
  { id: 'budget-below-one-block', volumes: [finalizedVolume(1, 1, 3), finalizedVolume(2, 4, 7)], maxTokens: 20, policy: null },
  { id: 'two-chapters-no-turns', volumes: [finalizedVolume(1, 1, 2)], maxTokens: 1_500, policy: null },
  { id: 'three-chapters-one-turn', volumes: [finalizedVolume(1, 1, 3)], maxTokens: 1_500, policy: null },
  { id: 'unordered-ordinals', volumes: [finalizedVolume(3, 20, 24), finalizedVolume(1, 1, 3), finalizedVolume(2, 4, 7)], maxTokens: 1_500, policy: null },
  {
    id: 'spaces-newlines-and-blank-goal',
    volumes: [
      {
        ordinal: 1,
        title: 'Tide   1',
        goal: '   ',
        chapters: [
          { number: 1, summary: '  The  oath\n\nis   sworn!  Then\tit breaks.  ' },
          { number: 2, summary: 'Middle chapter.\nWith a newline. And more.' },
          { number: 3, summary: 'A closing\n\n  line   with   gaps.' },
        ],
      },
    ],
    maxTokens: 1_500,
    policy: null,
  },
  {
    id: 'unicode-and-sentence-ends',
    volumes: [
      {
        ordinal: 1,
        title: 'Marée 🌊',
        goal: 'Éclaire le phare — « avant la marée ».',
        chapters: [
          { number: 1, summary: `${CJK}${CJK} 灯が消えた。そして朝が来た。` },
          { number: 2, summary: 'Ünïcödé résumé! Ça va? Oui… non.' },
          { number: 3, summary: '😀😀😀 émoji run. Second sentence.' },
          { number: 4, summary: 'Last: "quoted." Then more.' },
        ],
      },
    ],
    maxTokens: 1_500,
    policy: null,
  },
  { id: 'scrubbed-by-policy', volumes: [{ ordinal: 1, title: 'Tide 1', goal: null, chapters: [
      { number: 1, summary: 'The ferryman is the drowned heir of the tide court. Then dusk fell.' },
      { number: 2, summary: 'The tide court sat in silence. The weir held.' },
      { number: 3, summary: 'Nothing leaks here. The tide court again.' },
    ] }], maxTokens: 1_500, policy: WITH_SECRET },
  { id: 'twelve-volumes-long-list', volumes: Array.from({ length: 12 }, (_, i) => finalizedVolume(i + 1, i * 6 + 1, i * 6 + 6)), maxTokens: 1_500, policy: null },
  { id: 'one-long-word-summary', volumes: [{ ordinal: 1, title: 'Tide 1', goal: 'x'.repeat(900), chapters: [{ number: 1, summary: 'y'.repeat(2_000) }] }], maxTokens: 1_500, policy: null },
);
for (let index = 0; index < 8; index++) {
  const count = int(1, 9);
  const volumes = Array.from({ length: count }, (_, i) => {
    const chapters = Array.from({ length: int(0, 8) }, (_, c) => ({ number: (i + 1) * 20 + c, summary: prose(int(1, 14)) }));
    return { ordinal: i + 1, title: `Volume ${phrase(1, 3)}`, goal: rng() < 0.7 ? prose(int(1, 12)) : null, chapters };
  });
  volumeSpecs.push({ id: `generated-${index}`, volumes, maxTokens: pick([150, 400, 800, 1_500, 3_000]), policy: index % 3 === 0 ? WITH_SECRET : null });
}

const tokenBudget = await import(join(contextDir, 'token-budget.ts'));
const exactVolumes = [finalizedVolume(1, 1, 3), finalizedVolume(2, 4, 7), finalizedVolume(3, 8, 9)];
const exactSum = (writerContext.renderCompletedVolumes(exactVolumes, 1_000_000) as string).split('\n\n').reduce((sum: number, block: string) => sum + tokenBudget.countTokens(block) + 2, 0);
volumeSpecs.push(
  { id: 'budget-equals-block-sum', volumes: exactVolumes, maxTokens: exactSum, policy: null },
  { id: 'budget-one-under-block-sum', volumes: exactVolumes, maxTokens: exactSum - 1, policy: null },
);

const completedVolumes = volumeSpecs.map(spec => {
  const policy = policyOf(spec.policy ?? NO_POLICY);
  const scrub = spec.policy ? (summary: string): string => policy.scrub(summary, 'summary') : undefined;
  const text = writerContext.renderCompletedVolumes(spec.volumes, spec.maxTokens, scrub);
  return { id: spec.id, volumes: spec.volumes, maxTokens: spec.maxTokens, policy: spec.policy, expected: text, withheld: withheldOf(policy) };
});

interface EndingCase {
  id: string;
  chapter: number;
  row: any;
  draft: any;
  rawIsolated: boolean;
  policy: PolicySpec;
  caps?: { ending: number; state: number };
}

const longBody = (paragraphs: number): string => Array.from({ length: paragraphs }, () => prose(int(2, 6))).join('\n\n');
const draftOf = (over: Record<string, unknown> = {}): any => ({ body: null, summary: 'Four ends at the weir.', state: null, isolated: false, staleReason: null, ...over });
const rowOf = (over: Record<string, unknown> = {}): any => ({ status: 'done', isolated: false, content: longBody(8), summary: 'Summary of the row.', ...over });
const spillState = { conflict: sentence('The quarrel', 200), lastAction: 'Ines seals the ledger.' };
const fullState = { openConflict: 'The weir is failing', characterPositions: [{ entityKey: 'ines', location: 'the weir' }, { entityKey: 'oren', location: 'the ferry' }], lastBeat: 'The bell rings', emotionalState: 'dread', establishedFacts: Array.from({ length: 20 }, (_, i) => `Fact number ${i} about the weir`) };

const endingCases: EndingCase[] = [
  { id: 'nothing-before', chapter: 0, row: null, draft: null, rawIsolated: false, policy: NO_POLICY },
  { id: 'finalized-row-tail', chapter: 4, row: rowOf(), draft: null, rawIsolated: false, policy: NO_POLICY },
  { id: 'working-row-with-draft-state', chapter: 4, row: rowOf({ status: 'review' }), draft: draftOf({ state: fullState }), rawIsolated: false, policy: NO_POLICY },
  { id: 'row-without-content', chapter: 4, row: rowOf({ content: null }), draft: null, rawIsolated: false, policy: NO_POLICY },
  { id: 'row-scrubbed', chapter: 4, row: rowOf({ content: `${prose(3)}\n\nThe ferryman is the drowned heir of the tide court, and the tide court knew.` }), draft: null, rawIsolated: false, policy: WITH_SECRET },
  { id: 'draft-body-tail', chapter: 4, row: null, draft: draftOf({ body: longBody(10), state: fullState }), rawIsolated: false, policy: NO_POLICY },
  { id: 'draft-body-stale', chapter: 4, row: null, draft: draftOf({ body: longBody(3), staleReason: 'plan_changed' }), rawIsolated: false, policy: NO_POLICY },
  { id: 'draft-stale-empty-reason', chapter: 4, row: null, draft: draftOf({ body: 'A short ending.', staleReason: '' }), rawIsolated: false, policy: NO_POLICY },
  { id: 'draft-without-body', chapter: 4, row: null, draft: draftOf({ body: '' }), rawIsolated: false, policy: NO_POLICY },
  { id: 'draft-state-only', chapter: 4, row: null, draft: draftOf({ state: { lastAction: 'Ines seals the ledger.' } }), rawIsolated: false, policy: NO_POLICY },
  { id: 'state-string', chapter: 4, row: null, draft: draftOf({ body: 'Ends.', state: 'The weir holds at dusk.' }), rawIsolated: false, policy: NO_POLICY },
  { id: 'state-string-scrubbed', chapter: 4, row: null, draft: draftOf({ body: 'Ends.', state: 'He is the drowned heir of the tide court.' }), rawIsolated: false, policy: WITH_SECRET },
  { id: 'state-number', chapter: 4, row: null, draft: draftOf({ body: 'Ends.', state: 7 }), rawIsolated: false, policy: NO_POLICY },
  { id: 'state-zero', chapter: 4, row: null, draft: draftOf({ body: 'Ends.', state: 0 }), rawIsolated: false, policy: NO_POLICY },
  { id: 'state-false', chapter: 4, row: null, draft: draftOf({ body: 'Ends.', state: false }), rawIsolated: false, policy: NO_POLICY },
  { id: 'state-empty-object', chapter: 4, row: null, draft: draftOf({ body: 'Ends.', state: {} }), rawIsolated: false, policy: NO_POLICY },
  { id: 'state-empty-array', chapter: 4, row: null, draft: draftOf({ body: 'Ends.', state: [] }), rawIsolated: false, policy: NO_POLICY },
  { id: 'state-scrubbed-keys-and-values', chapter: 4, row: null, draft: draftOf({ body: 'Ends.', state: { 'tide court': 'the drowned heir of the tide court', plain: ['ok', 'ferryman_heir'] } }), rawIsolated: false, policy: WITH_SECRET },
  { id: 'state-largest-entry-dropped', chapter: 4, row: null, draft: draftOf({ body: 'Ends.', state: { lastAction: 'Ines seals the ledger.', conflict: sentence('The quarrel', 200), establishedFacts: ['The causeway floods at dusk.'] } }), rawIsolated: false, policy: NO_POLICY },
  { id: 'state-list-entry-loses-items', chapter: 4, row: null, draft: draftOf({ body: 'Ends.', state: { beats: Array.from({ length: 80 }, (_, i) => `${sentence(`Beat ${i}`, 2)}`), lastAction: 'Ines seals the ledger.' } }), rawIsolated: false, policy: NO_POLICY },
  { id: 'state-array-top-level', chapter: 4, row: null, draft: draftOf({ body: 'Ends.', state: ['The weir holds.', sentence('A long list item', 200)] }), rawIsolated: false, policy: NO_POLICY },
  { id: 'state-numeric-looking-keys', chapter: 4, row: null, draft: draftOf({ body: 'Ends.', state: { '10': sentence('ten', 150), '2': 'two', b: sentence('bee', 150), a: 'ay' } }), rawIsolated: false, policy: NO_POLICY },
  { id: 'state-unicode', chapter: 4, row: null, draft: draftOf({ body: 'Ends.', state: { 灯: CJK.repeat(2), emoji: '😀😀', 'é': ['ü', 'ñ'] } }), rawIsolated: false, policy: NO_POLICY },
  { id: 'state-small-caps', chapter: 4, row: null, draft: draftOf({ body: longBody(6), state: spillState }), rawIsolated: false, policy: NO_POLICY, caps: { ending: 120, state: 60 } },
  { id: 'isolated-row-standard', chapter: 4, row: rowOf({ isolated: true }), draft: draftOf({ state: fullState }), rawIsolated: false, policy: NO_POLICY },
  { id: 'isolated-draft-standard', chapter: 4, row: null, draft: draftOf({ isolated: true, state: fullState }), rawIsolated: false, policy: NO_POLICY },
  { id: 'isolated-draft-stale-standard', chapter: 4, row: null, draft: draftOf({ isolated: true, staleReason: 'plan_changed', state: fullState }), rawIsolated: false, policy: NO_POLICY },
  { id: 'isolated-draft-only-flag-standard', chapter: 4, row: rowOf(), draft: draftOf({ isolated: true, state: fullState }), rawIsolated: false, policy: NO_POLICY },
  { id: 'isolated-row-unrestricted-object', chapter: 4, row: rowOf({ isolated: true }), draft: draftOf({ state: spillState }), rawIsolated: true, policy: NO_POLICY },
  { id: 'isolated-draft-unrestricted-array', chapter: 4, row: null, draft: draftOf({ isolated: true, state: ['The weir holds.', sentence('A long list item', 200)] }), rawIsolated: true, policy: NO_POLICY },
  { id: 'isolated-draft-unrestricted-stale', chapter: 4, row: null, draft: draftOf({ isolated: true, staleReason: 'plan_changed', state: fullState }), rawIsolated: true, policy: NO_POLICY },
  { id: 'isolated-unrestricted-null-state', chapter: 4, row: rowOf({ isolated: true, summary: null }), draft: null, rawIsolated: true, policy: NO_POLICY },
  { id: 'isolated-unrestricted-string-state', chapter: 4, row: rowOf({ isolated: true }), draft: draftOf({ state: 'Held at the weir.' }), rawIsolated: true, policy: NO_POLICY },
  { id: 'isolated-unrestricted-zero-state', chapter: 4, row: rowOf({ isolated: true }), draft: draftOf({ state: 0 }), rawIsolated: true, policy: NO_POLICY },
  { id: 'isolated-unrestricted-scrubbed', chapter: 4, row: rowOf({ isolated: true, summary: 'The ferryman is the drowned heir of the tide court.' }), draft: draftOf({ state: { note: 'the tide court' } }), rawIsolated: true, policy: WITH_SECRET },
  { id: 'isolated-unrestricted-long-summary', chapter: 4, row: rowOf({ isolated: true, summary: longBody(40) }), draft: draftOf({ state: spillState }), rawIsolated: true, policy: NO_POLICY },
  { id: 'raw-flag-on-standard-row', chapter: 4, row: rowOf(), draft: draftOf({ state: fullState }), rawIsolated: true, policy: NO_POLICY },
  { id: 'state-equal-length-largest-entries', chapter: 4, row: null, draft: draftOf({ body: 'Ends.', state: { first: sentence('Alpha', 100), second: sentence('Bravo', 100), small: 'kept' } }), rawIsolated: false, policy: NO_POLICY },
  ...[301, 302, 303, 304].map(ending => ({ id: `isolated-unrestricted-odd-room-${ending}`, chapter: 4, row: rowOf({ isolated: true, summary: longBody(40) }), draft: draftOf({ state: spillState }), rawIsolated: true, policy: NO_POLICY, caps: { ending, state: 2_000 } })),
  { id: 'row-cjk-tail', chapter: 4, row: rowOf({ content: `${CJK.repeat(60)}\n\n${CJK.repeat(60)}` }), draft: null, rawIsolated: false, policy: NO_POLICY },
];
for (let index = 0; index < 8; index++) {
  const isolated = rng() < 0.4;
  endingCases.push({
    id: `generated-${index}`,
    chapter: int(1, 30),
    row: rng() < 0.5 ? rowOf({ isolated, status: pick(['done', 'review']), content: rng() < 0.9 ? longBody(int(1, 14)) : null, summary: rng() < 0.8 ? prose(int(1, 30)) : null }) : null,
    draft: rng() < 0.8 ? draftOf({ isolated: rng() < 0.4, body: rng() < 0.8 ? longBody(int(1, 14)) : null, summary: prose(int(1, 6)), staleReason: rng() < 0.3 ? 'plan_changed' : null, state: rng() < 0.7 ? { ...fullState, lastBeat: prose(int(1, 40)) } : null }) : null,
    rawIsolated: rng() < 0.4,
    policy: rng() < 0.4 ? WITH_SECRET : NO_POLICY,
  });
}

const previousEnding = endingCases.map(entry => {
  const policy = policyOf(entry.policy);
  const args = { chapter: entry.chapter, row: entry.row, draft: entry.draft, bridge: undefined, rawIsolated: entry.rawIsolated, disclosure: policy, ...(entry.caps ? { caps: entry.caps } : {}) };
  const previous = packRender.previousEnding(args);
  const result = runPrevious({ previous });
  const draft = entry.draft && { ...entry.draft, state: undefined, stateJson: entry.draft.state === undefined ? null : JSON.stringify(entry.draft.state) };
  return { ...entry, draft, expected: { ending: sectionOut(previous.ending), state: sectionOut(previous.state), ...rendered(result, policy) } };
});

interface View {
  known: Fact[];
  reveals: Fact[];
  hidden: Fact[];
  readerKnows: Fact[];
  pooledPov: { entityKey: string; name: string }[];
  learnedIn: [string, number][] | null;
}

const fact = (key: string, over: Partial<Fact> = {}): Fact => ({ factKey: key, text: `Fact ${key} holds.`, writerNote: null, subjects: null, ...over });
const facts = (count: number, prefix: string, over: (index: number) => Partial<Fact> = () => ({})): Fact[] => Array.from({ length: count }, (_, i) => fact(`${prefix}_${i}`, { text: sentence(`Fact ${i}`, 2), ...over(i) }));

const knowledgeSpecs: { id: string; view: View; chapterCast: string[]; policy: PolicySpec; contract: boolean }[] = [
  { id: 'no-contract-no-clues', view: { known: [], reveals: [], hidden: [], readerKnows: [], pooledPov: [], learnedIn: null }, chapterCast: [], policy: NO_POLICY, contract: false },
  { id: 'no-contract-clues', view: { known: [], reveals: [], hidden: [], readerKnows: [], pooledPov: [], learnedIn: null }, chapterCast: [], policy: WITH_SECRET, contract: false },
  { id: 'contract-nothing-known', view: { known: [], reveals: [], hidden: [], readerKnows: [], pooledPov: [], learnedIn: null }, chapterCast: ['ines'], policy: NO_POLICY, contract: true },
  {
    id: 'contract-small',
    view: {
      known: [fact('salt_binds', { text: 'Salt binds a spoken oath for a year and a day.' }), fact('tide_book', { subjects: ['ines'] })],
      reveals: [fact('warden_drowned', { text: 'The warden drowned his brother.' })],
      hidden: [fact('ferryman_heir', { writerNote: 'The ferryman deflects any talk of family.' }), fact('no_note', { writerNote: null }), fact('blank_note', { writerNote: '   ' })],
      readerKnows: [fact('lamp_lit', { writerNote: 'Nobody mentions the lamp.' }), fact('plain_reader')],
      pooledPov: [{ entityKey: 'ines', name: 'Ines' }],
      learnedIn: [['tide_book', 2]],
    },
    chapterCast: ['ines'],
    policy: NO_POLICY,
    contract: true,
  },
  {
    id: 'contract-two-pov-scrubbed',
    view: {
      known: [fact('a', { text: 'The ferryman is the drowned heir of the tide court.' }), fact('b', { text: 'The tide court is old.' })],
      reveals: [fact('r', { text: 'Reveal: the tide court falls.' })],
      hidden: [fact('h', { writerNote: 'Avoid the tide court.' })],
      readerKnows: [fact('rk', { writerNote: 'The tide court stays unmentioned.' })],
      pooledPov: [{ entityKey: 'ines', name: 'Ines' }, { entityKey: 'oren', name: 'Oren' }],
      learnedIn: [],
    },
    chapterCast: ['ines', 'oren'],
    policy: WITH_SECRET,
    contract: true,
  },
  {
    id: 'known-cut-chapter-subjects-and-latest-first',
    view: {
      known: facts(200, 'learned', i => ({ subjects: i === 0 ? ['ines'] : null })),
      reveals: [],
      hidden: [],
      readerKnows: [],
      pooledPov: [{ entityKey: 'ines', name: 'Ines' }],
      learnedIn: Array.from({ length: 200 }, (_, i) => [`learned_${i}`, 1 + (i % 4)] as [string, number]),
    },
    chapterCast: ['ines'],
    policy: NO_POLICY,
    contract: true,
  },
  {
    id: 'known-all-open-ledgerless',
    view: { known: facts(120, 'open'), reveals: [], hidden: [], readerKnows: [], pooledPov: [], learnedIn: null },
    chapterCast: [],
    policy: NO_POLICY,
    contract: true,
  },
  {
    id: 'reader-knows-and-hidden-cut',
    view: {
      known: [],
      reveals: facts(3, 'rev'),
      hidden: facts(150, 'hid', i => ({ writerNote: `Keep the ${phrase(3, 6)} quiet (${i}).`, subjects: i % 7 === 0 ? ['oren'] : null })),
      readerKnows: facts(90, 'rk', i => ({ writerNote: i % 2 === 0 ? `Stay silent about it ${i}.` : null, subjects: i % 11 === 0 ? ['ines'] : null })),
      pooledPov: [{ entityKey: 'ines', name: 'Ines' }, { entityKey: 'oren', name: 'Oren' }, { entityKey: 'lio', name: 'Lio' }],
      learnedIn: null,
    },
    chapterCast: ['ines', 'oren'],
    policy: NO_POLICY,
    contract: true,
  },
  {
    id: 'one-fact-longer-than-cap',
    view: { known: [fact('huge', { text: sentence('Huge', 400) }), fact('small')], reveals: [], hidden: [fact('hugenote', { writerNote: sentence('Quiet', 300) })], readerKnows: [fact('hugerk', { text: sentence('Reader', 300) })], pooledPov: [], learnedIn: null },
    chapterCast: [],
    policy: NO_POLICY,
    contract: true,
  },
  {
    id: 'unicode-facts',
    view: {
      known: [fact('灯', { text: `${CJK}${CJK}`, subjects: ['灯塔'] }), fact('émoji', { text: 'Marée 🌊 monte' })],
      reveals: [fact('révèle', { text: 'Résumé — « voilà »' })],
      hidden: [fact('hidé', { writerNote: 'Ne dis rien — 😀' })],
      readerKnows: [fact('lecteur', { writerNote: '静かに' })],
      pooledPov: [{ entityKey: 'tō', name: 'Tō 灯' }],
      learnedIn: [['émoji', 3], ['灯', 3]],
    },
    chapterCast: ['灯塔'],
    policy: NO_POLICY,
    contract: true,
  },
  {
    id: 'clues-from-several-facts',
    view: { known: [], reveals: [], hidden: [], readerKnows: [], pooledPov: [], learnedIn: null },
    chapterCast: [],
    policy: {
      chapter: 5,
      lockedFacts: [SECRET, { factKey: 'second_secret', text: 'The weir was built over a grave', terms: ['weir grave'], allowedClues: ['Cold air near the weir', 'A salt-stained signet ring on the ferryman', '  padded clue  ', 'weir grave explained'] }],
      plannerOnly: [],
      plannerPages: [],
    },
    contract: false,
  },
  {
    id: 'many-clues-over-cap',
    view: { known: [], reveals: [], hidden: [], readerKnows: [], pooledPov: [], learnedIn: null },
    chapterCast: [],
    policy: { chapter: 5, lockedFacts: [{ factKey: 'long_secret', text: 'A buried truth about the harbour', allowedClues: Array.from({ length: 120 }, (_, i) => `Clue ${i}: ${phrase(6, 12)}`) }], plannerOnly: [], plannerPages: [] },
    contract: false,
  },
];

const knowledge = knowledgeSpecs.map(spec => {
  const policy = policyOf(spec.policy);
  const learnedIn = spec.view.learnedIn === null ? undefined : new Map(spec.view.learnedIn);
  const view = { ...spec.view, learnedIn };
  const result = runKnowledge({ view, chapterCast: new Set(spec.chapterCast), disclosure: policy, knowledgeContract: spec.contract });
  return { id: spec.id, view: spec.view, chapterCast: spec.chapterCast, policy: spec.policy, contract: spec.contract, expected: rendered(result, policy) };
});

interface LedgerEntry {
  kind: string;
  topic: string;
  statement: string;
  why: string | null;
  rejectedAlternatives: string[];
  writerLine: string | null;
  decidedBy: string;
}
const entry = (topic: string, over: Partial<LedgerEntry> = {}): LedgerEntry => ({ kind: 'decision', topic, statement: `Statement for ${topic}`, why: null, rejectedAlternatives: [], writerLine: `Writer line for ${topic}.`, decidedBy: 'author', ...over });
const ledgerSpecs: { id: string; entries: LedgerEntry[]; policy: PolicySpec }[] = [
  { id: 'empty', entries: [], policy: NO_POLICY },
  { id: 'no-writer-lines', entries: [entry('a', { writerLine: null }), entry('b', { writerLine: '' })], policy: NO_POLICY },
  { id: 'kinds-filtered', entries: [entry('a'), entry('b', { kind: 'direction' }), entry('c', { kind: 'backlog' }), entry('d', { kind: 'rejected' }), entry('e', { kind: 'system', decidedBy: 'system' })], policy: NO_POLICY },
  { id: 'scrubbed-and-blanked', entries: [entry('a', { writerLine: 'The ferryman is the drowned heir of the tide court.' }), entry('b', { writerLine: '  padded line  ' }), entry('c', { writerLine: 'the tide court' })], policy: WITH_SECRET },
  { id: 'duplicate-topics', entries: [entry('a'), entry('a', { writerLine: 'Second line for a.' }), entry('b')], policy: NO_POLICY },
  { id: 'over-budget-newest-first', entries: Array.from({ length: 60 }, (_, i) => entry(`topic_${i}`, { writerLine: `${sentence(`Line ${i}`, 2)}`.trim() })), policy: NO_POLICY },
  { id: 'long-line-skipped-short-kept', entries: [entry('old_short', { writerLine: 'Short old line.' }), entry('mid_long', { writerLine: sentence('Long', 200).trim() }), entry('new_short', { writerLine: 'Short new line.' })], policy: NO_POLICY },
  { id: 'unicode', entries: [entry('灯', { writerLine: `${CJK}` }), entry('émoji', { writerLine: 'Marée 🌊 — « note »' })], policy: NO_POLICY },
];
const writerLines = ledgerSpecs.map(spec => {
  const policy = policyOf(spec.policy);
  const result = runWriterLines({ ledger: spec.entries, disclosure: policy });
  return { id: spec.id, entries: spec.entries, policy: spec.policy, expected: rendered(result, policy) };
});

interface BriefCase {
  id: string;
  chapter: number;
  brief: any;
  facts: (Fact & { revealChapter?: number })[];
  policy: PolicySpec;
}
const ENDING = {
  hookType: 'turn',
  emotionalBeat: 'Dread of the tide court',
  openQuestion: 'Who lit the lamp?',
  handoffState: 'The barge drifts past the tide court.',
  mustNotResolve: ['fact:ferryman_heir'],
};
const specBrief = { body: 'The ferryman rows toward the tide court.\nHint that The ferryman is the drowned heir of the tide court.', chapterPurpose: 'Tease the tide court.', guidance: null, endingContract: ENDING };
const briefCases: BriefCase[] = [
  { id: 'spec-withheld-before-reveal', chapter: 5, brief: specBrief, facts: [SECRET], policy: WITH_SECRET },
  { id: 'spec-reveal-chapter-in-full', chapter: 12, brief: { ...specBrief, endingContract: { ...ENDING, mustNotResolve: [] } }, facts: [SECRET], policy: { chapter: 12, lockedFacts: [], plannerOnly: [], plannerPages: [] } },
  { id: 'null-brief', chapter: 5, brief: null, facts: [], policy: NO_POLICY },
  { id: 'body-only', chapter: 5, brief: { body: 'Ines crosses the salt flats at night.' }, facts: [], policy: NO_POLICY },
  { id: 'empty-body-directives-only', chapter: 5, brief: { body: '', pov: 'ines', chapterPurpose: 'Show the weir.' }, facts: [], policy: NO_POLICY },
  { id: 'every-directive', chapter: 5, brief: { body: 'Scene one.\nScene two.', pov: '  ines  ', chapterPurpose: ' Cross the flats. ', readerValue: ['dread', '  wonder  ', '', '   ', 7, null], repetitionRisks: ['night crossings', ' bells '], guidance: '  Keep it quiet.  ' }, facts: [], policy: NO_POLICY },
  { id: 'blank-directives-dropped', chapter: 5, brief: { body: 'Body.', pov: '   ', chapterPurpose: '', readerValue: [], repetitionRisks: 'not a list', guidance: '  ' }, facts: [], policy: NO_POLICY },
  { id: 'whitespace-body-kept', chapter: 5, brief: { body: '  \n  ', pov: 'ines' }, facts: [], policy: NO_POLICY },
  { id: 'ending-no-must-not-resolve', chapter: 5, brief: { body: 'Plan.', endingContract: { ...ENDING, mustNotResolve: undefined } }, facts: [SECRET], policy: NO_POLICY },
  { id: 'ending-plain-entries-kept', chapter: 5, brief: { body: 'Plan.', endingContract: { ...ENDING, mustNotResolve: ['thread:heir_mystery', 'fact:ferryman_heir', 'ferryman_heir', 'fact:ferryman_heir'] } }, facts: [SECRET], policy: NO_POLICY },
  { id: 'ending-fact-without-note', chapter: 5, brief: { body: 'Plan.', endingContract: { ...ENDING, mustNotResolve: ['fact:silent', 'fact:missing', ' silent '] } }, facts: [{ factKey: 'silent', text: 'A silent truth', writerNote: null }, { factKey: 'blank', text: 'Another', writerNote: '   ' }], policy: NO_POLICY },
  { id: 'ending-note-padded-and-duplicated', chapter: 5, brief: { body: 'Plan.', endingContract: { ...ENDING, mustNotResolve: ['fact:a', 'fact:b', 'fact:c'] } }, facts: [{ factKey: 'a', text: 'A', writerNote: ' Same note. ' }, { factKey: 'b', text: 'B', writerNote: 'Same note.' }, { factKey: 'c', text: 'C', writerNote: null }], policy: NO_POLICY },
  { id: 'ending-without-contract-fields-unicode', chapter: 5, brief: { body: `${CJK}\nÉmoji 🌊`, chapterPurpose: '灯を守る', endingContract: { hookType: 'cliffhanger', emotionalBeat: '😀', openQuestion: 'Qui ?', handoffState: '潮が満ちる', mustNotResolve: ['fact:灯'] } }, facts: [{ factKey: '灯', text: 'Truth', writerNote: '静かに' }], policy: NO_POLICY },
  { id: 'scrubs-planner-only-and-keys', chapter: 5, brief: { body: 'The lighthouse was never abandoned, says ferryman_heir.', guidance: 'See fact:ferryman_heir.' }, facts: [SECRET], policy: WITH_SECRET },
];
const brief = await Promise.all(
  briefCases.map(async spec => {
    const policy = policyOf(spec.policy);
    const db = { query: { canonFacts: { findMany: async () => spec.facts } } } as never;
    const loaded = await writerBrief.loadWriterBrief(db, 1n, spec.chapter, spec.brief, policy);
    return { ...spec, expected: { chapterBrief: loaded.chapterBrief, endingContract: loaded.endingContract, withheld: withheldOf(policy) } };
  }),
);

const styleSpecs: { id: string; stored: string | null; policy: PolicySpec }[] = [
  { id: 'none', stored: null, policy: NO_POLICY },
  { id: 'empty', stored: '', policy: NO_POLICY },
  { id: 'additions', stored: 'Keep the narrator dry and close.\nNo exclamation marks.', policy: NO_POLICY },
  { id: 'additions-scrubbed', stored: 'Never mention the tide court.', policy: WITH_SECRET },
  { id: 'additions-over-budget', stored: Array.from({ length: 80 }, (_, i) => `Rule ${i}: ${phrase(20, 40)}.`).join('\n\n'), policy: NO_POLICY },
  { id: 'additions-unicode', stored: `${CJK}\n\nÉcris sobrement. 🌊`, policy: NO_POLICY },
];
const writingStyle = styleSpecs.map(spec => {
  const policy = policyOf(spec.policy);
  const section = packRender.writingStyleSection(spec.stored, policy);
  return { ...spec, expected: { section: sectionOut(section), withheld: withheldOf(policy) } };
});

const caps = { ...writerContext.WRITER_SECTION_CAPS };
const priorities = { ...writerContext.WRITER_OPTIONAL_PRIORITY };
if (typeof sectionsModule.renderSection !== 'function') throw new Error('sections module drifted');

writeFileSync(join(outDir, 'writer-pack-render.json'), `${JSON.stringify({ caps, priorities, completedVolumes, previousEnding, knowledge, writerLines, brief, writingStyle })}\n`);
