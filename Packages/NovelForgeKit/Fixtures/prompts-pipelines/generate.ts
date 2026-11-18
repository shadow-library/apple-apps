import { plugin } from 'bun';
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// Run as: PLATFORM_REPO=<checkout> bun --tsconfig-override "$PLATFORM_REPO/apps/novel-forge-server/tsconfig.json" generate.ts (the reference schemas use legacy decorators)
// The snapshots pin UNCOMMITTED reference edits (user decision: port the working copy): prompt-caching.ts (stableMessages), prompts/types.ts, and the editorial brief sliced from modules/review/chapter-review.service.ts; regenerate if they change.
const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');

const server = join(platformRepo, 'apps/novel-forge-server/src');
const outDir = dirname(fileURLToPath(import.meta.url));
const classes = await import(join(server, 'classes/app-error-code.ts'));
const sdk = await import(join(platformRepo, 'packages/sdk/src/index.ts'));

const commonExports: Record<string, unknown> = {};
for (const file of readdirSync(join(server, 'common')).filter(name => name.endsWith('.ts') && !name.endsWith('.spec.ts') && name !== 'index.ts').sort()) {
  try {
    Object.assign(commonExports, await import(join(server, 'common', file)));
  } catch {
    continue;
  }
}

const columns = (table: string): unknown => new Proxy({}, { get: (_, column) => (column === 'enumValues' ? [] : `${table}.${String(column)}`) });
const schema = new Proxy({}, { get: (_, table) => columns(String(table)) });

plugin({
  name: 'prompts-pipelines-fixture-stubs',
  setup(build) {
    build.module('@server/classes', () => ({ exports: { AppErrorCode: classes.AppErrorCode }, loader: 'object' }));
    build.module('@server/common', () => ({ exports: commonExports, loader: 'object' }));
    build.module('@server/database', () => ({ exports: { schema }, loader: 'object' }));
    build.module('@server/database/schemas', () => ({ exports: { bibleSection: { enumValues: [] } }, loader: 'object' }));
    build.module('@shadow-library/sdk', () => ({ exports: sdk, loader: 'object' }));
  },
});

const ai = join(server, 'modules/ai');
const plan = await import(join(ai, 'prompts/chapter-plan.prompt.ts'));
const outline = await import(join(ai, 'prompts/outline.prompt.ts'));
const continuity = await import(join(ai, 'prompts/continuity.prompt.ts'));
const refresh = await import(join(ai, 'prompts/chapter-canon-refresh.prompt.ts'));
const review = await import(join(ai, 'prompts/review.prompt.ts'));
const summarize = await import(join(ai, 'prompts/chapter-summarize.prompt.ts'));
const caching = await import(join(ai, 'prompt-caching.ts'));
const validate = await import(join(ai, 'schemas/validate.ts'));
const isolation = await import(join(ai, 'isolation-read-policy.ts'));
const planSchema = await import(join(ai, 'schemas/chapter-plan.schema.ts'));
const continuitySchema = await import(join(ai, 'schemas/continuity.schema.ts'));
const refreshSchema = await import(join(ai, 'schemas/chapter-canon-refresh.schema.ts'));
const reviewSchema = await import(join(ai, 'schemas/review.schema.ts'));
const summarizeSchema = await import(join(ai, 'schemas/chapter-summarize.schema.ts'));

const ROLES: Record<string, string> = { system: 'system', human: 'user', ai: 'assistant' };

const textOf = (content: unknown): string => {
  if (typeof content === 'string') return content;
  if (Array.isArray(content) && content.length === 1 && typeof content[0]?.text === 'string') return content[0].text;
  throw new Error(`unexpected message content ${JSON.stringify(content)}`);
};
const toMessages = (messages: any[]) => messages.map(message => ({ role: ROLES[message.getType()], text: textOf(message.content), cached: Array.isArray(message.content) }));
const breakpointsOf = (messages: any[]): number[] => toMessages(messages).flatMap((message, index) => (message.cached ? [index] : []));

const sliceBetween = (source: string, from: string, to: string, what: string): string => {
  const start = source.indexOf(from);
  const end = start === -1 ? -1 : source.indexOf(to, start);
  if (start === -1 || end === -1) throw new Error(`${what} moved in the reference`);
  return source.slice(start, end + to.length);
};
const transpiler = new Bun.Transpiler({ loader: 'ts' });
const readSource = (path: string): string => readFileSync(join(server, path), 'utf8');
const requireMarkers = (source: string, markers: string[], what: string): void => {
  for (const marker of markers) if (!source.includes(marker)) throw new Error(`${what} no longer holds ${marker}`);
};

const filler = (label: string, tokens: number): string => `${label}\n${'The lamp room kept its slow count of ships. '.repeat(Math.ceil(tokens / 9))}`;

const planService = readSource('modules/actions/chapter-plan.service.ts');
const planConstantsSource = ['const NONE =', 'const ENDING =', 'const NOT_ENDING ='].map(marker => sliceBetween(planService, marker, "';", `the plan constant ${marker}`)).join('\n');
const planConstants = new Function(`${planConstantsSource}\nreturn { none: NONE, ending: ENDING, notEnding: NOT_ENDING };`)() as { none: string; ending: string; notEnding: string };

const CATALOG = `## Entities\n- mara (character): keeper of the lighthouse\n- kai (character): her apprentice\n\n## Chapters\n- chapter:3 The Sealed Letter\n\n## Threads\n- thread:letter_sender: who wrote the letter?\n${filler('## BIBLE DOCUMENTS', 300)}`;
const OBLIGATIONS = '- Hand-on from chapter 3: Kai holds the sealed letter.\n- thread:letter_sender has waited the longest.';
const MILESTONES = '- first_light: the lamp is lit again (mara) — claiming it unlocks: lamp_origin';

const targets = [
  { name: 'default', min: 1800, aim: 2200, max: 2600 },
  { name: 'custom', min: 900, aim: 1000, max: 1100 },
  { name: 'large', min: 12000, aim: 15000, max: 18000 },
  { name: 'fractional', min: 1234.5678, aim: 1500.25, max: 1999.9999 },
  { name: 'tiny', min: 0, aim: 7, max: 999 },
  { name: 'half-scene', min: 1000, aim: 1125, max: 1250 },
  { name: 'million', min: 1000000, aim: 1500000, max: 2000000 },
];
const planInputs = [
  { name: 'first-chapter-empty', chapterNumber: '1', catalog: '', obligations: '(none)', milestones: '(none open)', endingNote: planConstants.notEnding, authorIntent: planConstants.none, chosenDirection: planConstants.none },
  { name: 'mid-intent', chapterNumber: '12', catalog: CATALOG, obligations: OBLIGATIONS, milestones: MILESTONES, endingNote: planConstants.notEnding, authorIntent: 'Mara and Kai cross the harbour; the ferry stalls.', chosenDirection: planConstants.none },
  { name: 'mid-direction', chapterNumber: '12', catalog: CATALOG, obligations: OBLIGATIONS, milestones: MILESTONES, endingNote: planConstants.notEnding, authorIntent: planConstants.none, chosenDirection: 'Kai opens the letter at sea.' },
  { name: 'final-chapter', chapterNumber: '48', catalog: CATALOG, obligations: OBLIGATIONS, milestones: '(none open)', endingNote: planConstants.ending, authorIntent: 'The lamp burns out.', chosenDirection: 'Quiet, earned rest.' },
  { name: 'unicode', chapterNumber: '7', catalog: 'Café ☕ — “quoted” 😀 {catalog} {{x}} $& \\n', obligations: '{obligations}', milestones: '{milestones}', endingNote: planConstants.ending, authorIntent: '{authorIntent} {wordTargetMin}', chosenDirection: '{chosenDirection}' },
];
const planCases: any[] = [];
for (const input of planInputs)
  for (const target of targets) {
    const vars = { ...input, ...outline.outlineWordTargetVars(target) };
    planCases.push({ name: `${input.name}-${target.name}`, input, target, vars: outline.outlineWordTargetVars(target), messages: toMessages(await plan.chapterPlanPrompt.template.formatMessages(vars)) });
  }

const continuityInputs = [
  { name: 'first-empty', contextPack: '', chapterNumber: 1, chapterProse: '' },
  { name: 'mid-full', contextPack: '## ENTITY ROSTER\nmara (character): Mara\n\n## EXISTING THREADS\nletter_sender (open): who wrote the letter?\n\n## EXISTING MYSTERIES\nnone\n\n## MILESTONES\nfirst_light (open, claimed by this chapter): the lamp is lit', chapterNumber: 12, chapterProse: 'Mara climbed the stair. “Hold on,” said Kai.' },
  { name: 'final-large', contextPack: filler('## ENTITY ROSTER', 1500), chapterNumber: 48, chapterProse: filler('Chapter prose', 3000) },
  { name: 'unicode', contextPack: 'Pack {contextPack} 😀', chapterNumber: 100, chapterProse: 'Café ☕ {chapterProse} $& {{x}}\\n' },
];
const continuityCases = [];
for (const input of continuityInputs) {
  const standard = await continuity.continuityPrompt.template.formatMessages(input);
  const isolatedPack = isolation.isolatedExtractionContext(input.contextPack);
  const walled = await continuity.continuityPrompt.template.formatMessages({ ...input, contextPack: isolatedPack });
  continuityCases.push({ ...input, standard: toMessages(standard), isolatedPack, isolated: toMessages(walled) });
}

const graphSource = readSource('modules/ai/graphs/chapter-finalization.graph.ts');
const rosterSource = sliceBetween(graphSource, 'export async function continuityRoster', '/** Re-indexes', 'continuityRoster');
requireMarkers(rosterSource, ['## ENTITY ROSTER', '## EXISTING THREADS', '## EXISTING MYSTERIES', 'threadRoster', 'mysteryRoster'], 'continuityRoster');
const makeRoster = new Function('eq', 'schema', `${transpiler.transformSync(rosterSource.replace('export async function', 'async function').replace(/\/\*\* Re-indexes$/, ''))}\nreturn continuityRoster;`)(
  () => null,
  schema,
) as (db: unknown, projectId: bigint) => Promise<string>;
const rosterCases: any[] = [];
const rosterRows = [
  { name: 'empty', entities: [], threads: [], mysteries: [] },
  {
    name: 'full',
    entities: [
      { entityKey: 'mara', name: 'Mara Venn', type: 'character' },
      { entityKey: 'north_pier', name: 'The North Pier', type: 'location' },
    ],
    threads: [
      { threadKey: 'letter_sender', status: 'open', summary: 'who wrote the letter?' },
      { threadKey: 'tide_debt', status: 'closed', summary: null },
    ],
    mysteries: [
      { mysteryKey: 'lamp_origin', status: 'open', question: 'where did the lamp come from?' },
      { mysteryKey: 'drowned_bell', status: 'resolved', question: null },
    ],
  },
  { name: 'unicode', entities: [{ entityKey: 'café', name: 'Café ☕ {x}', type: 'item' }], threads: [], mysteries: [{ mysteryKey: 'q', status: 'open', question: '“why”?' }] },
];
for (const rows of rosterRows) {
  const db = { query: { entities: { findMany: async () => rows.entities }, plotThreads: { findMany: async () => rows.threads }, mysteries: { findMany: async () => rows.mysteries } } };
  rosterCases.push({ ...rows, text: await makeRoster(db, 1n) });
}

const finalizeSource = readSource('modules/finalize-review/finalize-review.service.ts');
const packSource = sliceBetween(finalizeSource, 'const claimed = brief?.claimedMilestones', 'const contextPack = `${roster}\\n\\n## MILESTONES\\n${milestoneRoster || \'none\'}`;', 'the milestone context pack');
requireMarkers(packSource, ['claimed by this chapter', 'milestoneRoster', 'm.milestoneKey', 'm.state', 'm.label'], 'the milestone context pack');
const makePack = new Function(`${transpiler.transformSync(`function pack(brief, milestones, roster) {\n${packSource}\nreturn contextPack;\n}`)}\nreturn pack;`)() as (brief: unknown, milestones: unknown[], roster: string) => string;
const milestoneRows = [
  { milestoneKey: 'first_light', label: 'the lamp is lit', state: 'open' },
  { milestoneKey: 'storm_warning', label: 'the storm is named', state: 'reached' },
];
const packCases = [
  { name: 'none', roster: '## ENTITY ROSTER\nnone', milestones: [], claimed: null },
  { name: 'no-brief', roster: '## ENTITY ROSTER\nmara (character): Mara', milestones: milestoneRows, claimed: null },
  { name: 'claimed', roster: '## ENTITY ROSTER\nmara (character): Mara', milestones: milestoneRows, claimed: ['first_light'] },
  { name: 'unicode', roster: 'Café ☕', milestones: [{ milestoneKey: 'é', label: '“x” {y}', state: 'open' }], claimed: ['é'] },
].map(entry => ({ ...entry, text: makePack(entry.claimed === null ? null : { claimedMilestones: entry.claimed }, entry.milestones, entry.roster) }));

const refreshInputs = [
  { name: 'short', material: '## Story Bible pages\ndoc:world/harbour\nThe harbour is quiet.', chapterProse: 'The ferry stalled.' },
  { name: 'long', material: filler('## Story Bible pages', 1500), chapterProse: 'Mara lit the lamp. “Hold on,” said Kai.' },
  { name: 'empty', material: '', chapterProse: '' },
  { name: 'unicode', material: 'Café ☕ {material} 😀', chapterProse: '“Quoted” {chapterProse} $& {{x}}' },
];
const refreshCases = [];
for (const input of refreshInputs) {
  const messages = await refresh.chapterCanonRefreshPrompt.template.formatMessages(input);
  const marked = caching.applyAnthropicCacheControl(messages, { skipHumans: 0, stableMessages: refresh.chapterCanonRefreshPrompt.cacheStrategy.stableMessages ?? 1 });
  refreshCases.push({ ...input, messages: toMessages(messages), breakpoints: breakpointsOf(marked) });
}

const reviewService = readSource('modules/review/chapter-review.service.ts');
const briefSource = sliceBetween(reviewService, 'const chapterBrief = [', ".join('\\n\\n');", 'the editorial chapter brief');
requireMarkers(briefSource, ['(no plan was written for this chapter)', 'writerBrief.chapterBrief', 'writerBrief.endingContract'], 'the editorial chapter brief');
const makeBrief = new Function(`${transpiler.transformSync(`function brief(brief, writerBrief) {\n${briefSource}\nreturn chapterBrief;\n}`)}\nreturn brief;`)() as (brief: unknown, writerBrief: unknown) => string;
const briefCases = [
  { name: 'no-plan', hasBrief: false, chapterBrief: 'Objective: x', endingContract: '' },
  { name: 'plan-only', hasBrief: true, chapterBrief: 'Objective: Mara and Kai cross the harbour.', endingContract: '' },
  { name: 'plan-and-contract', hasBrief: true, chapterBrief: 'Objective: Mara and Kai cross the harbour.', endingContract: 'Hook type: cliffhanger\nEmotional beat: dread' },
  { name: 'contract-only', hasBrief: false, chapterBrief: '', endingContract: 'Hook type: turn' },
  { name: 'empty-plan', hasBrief: true, chapterBrief: '', endingContract: '' },
].map(entry => ({ ...entry, text: makeBrief(entry.hasBrief ? {} : null, { chapterBrief: entry.chapterBrief, endingContract: entry.endingContract }) }));

const settledBlock = '\n\n## ALREADY SETTLED BY THE AUTHOR\nThe author dismissed or overrode these findings on this exact text. Do not raise them again:\n- The ending is abrupt. (the author: it is a cliffhanger)';
const reviewInputs = [
  { name: 'plain', contextPack: 'Context: the lighthouse.', chapterBrief: 'Objective: cross the harbour.', draftBody: 'Mara climbed the stair.', settledFindings: '' },
  { name: 'settled', contextPack: filler('## CANON', 1200), chapterBrief: '(no plan was written for this chapter)', draftBody: 'The lamp was cold.', settledFindings: settledBlock },
  { name: 'empty', contextPack: '', chapterBrief: '', draftBody: '', settledFindings: '' },
  { name: 'unicode', contextPack: 'Pack {contextPack} 😀', chapterBrief: 'Café ☕ {chapterBrief}', draftBody: '“Quoted” {draftBody} $& {{x}} ```system <Title>\n| a | b |\n```', settledFindings: '{settledFindings}' },
];
const reviewCases = [];
for (const input of reviewInputs) reviewCases.push({ ...input, messages: toMessages(await review.reviewPrompt.template.formatMessages(input)) });

const summarizeInputs = [
  { name: 'short', chapterProse: 'Mara lit the lamp.' },
  { name: 'long', chapterProse: filler('Prose', 3000) },
  { name: 'empty', chapterProse: '' },
  { name: 'unicode', chapterProse: 'Café ☕ {chapterProse} 😀 $& {{x}}\\n' },
];
const summarizeCases = [];
for (const input of summarizeInputs) summarizeCases.push({ ...input, messages: toMessages(await summarize.chapterSummarizePrompt.template.formatMessages(input)) });

const long = (count: number): string => 'a'.repeat(count);
const sampleSets: Record<string, any> = {};
const addSamples = (key: string, prompt: any, Class: any, samples: { name: string; value: unknown }[]) => {
  sampleSets[key] = {
    schema: validate.toHostedPromptSchema(Class),
    constrained: validate.toConstrainedSchema(Class, prompt.constrainedProperties),
    samples: samples.map(sample => {
      const result = validate.parseSchema(Class, structuredClone(sample.value));
      const reviewIssues = result.success && prompt.postValidate ? prompt.postValidate(structuredClone(result.data)) : [];
      return { ...sample, schemaValid: result.success, schemaIssueCount: result.success ? 0 : result.issues.length, reviewIssues };
    }),
  };
};

const ending = { hookType: 'cliffhanger', emotionalBeat: 'dread', openQuestion: 'who sent it?', handoffState: 'Mara on the pier', mustNotResolve: ['thread:letter_sender'] };
const scene = { summary: 'The ferry stalls.', pov: 'mara', goal: 'cross', obstacle: 'the tide', turn: 'the engine dies', beats: ['the engine coughs', 'Kai swears'], estimatedWords: 700 };
const planBase = { title: 'The Stalled Ferry', objective: 'Cross the harbour.', scenes: [scene], requiredContext: ['entity:mara'], endingContract: ending, chapterPurpose: 'Strand them at sea.', readerValue: ['new_information'] };
addSamples('chapterPlan', plan.chapterPlanPrompt, planSchema.ChapterPlanSchema, [
  { name: 'minimal', value: planBase },
  { name: 'full', value: { ...planBase, continuesIntoNextChapter: true, startsFromPreviousChapter: true, handoffBeat: 'mid-swing', knowledgeContract: { pov: ['mara'], learns: [{ entityKey: 'mara', factKey: 'lamp_origin' }] }, claimedMilestones: ['first_light'], repetitionRisks: ['another crossing'], densityRisk: 'thin material', moves: 'thread:letter_sender' } },
  { name: 'scene-without-pov', value: { ...planBase, scenes: [{ ...scene, pov: undefined }] } },
  { name: 'no-scenes', value: { ...planBase, scenes: [] } },
  { name: 'scene-empty-summary', value: { ...planBase, scenes: [{ ...scene, summary: '' }] } },
  { name: 'scene-no-beats', value: { ...planBase, scenes: [{ ...scene, beats: [] }] } },
  { name: 'scene-zero-words', value: { ...planBase, scenes: [{ ...scene, estimatedWords: 0 }] } },
  { name: 'scene-fractional-words', value: { ...planBase, scenes: [{ ...scene, estimatedWords: 700.5 }] } },
  { name: 'scene-extra', value: { ...planBase, scenes: [{ ...scene, mood: 'x' }] } },
  { name: 'missing-title', value: { ...planBase, title: undefined } },
  { name: 'empty-title', value: { ...planBase, title: '' } },
  { name: 'missing-ending', value: { ...planBase, endingContract: undefined } },
  { name: 'unknown-hook', value: { ...planBase, endingContract: { ...ending, hookType: 'twist' } } },
  { name: 'empty-purpose', value: { ...planBase, chapterPurpose: '' } },
  { name: 'empty-reader-value', value: { ...planBase, readerValue: [] } },
  { name: 'unknown-reader-value', value: { ...planBase, readerValue: ['plot_twist'] } },
  { name: 'mixed-reader-value', value: { ...planBase, readerValue: ['emotional_turn', 'plot_twist'] } },
  { name: 'continues-without-handoff', value: { ...planBase, continuesIntoNextChapter: true } },
  { name: 'continues-blank-handoff', value: { ...planBase, continuesIntoNextChapter: true, handoffBeat: '   ' } },
  { name: 'starts-without-handoff', value: { ...planBase, startsFromPreviousChapter: true } },
  { name: 'starts-with-handoff', value: { ...planBase, startsFromPreviousChapter: true, handoffBeat: 'the pier' } },
  { name: 'handoff-without-flag', value: { ...planBase, handoffBeat: 'the pier' } },
  { name: 'continues-false', value: { ...planBase, continuesIntoNextChapter: false } },
  { name: 'flag-string', value: { ...planBase, continuesIntoNextChapter: 'yes' } },
  { name: 'knowledge-empty-pov', value: { ...planBase, knowledgeContract: { pov: [] } } },
  { name: 'knowledge-pov-only', value: { ...planBase, knowledgeContract: { pov: ['mara'] } } },
  { name: 'knowledge-uppercase-key', value: { ...planBase, knowledgeContract: { pov: ['mara'], learns: [{ entityKey: 'Mara', factKey: 'lamp_origin' }] } } },
  { name: 'knowledge-dash-key', value: { ...planBase, knowledgeContract: { pov: ['mara'], learns: [{ entityKey: 'mara', factKey: 'lamp-origin' }] } } },
  { name: 'knowledge-empty-key', value: { ...planBase, knowledgeContract: { pov: ['mara'], learns: [{ entityKey: '', factKey: 'x' }] } } },
  { name: 'knowledge-newline-key', value: { ...planBase, knowledgeContract: { pov: ['mara'], learns: [{ entityKey: 'mara\n', factKey: 'x' }] } } },
  { name: 'knowledge-digits-key', value: { ...planBase, knowledgeContract: { pov: ['mara'], learns: [{ entityKey: 'mara_2', factKey: '0_9' }] } } },
  { name: 'knowledge-null', value: { ...planBase, knowledgeContract: null } },
  { name: 'empty-density-risk', value: { ...planBase, densityRisk: '' } },
  { name: 'empty-moves', value: { ...planBase, moves: '' } },
  { name: 'milestones-not-strings', value: { ...planBase, claimedMilestones: [1] } },
  { name: 'extra', value: { ...planBase, subtitle: 'x' } },
  { name: 'array', value: [planBase] },
  { name: 'null', value: null },
]);

addSamples('continuity', continuity.continuityPrompt, continuitySchema.ContinuitySchema, [
  { name: 'empty', value: { appeared: [], newEntities: [], threads: [], mysteries: [], timeline: [], relationships: [], power: [], characterStates: [], knowledgeChanges: [], chapterSummary: 'Mara lit the lamp.' } },
  {
    name: 'full',
    value: {
      milestones: [{ milestoneKey: 'first_light', reached: true, evidence: 'the lamp caught' }],
      appeared: ['mara', 'kai'],
      newEntities: [{ entityKey: 'ferryman', name: 'The Ferryman', type: 'character', notes: 'gruff' }],
      threads: [{ threadKey: 'letter_sender', status: 'open', summary: 'still unknown', intentionallyOpen: true, confidence: 'low' }],
      mysteries: [{ mysteryKey: 'lamp_origin', status: 'open', question: 'where from?', intentionallyOpen: false, truthFactKey: 'lamp_made', confidence: 'high' }],
      timeline: [{ whenText: 'dusk', event: 'the ferry stalled', significance: 'sets up the storm' }],
      relationships: [{ entityKey: 'mara', targetKey: 'kai', kind: 'mentor', note: 'warming', evidence: '“Hold on,” she said.', confidence: 'low' }],
      power: [{ character: 'mara', stage: 'keeper', feat: 'lit the lamp', next: 'the long watch' }],
      characterStates: [{ entityKey: 'mara', location: 'the lamp room', conditions: ['tired'], immediateGoal: 'wait', statusNote: 'hopeful', evidence: 'she sat down', confidence: 'high' }],
      knowledgeChanges: [{ entityKey: 'kai', factKey: 'lamp_made', how: 'read it in the letter' }],
      chapterSummary: 'They crossed and the lamp was lit.',
    },
  },
  { name: 'missing-summary', value: { appeared: [], newEntities: [], threads: [], mysteries: [], timeline: [], relationships: [], power: [], characterStates: [], knowledgeChanges: [] } },
  { name: 'empty-summary', value: { appeared: [], newEntities: [], threads: [], mysteries: [], timeline: [], relationships: [], power: [], characterStates: [], knowledgeChanges: [], chapterSummary: '' } },
  { name: 'missing-list', value: { appeared: [], newEntities: [], threads: [], mysteries: [], timeline: [], relationships: [], power: [], characterStates: [], chapterSummary: 'x' } },
  { name: 'bad-entity-type', value: { appeared: [], newEntities: [{ entityKey: 'x', name: 'X', type: 'planet' }], threads: [], mysteries: [], timeline: [], relationships: [], power: [], characterStates: [], knowledgeChanges: [], chapterSummary: 'x' } },
  { name: 'bad-thread-status', value: { appeared: [], newEntities: [], threads: [{ threadKey: 't', status: 'stale' }], mysteries: [], timeline: [], relationships: [], power: [], characterStates: [], knowledgeChanges: [], chapterSummary: 'x' } },
  { name: 'bad-confidence', value: { appeared: [], newEntities: [], threads: [{ threadKey: 't', status: 'open', confidence: 'medium' }], mysteries: [], timeline: [], relationships: [], power: [], characterStates: [], knowledgeChanges: [], chapterSummary: 'x' } },
  { name: 'relationship-no-evidence', value: { appeared: [], newEntities: [], threads: [], mysteries: [], timeline: [], relationships: [{ entityKey: 'a', targetKey: 'b', kind: 'ally' }], power: [], characterStates: [], knowledgeChanges: [], chapterSummary: 'x' } },
  { name: 'state-no-evidence', value: { appeared: [], newEntities: [], threads: [], mysteries: [], timeline: [], relationships: [], power: [], characterStates: [{ entityKey: 'a', location: 'x' }], knowledgeChanges: [], chapterSummary: 'x' } },
  { name: 'knowledge-no-how', value: { appeared: [], newEntities: [], threads: [], mysteries: [], timeline: [], relationships: [], power: [], characterStates: [], knowledgeChanges: [{ entityKey: 'a', factKey: 'b' }], chapterSummary: 'x' } },
  { name: 'milestone-no-flag', value: { milestones: [{ milestoneKey: 'm' }], appeared: [], newEntities: [], threads: [], mysteries: [], timeline: [], relationships: [], power: [], characterStates: [], knowledgeChanges: [], chapterSummary: 'x' } },
  { name: 'milestone-string-flag', value: { milestones: [{ milestoneKey: 'm', reached: 'yes' }], appeared: [], newEntities: [], threads: [], mysteries: [], timeline: [], relationships: [], power: [], characterStates: [], knowledgeChanges: [], chapterSummary: 'x' } },
  { name: 'timeline-no-event', value: { appeared: [], newEntities: [], threads: [], mysteries: [], timeline: [{ whenText: 'dusk' }], relationships: [], power: [], characterStates: [], knowledgeChanges: [], chapterSummary: 'x' } },
  { name: 'power-no-stage', value: { appeared: [], newEntities: [], threads: [], mysteries: [], timeline: [], relationships: [], power: [{ character: 'a' }], characterStates: [], knowledgeChanges: [], chapterSummary: 'x' } },
  { name: 'extra', value: { appeared: [], newEntities: [], threads: [], mysteries: [], timeline: [], relationships: [], power: [], characterStates: [], knowledgeChanges: [], chapterSummary: 'x', notes: 'y' } },
  { name: 'array', value: [] },
]);

const biblePageOp = { op: 'bible_document.upsert', section: 'world', slug: 'harbour', body: 'The harbour is now flooded.' };
const entityOp = { op: 'entity.upsert', entityKey: 'mara', type: 'character', notes: 'the keeper' };
const update = { finding: 'The harbour flooded.', evidence: [{ ref: 'chapter:12', quote: 'the water rose' }], changeSet: [biblePageOp] };
addSamples('canonRefresh', refresh.chapterCanonRefreshPrompt, refreshSchema.ChapterCanonRefreshSchema, [
  { name: 'none', value: { updates: [] } },
  { name: 'one', value: { updates: [update] } },
  { name: 'two-ops', value: { updates: [{ ...update, changeSet: [biblePageOp, entityOp] }] } },
  { name: 'missing-updates', value: {} },
  { name: 'empty-finding', value: { updates: [{ ...update, finding: '' }] } },
  { name: 'no-evidence', value: { updates: [{ ...update, evidence: [] }] } },
  { name: 'empty-quote', value: { updates: [{ ...update, evidence: [{ ref: 'chapter:12', quote: '' }] }] } },
  { name: 'empty-ref', value: { updates: [{ ...update, evidence: [{ ref: '', quote: 'x' }] }] } },
  { name: 'no-changes', value: { updates: [{ ...update, changeSet: [] }] } },
  { name: 'change-not-object', value: { updates: [{ ...update, changeSet: ['x'] }] } },
  { name: 'disallowed-op', value: { updates: [{ ...update, changeSet: [{ op: 'fact.upsert', factKey: 'x' }] }] } },
  { name: 'unknown-op', value: { updates: [{ ...update, changeSet: [{ op: 'planet.explode' }] }] } },
  { name: 'missing-field', value: { updates: [{ ...update, changeSet: [{ op: 'bible_document.upsert', section: 'world' }] }] } },
  { name: 'second-update-bad', value: { updates: [update, { ...update, changeSet: [{ op: 'entity.upsert', entityKey: 'x' }] }] } },
  { name: 'ref-form-section', value: { updates: [{ ...update, changeSet: [{ op: 'bible_document.upsert', section: 'doc:world/harbour', slug: 'harbour', body: 'x' }] }] } },
  { name: 'extra', value: { updates: [], note: 'x' } },
]);

const finding = { severity: 'blocking', text: 'The ending contradicts the brief.', evidence: 'Mara walked away.' };
const slip = { kind: 'grammar', quote: 'she go to the pier', fix: 'she went to the pier', reason: 'tense' };
addSamples('review', review.reviewPrompt, reviewSchema.ReviewSchema, [
  { name: 'approve', value: { disposition: 'approve' } },
  { name: 'revision', value: { disposition: 'revision_requested', note: 'Tighten the ending.', findings: [finding], proofreading: [slip] } },
  { name: 'suggestion', value: { disposition: 'approve', findings: [{ severity: 'suggestion', text: 'Consider a longer opening.' }] } },
  ...['grammar', 'spelling', 'punctuation', 'tense', 'pov', 'name', 'reference'].map(kind => ({ name: `kind-${kind}`, value: { disposition: 'approve', proofreading: [{ kind, quote: 'a', fix: 'b' }] } })),
  { name: 'empty-lists', value: { disposition: 'approve', findings: [], proofreading: [] } },
  { name: 'unknown-disposition', value: { disposition: 'reject' } },
  { name: 'missing-disposition', value: { findings: [] } },
  { name: 'unknown-severity', value: { disposition: 'approve', findings: [{ severity: 'warning', text: 'x' }] } },
  { name: 'empty-finding-text', value: { disposition: 'approve', findings: [{ severity: 'suggestion', text: '' }] } },
  { name: 'unknown-kind', value: { disposition: 'approve', proofreading: [{ kind: 'style', quote: 'a', fix: 'b' }] } },
  { name: 'empty-quote', value: { disposition: 'approve', proofreading: [{ kind: 'grammar', quote: '', fix: 'b' }] } },
  { name: 'empty-fix', value: { disposition: 'approve', proofreading: [{ kind: 'grammar', quote: 'a', fix: '' }] } },
  { name: 'twenty-one-slips', value: { disposition: 'approve', proofreading: Array.from({ length: 21 }, () => ({ kind: 'spelling', quote: 'a', fix: 'b' })) } },
  { name: 'finding-extra', value: { disposition: 'approve', findings: [{ severity: 'suggestion', text: 'x', line: 3 }] } },
  { name: 'extra', value: { disposition: 'approve', score: 9 } },
  { name: 'null', value: null },
]);

const state = { openConflict: 'storm closing', characterPositions: [{ entityKey: 'mara', location: 'the lamp room' }], lastBeat: 'Mara lit the lamp', emotionalState: 'tense', establishedFacts: ['Kai: Level 3'] };
addSamples('chapterSummarize', summarize.chapterSummarizePrompt, summarizeSchema.ChapterSummarizeSchema, [
  { name: 'full', value: { summary: 'Mara lit the lamp.', state } },
  { name: 'empty-state', value: { summary: 'Mara lit the lamp.', state: {} } },
  { name: 'missing-state', value: { summary: 'Mara lit the lamp.' } },
  { name: 'missing-summary', value: { state } },
  { name: 'empty-summary', value: { summary: '', state } },
  { name: 'state-extra', value: { summary: 'x', state: { ...state, mood: 'x' } } },
  { name: 'location-60', value: { summary: 'x', state: { characterPositions: [{ entityKey: 'mara', location: long(60) }] } } },
  { name: 'location-61', value: { summary: 'x', state: { characterPositions: [{ entityKey: 'mara', location: long(61) }] } } },
  { name: 'position-key-empty', value: { summary: 'x', state: { characterPositions: [{ entityKey: '', location: 'x' }] } } },
  { name: 'position-missing-location', value: { summary: 'x', state: { characterPositions: [{ entityKey: 'mara' }] } } },
  { name: 'facts-not-strings', value: { summary: 'x', state: { establishedFacts: [1] } } },
  { name: 'extra', value: { summary: 'x', state, title: 'y' } },
  { name: 'array', value: [] },
]);

const constants = {
  plan: { version: plan.chapterPlanPrompt.version, system: plan.chapterPlanPrompt.system, none: planConstants.none, ending: planConstants.ending, notEnding: planConstants.notEnding },
  continuity: { version: continuity.continuityPrompt.version, system: continuity.continuityPrompt.system, isolatedNote: isolation.ISOLATED_EXTRACTION_NOTE },
  canonRefresh: { version: refresh.chapterCanonRefreshPrompt.version, system: refresh.chapterCanonRefreshPrompt.system, ops: refresh.CANON_REFRESH_OPS, stableVars: refresh.chapterCanonRefreshPrompt.cacheStrategy.stableVars },
  review: { version: review.reviewPrompt.version, system: review.reviewPrompt.system },
  summarize: { version: summarize.chapterSummarizePrompt.version, system: summarize.chapterSummarizePrompt.system },
  minCacheableTokens: caching.MIN_CACHEABLE_TOKENS,
};
const noCacheStrategy = [plan, continuity, review, summarize].map(module => Object.values(module).filter((value: any) => value?.key).every((prompt: any) => prompt.cacheStrategy === undefined));
if (!noCacheStrategy.every(Boolean)) throw new Error('a pipeline prompt gained a cacheStrategy; map its breakpoints');

const output = { constants, plan: planCases, continuity: continuityCases, roster: rosterCases, milestonePack: packCases, canonRefresh: refreshCases, editorialBrief: briefCases, review: reviewCases, summarize: summarizeCases, schemas: sampleSets };

writeFileSync(join(outDir, 'prompts-pipelines.json'), `${JSON.stringify(output)}\n`);
console.log(`plan ${planCases.length}, continuity ${continuityCases.length}, refresh ${refreshCases.length}, review ${reviewCases.length}, summarize ${summarizeCases.length}, samples ${Object.values(sampleSets).reduce((sum: number, set: any) => sum + set.samples.length, 0)}`);
