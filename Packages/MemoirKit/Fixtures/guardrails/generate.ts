import { mock } from 'bun:test';
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');
const outDir = dirname(fileURLToPath(import.meta.url));
const src = join(platformRepo, 'apps/memoir-server/src');

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };

class CodedError extends Error {
  constructor(readonly code: string) {
    super(code);
  }
}
const codes = new Proxy({} as Record<string, unknown>, { get: (_, code) => ({ create: () => new CodedError(String(code)) }) });
mock.module('@server/classes', () => ({ AppErrorCode: codes }));
mock.module('@modules/inference', () => ({}));
mock.module('@server/database', () => ({}));

const guardrails = await import(join(src, 'modules/ai-worker/guardrails.ts'));
const contract = await import(join(src, 'modules/ai-worker/prompt-contract.ts'));
const { ALLOWED_SUGGESTION_KINDS, CRISIS_RESPONSE_ANSWER, applyGuardrails, findVerbatimQuote } = guardrails;
const { buildPrompt, parseDraft } = contract;

const lcg = (seed: number) => {
  let state = seed >>> 0;
  return () => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state / 0x1_0000_0000;
  };
};
const pick = <T>(next: () => number, values: readonly T[]): T => values[Math.floor(next() * values.length)] ?? (values[0] as T);
const integer = (next: () => number, upper: number): number => Math.floor(next() * (upper + 1));
const chance = (next: () => number, p: number): boolean => next() < p;

const clean = (value: unknown): Json => JSON.parse(JSON.stringify(value)) as Json;

const parsed = (text: string): { draft: Json } | { error: string } => {
  try {
    return { draft: clean(parseDraft(JSON.parse(text))) };
  } catch (error) {
    if (error instanceof CodedError) return { error: error.code };
    throw error;
  }
};

// tests/ai/guardrails.spec.ts: every literal input, each output from the reference.

const JOURNAL_ENTRY = 'I skipped the evening run again because my manager kept me on a call until nearly nine and I felt completely wrung out afterwards';
const REASON_NOTE = 'too tired after the late standup meeting';
const CLEAN_DRAFT = {
  answer: 'Evening quests are missed about three times as often as morning ones, and almost always on days with a late work log.',
  patterns: ['Missed evening quests cluster on days with an expense logged after 20:00.'],
  suggestions: [{ kind: 'shift_time', questId: '11', text: 'Try moving the evening run 45 minutes earlier.' }],
  limitationNote: null,
};

interface GuardrailInput {
  queryText: string;
  sensitiveSources: string[];
  allowedQuestIds: string[];
  draft: Record<string, unknown>;
}

const input = (overrides: Partial<GuardrailInput> = {}): GuardrailInput => ({
  queryText: 'why do I keep failing evening quests?',
  sensitiveSources: [JOURNAL_ENTRY, REASON_NOTE],
  allowedQuestIds: ['11', '12'],
  draft: CLEAN_DRAFT,
  ...overrides,
});
const withAnswer = (answer: string): GuardrailInput => input({ draft: { ...CLEAN_DRAFT, answer } });

const specInputs: [string, GuardrailInput][] = [
  ['clean output', input()],
  ...ALLOWED_SUGGESTION_KINDS.map((kind: string): [string, GuardrailInput] => [
    `allowed kind ${kind}`,
    input({ draft: { ...CLEAN_DRAFT, suggestions: [{ kind, questId: '11', text: 'A neutral tweak worth trying.' }] } }),
  ]),
  ...[
    ['a long journal sentence reproduced whole', JOURNAL_ENTRY],
    ['a seven-word run lifted out of the middle of a journal entry', 'because my manager kept me on a call'],
    ['a short reason note reproduced whole', REASON_NOTE],
    ['a quote wrapped in quotation marks and punctuation', `You wrote: "${REASON_NOTE}."`],
    ['a quote with the casing changed', REASON_NOTE.toUpperCase()],
  ].map(([name, quote]): [string, GuardrailInput] => [`quote: ${name}`, withAnswer(`Your evenings look heavy. ${quote}`)]),
  ['quote in a suggestion', input({ draft: { ...CLEAN_DRAFT, suggestions: [{ kind: 'shift_time', questId: '11', text: `Because ${REASON_NOTE}, move it earlier.` }] } })],
  ['genuine paraphrase', withAnswer('On the days you missed the run, your own notes point at work running late and leaving you drained.')],
  ...[
    ['a bare identity assertion', 'You are lazy about evenings.'],
    ['a contracted identity assertion', "You're a procrastinator when it comes to the gym."],
    ['a hedged identity assertion', 'You are probably just unmotivated in the evenings.'],
    ['a clinical label', 'You have depression, which explains the missed days.'],
    ['a diagnosis framing', 'This pattern is diagnosable as burnout.'],
    ['a type-of-person framing', "You're the kind of person who starts things and drops them."],
  ].map(([name, answer]): [string, GuardrailInput] => [`identity: ${name}`, withAnswer(answer as string)]),
  ['behavioural statement', withAnswer('You completed 4 of 12 evening quests last month, and 11 of 12 morning ones.')],
  ...['You failed again this week.', 'You should be ashamed of that streak.', 'Four misses is disappointing.', 'Stop being lazy about it.'].map(
    (answer): [string, GuardrailInput] => [`shame: ${answer}`, withAnswer(answer)],
  ),
  ['mechanic mutation in the answer', withAnswer("I've moved your evening run to 18:00 and awarded 20 XP for the streak.")],
  [
    'a suggestion kind outside the allowed set',
    input({
      draft: {
        ...CLEAN_DRAFT,
        suggestions: [
          { kind: 'shift_time', questId: '11', text: 'Move it earlier.' },
          { kind: 'grant_xp', questId: '11', text: 'Give yourself 100 XP.' },
        ],
      },
    }),
  ],
  ['a suggestion for a quest the account does not own', input({ draft: { ...CLEAN_DRAFT, suggestions: [{ kind: 'shift_time', questId: '999', text: 'Move it earlier.' }] } })],
  ['crisis in the question', input({ queryText: 'why do I keep thinking I want to die when I miss my quests' })],
  ['crisis in the data', input({ sensitiveSources: ['some days I think everyone would be better off dead without me around'] })],
  ['crisis in the output', withAnswer('Your notes mention self-harm on the days you miss quests.')],
  ['crisis with coaching asked for', input({ queryText: 'I keep thinking about killing myself, what should I change?' })],
  ['crisis carries no violation', input({ queryText: 'I want to die' })],
];

const guardrailCase = (id: string, guardrailInput: GuardrailInput) => {
  const normalized = clean(guardrailInput) as unknown as GuardrailInput;
  return { id, input: normalized, output: clean(applyGuardrails(normalized)) };
};

const spec = specInputs.map(([name, guardrailInput]) => guardrailCase(`spec: ${name}`, guardrailInput));
const specQuotes = [{ id: 'spec: an incidental short phrase', output: 'you were too tired', sources: ['too tired'] }];

// Seeded cases: drafts drawn from phrase pools that sit on, just inside and just outside every pattern, with the Unicode a JavaScript regex treats
// specially, each passed through parseDraft as the executor does.

const UNICODE = [
  'K', 'İ', 'ı', 'ſ', 'ß', 'Σ', 'ς', 'é', 'é', 'Ａ', 'ａ', '１', ' ', ' ', ' ', ' ', '﻿', '​', '‍', '😀', '👍🏽', '𝒜', '中', 'あ', '’', '“', '”', '—', '…', 'ͅ',
];
const NEUTRAL = [
  'Evening quests slip more often on weekdays.',
  'You completed 9 of 14 morning quests.',
  'Spending rises on days with a missed run.',
  'HP dipped twice after late nights.',
  'The data covers eleven days.',
  'Sleep logs are sparse.',
  'You moved the gym quest twice.',
  'Mood scores are higher after walks.',
  'you were too tired',
  'Try a shorter session.',
];
const IDENTITY = [
  'You are lazy about it.',
  "You're a procrastinator.",
  'You are probably just unmotivated.',
  'You seem so hopeless lately.',
  'You were such a failure that week.',
  'You have been a bit broken.',
  'You sound kind of anxious.',
  'You always seem undisciplined.',
  'You are an addict.',
  'You are a bad person.',
  'You are the burnout case here.',
  'You are lazyish about it.',
  'You are not lazy.',
  'Your lazy days',
  'You have depression.',
  'You suffer from chronic insomnia disorder.',
  'You struggle with severe adhd.',
  'You are dealing with mild clinical burnout.',
  'You have add.',
  'You have address issues.',
  'You are experiencing an eating disorder.',
  'This looks diagnosed.',
  'A diagnosis is not possible.',
  'This is clinical depression.',
  'This sounds like textbook avoidance.',
  "You're someone who quits.",
  'You are the type of person who plans.',
  'You are someone whom we admire.',
  'YOU ARE LAZY.',
  'you are lazy.',
  'You are  lazy.',
  'You aren’t lazy.',
  'You’re a procrastinator.',
  'You are laſy.',
  'You are weaK.',
];
const SHAME = [
  'You failed again.',
  'You failed yet again this month.',
  'You failed once.',
  'You should be ashamed.',
  "That's pathetic.",
  'This is pathetic.',
  'There is no excuse.',
  'No excuses needed.',
  'Stop being lazy.',
  'Stop being so soft.',
  'Stop being weak.',
  'Stop being slow.',
  'You always give up.',
  'You always let yourself down.',
  'That was disappointing.',
  'It was disappointingly short.',
  'That’s pathetic.',
];
const CRISIS = [
  'I want to kill myself.',
  'I keep killing myself over this.',
  'suicidal thoughts',
  'Suicide is on my mind.',
  'ending it all',
  'end my life',
  'take my own life',
  'I want to die.',
  'better off dead',
  'no reason to live',
  'no reason to go on',
  'self-harm',
  'self harm',
  'selfharm',
  'I hurt myself.',
  'cut my self',
  'harm myself',
  'killmyself',
  'kill myselfish',
  'want to diet',
  'suicidality',
];
const MUTATION = [
  "I've updated your quest.",
  'I have changed the reminder.',
  'I already rescheduled it.',
  'Iset it.',
  'I paused the quest.',
  'I completed it for you.',
  'I awarded the badge.',
  'I unlocked a title.',
  'I applied the change.',
  'I added 20 xp.',
  'We have removed coins.',
  'We added 5 hp.',
  'I removed crown.',
  'Your quest has been updated.',
  'Your coins have been awarded.',
  'Your streak has been reset.',
  'Your level has been changed.',
  'Your XP has been adjusted.',
  'I would update it.',
  'I suggest you update it.',
  'Once updated, check it.',
];
const SOURCE_WORDS = [
  'skipped', 'the', 'evening', 'run', 'because', 'my', 'manager', 'kept', 'me', 'late', 'and', 'felt', 'drained', 'after', 'standup', 'café', 'naïve', 'résumé',
  'İstanbul', 'straße', 'ΣΟΦΙΑ', 'don’t', "can't", 'e-mail', '12:30', '42', 'x2', 'Kelvin', 'ſtrong', '東京', 'привет', 'okay!', '(really)', '“quoted”',
];
const KINDS = [...ALLOWED_SUGGESTION_KINDS, 'grant_xp', 'Shift_Time', 'shift_time ', '', 'delete_quest'];

const sourceText = (next: () => number): string => {
  const length = 1 + integer(next, 14);
  const words = Array.from({ length }, () => pick(next, SOURCE_WORDS));
  if (chance(next, 0.2)) words.splice(integer(next, words.length), 0, pick(next, UNICODE));
  return words.join(pick(next, [' ', ' ', ' ', '  ', ', ', ' - ', '\n']));
};

const quoteOf = (next: () => number, source: string): string => {
  const words = source.split(/\s+/).filter(Boolean);
  const start = integer(next, Math.max(0, words.length - 1));
  const length = 1 + integer(next, 9);
  let quote = words.slice(start, start + length).join(pick(next, [' ', ' ', '  ', ' — ', '...', ' “', '\n']));
  if (chance(next, 0.3)) quote = quote.toUpperCase();
  if (chance(next, 0.2)) quote = `"${quote}."`;
  if (chance(next, 0.15)) quote = quote.replace(/e/g, 'é');
  return quote;
};

const sentence = (next: () => number, sources: string[]): string => {
  const roll = integer(next, 39);
  const pool = roll < 2 ? 'crisis' : roll < 8 ? 'identity' : roll < 13 ? 'shame' : roll < 18 ? 'mutation' : roll < 26 ? 'quote' : roll < 29 ? 'unicode' : 'neutral';
  switch (pool) {
    case 'identity':
      return pick(next, IDENTITY);
    case 'shame':
      return pick(next, SHAME);
    case 'crisis':
      return pick(next, CRISIS);
    case 'mutation':
      return pick(next, MUTATION);
    case 'quote':
      return sources.length > 0 ? quoteOf(next, pick(next, sources)) : pick(next, NEUTRAL);
    case 'unicode':
      return `${pick(next, NEUTRAL)}${pick(next, UNICODE)}${pick(next, NEUTRAL)}`;
    default:
      return pick(next, NEUTRAL);
  }
};

const text = (next: () => number, sources: string[]): string => Array.from({ length: 1 + integer(next, 2) }, () => sentence(next, sources)).join(' ');

const rawSuggestion = (next: () => number, sources: string[], quests: string[]): unknown => {
  const shape = integer(next, 19);
  if (shape === 0) return null;
  if (shape === 1) return [pick(next, KINDS)];
  if (shape === 2) return 'shift_time';
  const suggestion: Record<string, unknown> = {};
  if (!chance(next, 0.05)) suggestion.kind = chance(next, 0.05) ? 7 : pick(next, KINDS);
  const questShape = integer(next, 9);
  if (questShape <= 5) suggestion.questId = pick(next, [...quests, '999', '11 ', 'UPPER']);
  else if (questShape === 6) suggestion.questId = pick(next, [11, 12, 11.5, 1e21]);
  else if (questShape === 7) suggestion.questId = null;
  const textShape = integer(next, 9);
  if (textShape <= 6) suggestion.text = text(next, sources);
  else if (textShape === 7) suggestion.text = pick(next, [5, true, null, ['a', 'b']]);
  return suggestion;
};

const rawDraft = (next: () => number, sources: string[], quests: string[]): unknown => {
  const draft: Record<string, unknown> = {};
  const answerShape = integer(next, 29);
  if (answerShape > 0) draft.answer = answerShape === 1 ? 42 : text(next, sources);
  const patternsShape = integer(next, 9);
  if (patternsShape <= 6) draft.patterns = Array.from({ length: integer(next, 3) }, () => (chance(next, 0.1) ? 3 : sentence(next, sources)));
  else if (patternsShape === 7) draft.patterns = 'not a list';
  const suggestionsShape = integer(next, 9);
  if (suggestionsShape <= 7) draft.suggestions = Array.from({ length: integer(next, 3) }, () => rawSuggestion(next, sources, quests));
  else if (suggestionsShape === 8) draft.suggestions = { kind: 'shift_time' };
  const noteShape = integer(next, 5);
  if (noteShape <= 1) draft.limitationNote = sentence(next, sources);
  else if (noteShape === 2) draft.limitationNote = null;
  else if (noteShape === 3) draft.limitationNote = 9;
  return draft;
};

const SEEDED_RUNS = 1500;
const seeded: ReturnType<typeof guardrailCase>[] = [];
const parseCases: { id: string; raw: string; output: Json }[] = [];
for (let run = 0; run < SEEDED_RUNS; run++) {
  const next = lcg(20261121 + run * 7919);
  const sources = Array.from({ length: integer(next, 3) }, () => sourceText(next));
  if (chance(next, 0.05)) sources.push(pick(next, CRISIS));
  const quests = ['11', '12', '0198a3f0-7b1c-7d2e-9f00-000000000011'].slice(0, 1 + integer(next, 2));
  const raw = JSON.stringify(rawDraft(next, sources, quests));
  const result = parsed(raw);
  parseCases.push({ id: `seeded ${run}`, raw, output: clean(result) });
  if (!('draft' in result)) continue;
  const queryText = chance(next, 0.05) ? pick(next, CRISIS) : pick(next, ['why do I miss evening quests?', 'what should I change?', 'how is my week going?']);
  seeded.push(guardrailCase(`seeded ${run}`, { queryText, sensitiveSources: sources, allowedQuestIds: quests, draft: result.draft as Record<string, unknown> }));
}

const literalRaw = [
  'null',
  '"text"',
  '[]',
  '42',
  '{}',
  '{"answer":null}',
  '{"answer":""}',
  '{"answer":"a","answer":"b"}',
  '{"answer":"a","patterns":["x",1,null,"y"],"suggestions":[null,{},[],"s",1,{"kind":"pause_quest"}],"limitationNote":""}',
  '{"limitationNote":"n","answer":"a"}',
  '{"answer":"a","extra":{"nested":true},"suggestions":[{"questId":"11","kind":"shift_time","text":"t","extra":1}]}',
  '{"answer":"\\u00e9\\ud83d\\ude00","patterns":["\\u2028"]}',
];
literalRaw.forEach((raw, index) => parseCases.push({ id: `literal ${index}`, raw, output: clean(parsed(raw)) }));

const quoteCases: { id: string; output: string; sources: string[]; quote: Json }[] = [];
for (const quote of specQuotes) quoteCases.push({ ...quote, quote: findVerbatimQuote(quote.output, quote.sources) });
const quoteProbes: [string, string[]][] = [
  ['', ['one two three four']],
  ['one two three four', ['one two three four']],
  ['xone two three foury', ['one two three four']],
  ['one two three', ['one two three']],
  ['ONE—TWO…THREE“FOUR', ['one two three four']],
  ['one two three four five six seven', ['one two three four five six seven eight']],
  ['two three four five six seven eight', ['one two three four five six seven eight']],
  ['one two three four five six', ['one two three four five six seven eight']],
  ['the café is near', ['the café is near']],
  ['the caf is near', ['the café is near']],
  ['i̇stanbul is far away', ['İstanbul is far away']],
  ['kelvin is a unit here', ['Kelvin is a unit here']],
  ['ſtrong words were said', ['strong words were said']],
  ['東京 is far from here now', ['東京 is far from here now']],
  ['is far from here now', ['東京 is far from here now']],
  ['привет', ['привет мир как дела']],
  ['a b c d', ['a b c　d']],
  ['x1 y2 z3 w4', ['x1 y2 z3 w4']],
  ['don t do that again ok', ['don’t do that again ok']],
  ['one two three four', ['', '   ', 'one two three four']],
  ['first second third fourth fifth sixth seventh', ['zero first second third fourth fifth sixth seventh eighth', 'first second third fourth']],
];
quoteProbes.forEach(([output, sources], index) => quoteCases.push({ id: `probe ${index}`, output, sources, quote: findVerbatimQuote(output, sources) }));
// A run the check should find: a whole short source or a seven-to-nine-word stretch of a long one, re-cased, re-punctuated or wrapped, which
// normalisation undoes; one in five then loses a word or an accent, which it does not.
const runOf = (next: () => number, source: string): string => {
  const words = source.split(/\s+/).filter(Boolean);
  const length = words.length <= 7 ? words.length : 7 + integer(next, 2);
  const start = integer(next, Math.max(0, words.length - length));
  let run = words.slice(start, start + length);
  if (chance(next, 0.2)) run = run.filter((_, index) => index !== integer(next, run.length - 1));
  let quote = run.join(pick(next, [' ', '  ', ' — ', '...', ', ', '\n', '\u00a0']));
  if (chance(next, 0.3)) quote = quote.toUpperCase();
  if (chance(next, 0.3)) quote = `“${quote}”`;
  if (chance(next, 0.1)) quote = quote.replace(/e/g, 'é');
  return quote;
};
const longSource = (next: () => number): string => {
  const length = 4 + integer(next, 11);
  return Array.from({ length }, () => pick(next, SOURCE_WORDS)).join(pick(next, [' ', ' ', ', ', ' - ', '\n']));
};
for (let run = 0; run < 400; run++) {
  const next = lcg(4242 + run * 7919);
  const sources = Array.from({ length: 1 + integer(next, 2) }, () => (chance(next, 0.8) ? longSource(next) : sourceText(next)));
  const piece = (): string => {
    const roll = integer(next, 9);
    if (roll < 6) return runOf(next, pick(next, sources));
    if (roll < 8) return quoteOf(next, pick(next, sources));
    return pick(next, NEUTRAL);
  };
  const output = Array.from({ length: 1 + integer(next, 2) }, piece).join(' ');
  quoteCases.push({ id: `seeded ${run}`, output, sources, quote: findVerbatimQuote(output, sources) });
}

const contexts: [string, string, unknown][] = [
  [
    'why do I keep failing evening quests?',
    'empty',
    {
      profile: { timezone: 'Europe/London', intensityMode: 'standard', windowStart: null },
      quests: [],
      questLogs: [],
      heroEvents: [],
      dailyStates: [],
      progressionEvents: [],
      finance: [],
      metrics: [],
      meals: [],
      sideQuests: [],
      journal: [],
      health: [],
    },
  ],
  [
    'Wie war meine Woche? 😀',
    'rows',
    {
      profile: { timezone: 'Asia/Kolkata', intensityMode: 'gentle', windowStart: '2026-08-21' },
      quests: [{ id: '0198a3f0-7b1c-7d2e-9f00-000000000011', name: 'Run “early”\n', startTimeMin: 390, durationMin: null, strictness: 'anchor', active: true }],
      questLogs: [{ questId: '0198a3f0-7b1c-7d2e-9f00-000000000011', date: '2026-11-20', state: 'missed', xpAwarded: 0, reasonNote: 'tab\there "quote" \\ back' }],
      heroEvents: [],
      dailyStates: [{ date: '2026-11-20', hpStart: 100, hpEnd: 92.5, momentumBucket: 'warm' }],
      progressionEvents: [{ entity: 'title', titleId: 'early_bird', earnedAt: '2026-11-19T06:00:00.000Z' }],
      finance: [{ entity: 'expense', amountMinor: 1250, currency: 'EUR', homeAmountMinor: 1250, merchant: 'Café Ü', occurredOn: '2026-11-20' }],
      metrics: [{ entity: 'metric_entry', metricId: 'm1', date: '2026-11-20', value: '7.25', source: 'manual' }],
      meals: [],
      sideQuests: [],
      journal: [{ date: '2026-11-20', text: 'line separator and \u0007 bell', mood: 3, tags: ['a', 'b'] }],
      health: [{ entity: 'weight', date: '2026-11-20', kg: '72.4' }],
    },
  ],
];
const prompts = contexts.map(([queryText, id, context]) => ({ id, queryText, context: clean(context), output: buildPrompt(queryText, context) }));

const writeJson = (name: string, groups: Record<string, readonly unknown[]>): void => {
  const body = Object.entries(groups)
    .map(([key, items]) => `${JSON.stringify(key)}: [\n${items.map(item => JSON.stringify(item)).join(',\n')}\n]`)
    .join(',\n');
  writeFileSync(join(outDir, name), `{\n${body}\n}\n`);
};

writeJson('guardrails.json', { spec, seeded });
writeJson('quotes.json', { cases: quoteCases });
writeJson('parse.json', { cases: parseCases });
writeJson('prompts.json', { cases: prompts });
writeFileSync(
  join(outDir, 'contract.json'),
  `${JSON.stringify({ allowedSuggestionKinds: ALLOWED_SUGGESTION_KINDS, crisisResponseAnswer: CRISIS_RESPONSE_ANSWER, systemPrompt: buildPrompt('', {}).systemPrompt }, null, 2)}\n`,
);
