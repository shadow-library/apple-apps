import { plugin } from 'bun';
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// Run as: PLATFORM_REPO=<checkout> bun --tsconfig-override "$PLATFORM_REPO/apps/novel-forge-server/tsconfig.json" generate.ts (the reference schemas use legacy decorators)
// The snapshots pin UNCOMMITTED reference edits (user decision: port the working copy): prompts/fix.prompt.ts (1.7.1), judge.prompt.ts (2.7.1, judgeMessages), revision.prompt.ts (1.9.1), prompts/types.ts, prompt-caching.ts and the judge evaluation in graphs/chapter-generation.graph.ts, which is sliced from the graph source; regenerate if they change.
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
  name: 'prompts-chapters-fixture-stubs',
  setup(build) {
    build.module('@server/classes', () => ({ exports: { AppErrorCode: classes.AppErrorCode }, loader: 'object' }));
    build.module('@server/common', () => ({ exports: commonExports, loader: 'object' }));
    build.module('@server/database', () => ({ exports: { schema }, loader: 'object' }));
    build.module('@server/database/schemas', () => ({ exports: { bibleSection: { enumValues: [] } }, loader: 'object' }));
    build.module('@shadow-library/sdk', () => ({ exports: sdk, loader: 'object' }));
  },
});

const ai = join(server, 'modules/ai');
const generation = await import(join(ai, 'prompts/generation.prompt.ts'));
const expand = await import(join(ai, 'prompts/chapter-expand.prompt.ts'));
const title = await import(join(ai, 'prompts/title.prompt.ts'));
const fix = await import(join(ai, 'prompts/fix.prompt.ts'));
const revision = await import(join(ai, 'prompts/revision.prompt.ts'));
const judge = await import(join(ai, 'prompts/judge.prompt.ts'));
const caching = await import(join(ai, 'prompt-caching.ts'));
const tokenBudget = await import(join(ai, 'context/token-budget.ts'));
const validate = await import(join(ai, 'schemas/validate.ts'));
const generationSchema = await import(join(ai, 'schemas/generation.schema.ts'));
const expandSchema = await import(join(ai, 'schemas/chapter-expand.schema.ts'));
const titleSchema = await import(join(ai, 'schemas/title.schema.ts'));
const fixSchema = await import(join(ai, 'schemas/fix.schema.ts'));
const judgeSchema = await import(join(ai, 'schemas/judge.schema.ts'));
const endingSchema = await import(join(ai, 'schemas/ending-contract.schema.ts'));

const ROLES: Record<string, string> = { system: 'system', human: 'user', ai: 'assistant' };

const textOf = (content: unknown): string => {
  if (typeof content === 'string') return content;
  if (Array.isArray(content) && content.length === 1 && typeof content[0]?.text === 'string') return content[0].text;
  throw new Error(`unexpected message content ${JSON.stringify(content)}`);
};
const toMessages = (messages: any[]) => messages.map(message => ({ role: ROLES[message.getType()], text: textOf(message.content), cached: Array.isArray(message.content) }));

const filler = (label: string, tokens: number): string => `${label}\n${'The lamp room kept its slow count of ships. '.repeat(Math.ceil(tokens / 9))}`;

const STABLE = `## WRITING STYLE\nPlain English, short paragraphs.\n\n## CANON\nMara keeps the lighthouse; Kai is her apprentice (Level 3, Strength 14).\n${filler('## WORLD', 1500)}`;
const VOLATILE = '## CONTINUATION STATE\nopenConflict: the storm is closing on the harbour\nlastBeat: Mara lit the lamp\n\n## RECENT SUMMARIES\nChapter 4: Kai found the sealed letter.';
const CONTRACT = 'Hook type: cliffhanger\nEmotional beat: dread\nOpen question: who sent the letter?\nHandoff state: Mara on the north pier\nMust NOT resolve: thread:letter_sender';
const BRIEF = 'Objective: Mara and Kai cross the harbour.\nEvents: the ferry stalls; Kai opens the letter.';
const SHORT_STABLE = '## CANON\nShort.';

const targets = [
  { name: 'default', min: 1800, aim: 2200, max: 2600 },
  { name: 'custom', min: 900, aim: 1000, max: 1100 },
  { name: 'large', min: 12000, aim: 15000, max: 18000 },
  { name: 'million', min: 1000000, aim: 1500000, max: 2000000 },
  { name: 'fractional', min: 1234.5678, aim: 1500.25, max: 1999.9999 },
  { name: 'small', min: 0, aim: 7, max: 999 },
];
const words = (count: number): string => count.toLocaleString('en-US');

const generationCases: any[] = [];
const generationInputs = [
  { name: 'first-chapter', stableContext: STABLE, volatileContext: '## CONTINUATION STATE\n(none — this is chapter 1)', chapterBrief: `[STARTS FROM PREVIOUS CHAPTER]\n${BRIEF}`, endingContract: '', guidance: '' },
  { name: 'mid-volume', stableContext: STABLE, volatileContext: VOLATILE, chapterBrief: `[CONTINUES INTO NEXT CHAPTER]\n${BRIEF}`, endingContract: CONTRACT, guidance: 'Keep Kai quiet in the ferry scene.' },
  { name: 'final-chapter', stableContext: STABLE, volatileContext: VOLATILE, chapterBrief: `${BRIEF}\nThis is the planned ending chapter.`, endingContract: 'Hook type: earned_rest\nEmotional beat: calm\nOpen question: none\nHandoff state: the lamp lit', guidance: '' },
  { name: 'unicode', stableContext: SHORT_STABLE, volatileContext: 'Café ☕ — “quoted” 😀 {braces} {wordTargetMin}', chapterBrief: 'Brief with {chapterBrief} and \\n and $& and {{double}}', endingContract: '', guidance: '{guidance}' },
];
for (const input of generationInputs)
  for (const target of targets) {
    const vars = { ...input, ...generation.generationWordTargetVars(target) };
    const messages = await generation.generationPrompt.template.formatMessages(vars);
    const marked = caching.applyAnthropicCacheControl(messages, { skipHumans: 0, stableMessages: 1 });
    generationCases.push({ name: `${input.name}-${target.name}`, input, target, vars: generation.generationWordTargetVars(target), messages: toMessages(messages), breakpoints: toMessages(marked).flatMap((m, i) => (m.cached ? [i] : [])) });
  }

const wordCases = [0, 1, 7, 999, 1000, 1234, 12345, 1234567, 1234.5678, 1500.25, 0.0004, 0.0005, 123456789012345.67, -1234.5, 2200].map(value => ({ value, text: words(value) }));

const expandCases = [
  { name: 'short', draftWords: 1200, minWords: 1800, aimWords: 2200, missingWords: 1000, stableContext: STABLE, draftBody: 'Mara climbed the stair.\n\nThe lamp was cold.' },
  { name: 'second-pass', draftWords: 1650, minWords: 1800, aimWords: 2200, missingWords: 550, stableContext: STABLE, draftBody: 'The ferry stalled mid-channel. “Hold on,” said Kai.' },
  { name: 'fractional', draftWords: 1234.5, minWords: 1800.5, aimWords: 2200.25, missingWords: 965.75, stableContext: SHORT_STABLE, draftBody: 'Café ☕ {draftBody} 😀' },
  { name: 'tiny-target', draftWords: 0, minWords: 0, aimWords: 1e21, missingWords: 1e-7, stableContext: STABLE, draftBody: '' },
];
const expandInputs = { volatileContext: VOLATILE, chapterBrief: `[CONTINUES INTO NEXT CHAPTER]\n${BRIEF}`, endingContract: CONTRACT, guidance: 'Keep it plain.' };
const expandOut: any[] = [];
for (const entry of expandCases) {
  const vars = { ...expandInputs, ...entry };
  const messages = await expand.chapterExpandPrompt.template.formatMessages(vars);
  const marked = caching.applyAnthropicCacheControl(messages, { skipHumans: 0, stableMessages: 1 });
  expandOut.push({ ...entry, volatileContext: vars.volatileContext, chapterBrief: vars.chapterBrief, endingContract: vars.endingContract, guidance: vars.guidance, messages: toMessages(messages), breakpoints: toMessages(marked).flatMap((m, i) => (m.cached ? [i] : [])) });
}

const titleCases = [
  { name: 'with-titles', existingTitles: '- Ch 1: The Lamp Room\n- Ch 2: Salt and Iron', chapterSummary: 'Mara and Kai crossed the harbour. Kai opened the letter.' },
  { name: 'none-yet', existingTitles: '(none yet)', chapterSummary: 'Mara arrived at the lighthouse.' },
  { name: 'unicode', existingTitles: '- Ch 1: Café ☕ {title}', chapterSummary: '“Quoted” 😀 {chapterSummary} and {{x}}' },
];
const titleOut: any[] = [];
for (const entry of titleCases) titleOut.push({ ...entry, messages: toMessages(await title.titlePrompt.template.formatMessages(entry)) });

const fixCases = [
  { name: 'patch', contextPack: STABLE, prose: 'Li Wei executed the Void Step, vanishing from sight.', findings: '[hard] Void Step is not unlocked until Chapter 15.' },
  { name: 'readability', contextPack: SHORT_STABLE, prose: 'His hope was a candle in a draughty hall.', findings: '[soft] readability: "His hope was a candle in a draughty hall." — metaphor for a feeling.' },
  { name: 'unicode', contextPack: 'Pack {contextPack} 😀', prose: 'Café ☕ {prose}', findings: '[hard] {findings}\n[soft] second' },
];
const fixOut: any[] = [];
for (const entry of fixCases) {
  const messages = await fix.fixPrompt.template.formatMessages(entry);
  const marked = caching.applyAnthropicCacheControl(messages, { skipHumans: 1, stableMessages: 1 });
  fixOut.push({ ...entry, messages: toMessages(messages), breakpoints: toMessages(marked).flatMap((m, i) => (m.cached ? [i] : [])) });
}

const revisionCases = [
  { name: 'blocking', contextPack: STABLE, chapterBrief: BRIEF, draftBody: 'Mara climbed the stair.', feedback: '[blocking] The ending is too neat.' },
  { name: 'short-pack', contextPack: SHORT_STABLE, chapterBrief: '[CONTINUES INTO NEXT CHAPTER]', draftBody: 'Café ☕ {draftBody}', feedback: 'Wrap up the chapter. 😀 {feedback}' },
];
const revisionOut: any[] = [];
for (const entry of revisionCases) {
  const messages = await revision.revisionPrompt.template.formatMessages(entry);
  const marked = caching.applyAnthropicCacheControl(messages, { skipHumans: 0, stableMessages: 1 });
  revisionOut.push({ ...entry, messages: toMessages(messages), breakpoints: toMessages(marked).flatMap((m, i) => (m.cached ? [i] : [])) });
}

const judgeCases = [
  { name: 'plain', contextPack: STABLE, evaluation: 'Draft prose to evaluate:\nMara climbed.\n\n## BRIEF\nPOV: Mara\n' + BRIEF },
  { name: 'contract-and-knowledge', contextPack: STABLE, evaluation: `Draft prose to evaluate:\nMara climbed.\n\n## ENDING CONTRACT\n${CONTRACT}\n\n## FORBIDDEN KNOWLEDGE\n- [steward_poisoned_well] The steward poisoned the well.` },
  { name: 'short-pack', contextPack: SHORT_STABLE, evaluation: 'Café ☕ {evaluation} 😀' },
  { name: 'empty', contextPack: '', evaluation: '' },
];
const judgeOut = judgeCases.map(entry => ({ ...entry, messages: toMessages(judge.judgeMessages(entry.contextPack, entry.evaluation)) }));
const graphSource = readFileSync(join(ai, 'graphs/chapter-generation.graph.ts'), 'utf8');
const sliceStart = graphSource.indexOf('const renderedContract =');
const sliceEnd = graphSource.indexOf('const opening =', sliceStart);
if (sliceStart === -1 || sliceEnd === -1) throw new Error('the judge evaluation moved in chapter-generation.graph.ts');
const evaluationSource = graphSource.slice(sliceStart, sliceEnd);
for (const marker of ['renderEndingContract(', 'parseKnowledgeContract(', 'loadKnowledgeView(', 'renderForbiddenFacts(', 'renderJudgeReaderKnows(', 'const evaluation =']) {
  if (!evaluationSource.includes(marker)) throw new Error(`the judge evaluation no longer holds ${marker}`);
}
const knowledgeView = await import(join(server, 'modules/bible/fact/knowledge-view.ts'));
const transpiler = new Bun.Transpiler({ loader: 'ts' });
const composeEvaluation = (deps: Record<string, unknown>) => {
  const js = transpiler.transformSync(`async function evaluate(brief, state, db, projectId) {\n${evaluationSource}\nreturn evaluation;\n}`);
  return new Function(...Object.keys(deps), `${js}\nreturn evaluate;`)(...Object.values(deps)) as (brief: unknown, state: unknown, db: unknown, projectId: bigint) => Promise<string>;
};

const fact = (factKey: string, text: string, source: string) => ({ factKey, text, source });
const pack = { pov: ['mara'], learns: [] };
const evaluationCases = [
  { name: 'no-brief', brief: null, prose: 'Mara climbed.', readabilityEvidence: '', hidden: [], readerKnows: [] },
  { name: 'bare', brief: { pov: '', body: BRIEF, endingContract: null, knowledgeContract: null }, prose: 'Mara climbed.', readabilityEvidence: '', hidden: [], readerKnows: [] },
  {
    name: 'everything',
    brief: {
      pov: 'Mara',
      body: BRIEF,
      endingContract: { hookType: 'cliffhanger', emotionalBeat: 'dread', openQuestion: 'who sent the letter?', handoffState: 'Mara on the north pier', mustNotResolve: ['thread:letter_sender'] },
      knowledgeContract: pack,
    },
    prose: 'Mara climbed.',
    readabilityEvidence: '## READABILITY EVIDENCE\naverage sentence 27.4 words',
    hidden: [fact('steward_poisoned_well', 'The steward poisoned the well.', 'manual'), fact('seeded', 'A seeded fact.', 'seed'), fact('heir_alive', 'The heir lives.', 'brief')],
    readerKnows: [fact('lamp_cursed', 'The lamp is cursed.', 'manual'), fact('ferry_sabotaged', 'The ferry was sabotaged.', 'generated')],
  },
  { name: 'only-seeded-hidden', brief: { pov: 'Mara', body: BRIEF, endingContract: null, knowledgeContract: pack }, prose: 'Mara climbed.', readabilityEvidence: '', hidden: [fact('seeded', 'A seeded fact.', 'seed')], readerKnows: [] },
  { name: 'no-pov-entities', brief: { pov: 'Mara', body: BRIEF, endingContract: null, knowledgeContract: { pov: [], learns: [] } }, prose: 'Mara climbed.', readabilityEvidence: '', hidden: [fact('x', 'unreachable', 'manual')], readerKnows: [fact('y', 'unreachable', 'manual')] },
  {
    name: 'unicode',
    brief: { pov: 'Café ☕', body: 'Brief {braces} $& 😀', endingContract: { hookType: 'turn', emotionalBeat: '“calm”', openQuestion: 'why?', handoffState: 'x', mustNotResolve: [] }, knowledgeContract: pack },
    prose: 'Prose {prose} \\n 😀',
    readabilityEvidence: 'Evidence é',
    hidden: [fact('é_key', 'Text with "quotes" and 😀', 'import')],
    readerKnows: [fact('k', 'multi\nline', 'manual')],
  },
];
const evaluations: any[] = [];
for (const entry of evaluationCases) {
  let viewUsed = false;
  const evaluate = composeEvaluation({
    renderEndingContract: endingSchema.renderEndingContract,
    parseKnowledgeContract: knowledgeView.parseKnowledgeContract,
    renderForbiddenFacts: knowledgeView.renderForbiddenFacts,
    renderJudgeReaderKnows: knowledgeView.renderJudgeReaderKnows,
    loadKnowledgeView: async () => {
      viewUsed = true;
      return { hidden: entry.hidden, readerKnows: entry.readerKnows };
    },
  });
  const text = await evaluate(entry.brief, { prose: entry.prose, readabilityEvidence: entry.readabilityEvidence }, {}, 1n);
  evaluations.push({ ...entry, viewUsed, text });
}

const fillerSentence = 'The lamp room kept its slow count of ships. ';
const contextReaching = (target: number): string => {
  const base = tokenBudget.countTokens(expand.chapterExpandPrompt.system);
  for (let sentences = 1; sentences < 2000; sentences++) {
    const context = fillerSentence.repeat(sentences);
    if (base + tokenBudget.countTokens(context) >= target) return context;
  }
  throw new Error(`no stable context reaches ${target} tokens`);
};
const thresholdCases: any[] = [];
for (const target of [600, 900, 1100, 1300]) {
  const vars = { ...expandInputs, ...expandCases[0], stableContext: contextReaching(target) };
  const messages = await expand.chapterExpandPrompt.template.formatMessages(vars);
  const marked = caching.applyAnthropicCacheControl(messages, { skipHumans: 0, stableMessages: 1 });
  thresholdCases.push({ target, ...expandCases[0], stableContext: vars.stableContext, volatileContext: vars.volatileContext, chapterBrief: vars.chapterBrief, endingContract: vars.endingContract, guidance: vars.guidance, messages: toMessages(messages), breakpoints: toMessages(marked).flatMap((m, i) => (m.cached ? [i] : [])) });
}

const long = (count: number): string => 'a'.repeat(count);
const sampleSets: Record<string, { schema: unknown; samples: { name: string; value: unknown }[] }> = {};
const addSamples = (key: string, Class: any, samples: { name: string; value: unknown }[]) => {
  sampleSets[key] = {
    schema: validate.toHostedPromptSchema(Class),
    constrained: validate.toConstrainedSchema(Class),
    samples: samples.map(sample => {
      const result = validate.parseSchema(Class, structuredClone(sample.value));
      return { ...sample, valid: result.success, issueCount: result.success ? 0 : result.issues.length };
    }),
  };
};

const state = { openConflict: 'storm closing', characterPositions: [{ entityKey: 'mara', location: 'the lamp room' }], lastBeat: 'Mara lit the lamp', emotionalState: 'tense', establishedFacts: ['Kai: Level 3'] };
const draft = { title: 'The Stalled Ferry', body: long(100), summary: 'Mara and Kai crossed the harbour.' };
addSamples('generation', generationSchema.GenerationSchema, [
  { name: 'minimal', value: draft },
  { name: 'with-state', value: { ...draft, state } },
  { name: 'empty-state', value: { ...draft, state: {} } },
  { name: 'body-boundary-100', value: { ...draft, body: long(100) } },
  { name: 'body-99', value: { ...draft, body: long(99) } },
  { name: 'body-100-code-points', value: { ...draft, body: '😀'.repeat(100) } },
  { name: 'body-99-code-points', value: { ...draft, body: '😀'.repeat(99) } },
  { name: 'title-200', value: { ...draft, title: long(200) } },
  { name: 'title-201', value: { ...draft, title: long(201) } },
  { name: 'title-empty', value: { ...draft, title: '' } },
  { name: 'summary-empty', value: { ...draft, summary: '' } },
  { name: 'missing-summary', value: { title: draft.title, body: draft.body } },
  { name: 'extra-property', value: { ...draft, extra: 1 } },
  { name: 'state-extra-property', value: { ...draft, state: { ...state, mood: 'x' } } },
  { name: 'position-location-60', value: { ...draft, state: { characterPositions: [{ entityKey: 'mara', location: long(60) }] } } },
  { name: 'position-location-61', value: { ...draft, state: { characterPositions: [{ entityKey: 'mara', location: long(61) }] } } },
  { name: 'position-key-empty', value: { ...draft, state: { characterPositions: [{ entityKey: '', location: 'x' }] } } },
  { name: 'position-missing-location', value: { ...draft, state: { characterPositions: [{ entityKey: 'mara' }] } } },
  { name: 'facts-not-strings', value: { ...draft, state: { establishedFacts: [1] } } },
  { name: 'body-number', value: { ...draft, body: 5 } },
  { name: 'array', value: [draft] },
  { name: 'null', value: null },
]);
addSamples('chapterExpand', expandSchema.ChapterExpandSchema, [
  { name: 'valid', value: { body: long(100) } },
  { name: 'short', value: { body: long(99) } },
  { name: 'missing', value: {} },
  { name: 'extra', value: { body: long(100), title: 'x' } },
  { name: 'not-object', value: 'text' },
]);
addSamples('title', titleSchema.TitleSchema, [
  { name: 'valid', value: { title: 'Salt and Iron' } },
  { name: 'alternatives', value: { title: 'Salt and Iron', alternatives: ['A', 'B'] } },
  { name: 'empty-title', value: { title: '' } },
  { name: 'title-200', value: { title: long(200) } },
  { name: 'title-201', value: { title: long(201) } },
  { name: 'alternatives-not-strings', value: { title: 'x', alternatives: [1] } },
  { name: 'missing', value: {} },
  { name: 'extra', value: { title: 'x', subtitle: 'y' } },
]);
addSamples('fix', fixSchema.FixSchema, [
  { name: 'patch', value: { action: 'patch', patches: [{ find: 'a', replace: 'b' }] } },
  { name: 'patch-empty-replace', value: { action: 'patch', patches: [{ find: 'a', replace: '' }] } },
  { name: 'patch-without-patches', value: { action: 'patch' } },
  { name: 'patch-empty-patches', value: { action: 'patch', patches: [] } },
  { name: 'patch-with-body', value: { action: 'patch', patches: [{ find: 'a', replace: 'b' }], body: 'x' } },
  { name: 'patch-empty-find', value: { action: 'patch', patches: [{ find: '', replace: 'b' }] } },
  { name: 'rewrite', value: { action: 'rewrite', body: 'The whole chapter.' } },
  { name: 'rewrite-without-body', value: { action: 'rewrite' } },
  { name: 'rewrite-empty-body', value: { action: 'rewrite', body: '' } },
  { name: 'rewrite-with-patches', value: { action: 'rewrite', body: 'x', patches: [{ find: 'a', replace: 'b' }] } },
  { name: 'rewrite-with-patches-only', value: { action: 'rewrite', patches: [{ find: 'a', replace: 'b' }] } },
  { name: 'unknown-action', value: { action: 'delete', body: 'x' } },
  { name: 'missing-action', value: { body: 'x' } },
  { name: 'extra-property', value: { action: 'rewrite', body: 'x', note: 'y' } },
  { name: 'patch-extra-property', value: { action: 'patch', patches: [{ find: 'a', replace: 'b', all: true }] } },
]);
const finding = { severity: 'hard', text: 'Contradicts chapter 3.' };
const compliance = { compliant: true, issues: [] };
addSamples('judge', judgeSchema.JudgeSchema, [
  { name: 'consistent', value: { verdict: 'consistent', findings: [] } },
  { name: 'consistent-soft', value: { verdict: 'consistent', findings: [{ severity: 'soft', text: 'wrinkle' }] } },
  { name: 'contradiction-hard', value: { verdict: 'contradiction', findings: [finding] } },
  { name: 'contradiction-soft-and-hard', value: { verdict: 'contradiction', findings: [{ severity: 'soft', text: 'a' }, finding] } },
  { name: 'contradiction-soft-only', value: { verdict: 'contradiction', findings: [{ severity: 'soft', text: 'a' }] } },
  { name: 'contradiction-empty', value: { verdict: 'contradiction', findings: [] } },
  { name: 'evaluation-failed', value: { verdict: 'evaluation_failed', findings: [] } },
  { name: 'unknown-verdict', value: { verdict: 'maybe', findings: [] } },
  { name: 'all-compliance', value: { verdict: 'consistent', findings: [], endingCompliance: compliance, knowledgeCompliance: compliance, briefCompliance: compliance, readabilityCompliance: compliance } },
  { name: 'compliance-with-issues', value: { verdict: 'consistent', findings: [], briefCompliance: { compliant: false, issues: ['the bribe is never dramatized'] } } },
  { name: 'compliance-missing-issues', value: { verdict: 'consistent', findings: [], briefCompliance: { compliant: true } } },
  { name: 'compliance-missing-compliant', value: { verdict: 'consistent', findings: [], endingCompliance: { issues: [] } } },
  { name: 'compliance-string-flag', value: { verdict: 'consistent', findings: [], knowledgeCompliance: { compliant: 'yes', issues: [] } } },
  { name: 'compliance-extra', value: { verdict: 'consistent', findings: [], readabilityCompliance: { compliant: true, issues: [], score: 1 } } },
  { name: 'compliance-issues-not-strings', value: { verdict: 'consistent', findings: [], readabilityCompliance: { compliant: false, issues: [1] } } },
  { name: 'finding-unknown-severity', value: { verdict: 'consistent', findings: [{ severity: 'fatal', text: 'x' }] } },
  { name: 'finding-missing-text', value: { verdict: 'consistent', findings: [{ severity: 'soft' }] } },
  { name: 'finding-empty-text', value: { verdict: 'consistent', findings: [{ severity: 'soft', text: '' }] } },
  { name: 'finding-extra', value: { verdict: 'consistent', findings: [{ severity: 'soft', text: 'x', line: 3 }] } },
  { name: 'missing-findings', value: { verdict: 'consistent' } },
  { name: 'missing-verdict', value: { findings: [] } },
  { name: 'extra-property', value: { verdict: 'consistent', findings: [], notes: 'x' } },
  { name: 'array', value: [] },
]);
const contract = { hookType: 'cliffhanger', emotionalBeat: 'dread', openQuestion: 'who sent it?', handoffState: 'Mara on the pier' };
addSamples('endingContract', endingSchema.EndingContractSchema, [
  { name: 'valid', value: contract },
  { name: 'must-not-resolve', value: { ...contract, mustNotResolve: ['thread:heir_mystery'] } },
  ...['cliffhanger', 'revelation', 'quiet_dread', 'promise', 'turn', 'closure_with_momentum', 'earned_rest'].map(hookType => ({ name: `hook-${hookType}`, value: { ...contract, hookType } })),
  { name: 'unknown-hook', value: { ...contract, hookType: 'twist' } },
  { name: 'empty-beat', value: { ...contract, emotionalBeat: '' } },
  { name: 'empty-question', value: { ...contract, openQuestion: '' } },
  { name: 'empty-handoff', value: { ...contract, handoffState: '' } },
  { name: 'missing-handoff', value: { hookType: 'turn', emotionalBeat: 'x', openQuestion: 'y' } },
  { name: 'must-not-resolve-not-strings', value: { ...contract, mustNotResolve: [1] } },
  { name: 'extra', value: { ...contract, note: 'x' } },
]);

const noteMap = (entries: [string, string | null][]) => new Map(entries);
const renderCases = [
  { name: 'bare', contract },
  { name: 'must-not-resolve', contract: { ...contract, mustNotResolve: ['thread:heir_mystery', 'fact:poisoned_well'] } },
  { name: 'empty-list', contract: { ...contract, mustNotResolve: [] } },
  { name: 'unicode', contract: { hookType: 'turn', emotionalBeat: 'Café ☕', openQuestion: '“why”', handoffState: '😀', mustNotResolve: ['x'] } },
  {
    name: 'writer-notes',
    contract: { ...contract, mustNotResolve: ['fact:poisoned_well', 'poisoned_well', 'fact: padded ', 'thread:heir_mystery', 'unknown_fact', 'hidden_heir', 'fact:noted'] },
    notes: [['poisoned_well', 'keep the well question open'], ['padded', null], ['hidden_heir', '  '], ['noted', 'keep the well question open'], ['unused', 'unused note']] as [string, string | null][],
  },
  { name: 'writer-notes-empty', contract: { ...contract, mustNotResolve: ['fact:a', 'b'] }, notes: [] as [string, string | null][] },
].map(entry => ({
  name: entry.name,
  contract: entry.contract,
  notes: entry.notes ?? null,
  text: endingSchema.renderEndingContract(entry.contract, entry.notes ? noteMap(entry.notes) : undefined),
}));

const output = {
  constants: {
    generation: { version: generation.generationPrompt.version, system: generation.generationPrompt.system },
    chapterExpand: { version: expand.chapterExpandPrompt.version, system: expand.chapterExpandPrompt.system },
    title: { version: title.titlePrompt.version, system: title.titlePrompt.system },
    fix: { version: fix.fixPrompt.version, system: fix.fixPrompt.system, fewShots: toMessages(fix.fixPrompt.fewShots) },
    revision: { version: revision.revisionPrompt.version, system: revision.revisionPrompt.system },
    judge: { version: judge.judgePrompt.version, system: judge.judgePrompt.system, fewShots: toMessages(judge.judgePrompt.fewShots) },
    hiddenThreadPlaceholder: endingSchema.HIDDEN_THREAD_PLACEHOLDER,
    minCacheableTokens: caching.MIN_CACHEABLE_TOKENS,
  },
  wordCases,
  generation: generationCases,
  chapterExpand: expandOut,
  title: titleOut,
  fix: fixOut,
  revision: revisionOut,
  judge: judgeOut,
  thresholdCases,
  evaluations,
  renderEndingContract: renderCases,
  schemas: sampleSets,
};

writeFileSync(join(outDir, 'prompts-chapters.json'), `${JSON.stringify(output)}\n`);
console.log(
  `generation ${generationCases.length}, expand ${expandOut.length}, title ${titleOut.length}, fix ${fixOut.length}, revision ${revisionOut.length}, judge ${judgeOut.length}, samples ${Object.values(sampleSets).reduce((sum, set) => sum + set.samples.length, 0)}`,
);
