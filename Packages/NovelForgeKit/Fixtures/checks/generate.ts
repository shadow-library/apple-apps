import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');

const graphsDir = join(platformRepo, 'apps/novel-forge-server/src/modules/ai/graphs');
const mechanical = await import(join(graphsDir, 'mechanical-check.ts'));
const readability = await import(join(graphsDir, 'readability-check.ts'));

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

const rng = createRng(0x14c4);

const WORDS = [
  'the', 'a', 'and', 'she', 'he', 'they', 'walked', 'door', 'light', 'rain', 'Mira', 'Tomas', 'quietly', 'heart', 'eyes', 'hands', 'night', 'river', 'lamp', 'stone', 'across',
  'before', 'under', 'window', 'carried', 'silence', 'toward', 'morning', 'bread', 'letter', 'about', 'there', 'where', 'never', 'remembered', 'between', 'every', 'harbour',
  'Naïve', 'café', 'İstanbul', '😀', '𝒜', 'é',
];
const NAMES = ['Mira', 'Tomas', 'Old Ben', 'Ines', 'Kael', 'Ada Lin'];
const SAID = ['said', 'asked', 'SAID', 'Asked'];
const ALTERNATIVES = ['exclaimed', 'growled', 'whispered', 'SHOUTED', 'Muttered', 'hissed', 'snapped', 'replied', 'sighed', 'laughed', 'added'];
const STOCK = [
  'her eyes narrowed', 'his jaw tightened', 'her breath hitched', 'a mixture of fear and awe', 'his heart was pounding', 'his eyes widened', 'a shiver ran down her spine',
  'he clenched his fists', 'her stomach dropped', 'his blood ran cold', 'a ghost of a smile', 'she let out a heavy sigh', 'she raised an eyebrow', 'EYES WIDENED',
];
const SIMILES = [
  'like a lantern', 'like an anchor', 'Like a stone', 'LIKE A BELL', 'like she was lost', 'like he’d been warned', "like they had left", 'like it could break', 'the way a door closes',
  'the way someone breathes', 'The way you wait', 'the kind of silence', 'the sort of man', 'the way people leave', 'the way one remembers',
];
const NON_SIMILES = [
  'I like a good tea', 'you like an early start', "they would like a word", "she doesn't like a crowd", "he didn’t like an argument", "I'd like a word", 'we’d like an answer',
  'to like a person', 'on the way a', 'by the way someone', 'might like a chance', 'She would like a minute', 'wouldn’t like a fight', 'on the way one',
];
const ORNATE = ['The architecture of her grief held the house together.', 'The silence had a weight she could taste.', 'The room held its breath.', 'His voice like a bell carried.'];
const FRAGMENTS = [
  '“Come along,” said Mira.', '"Not yet," asked Tomas.', '‘Hold on,’ whispered Ines.', 'He said ‘no’ and left.', 'It’s Tomas’s don’t-care way.', '‘em and ’twas fine.', '‘unclosed quote like a stone',
  'She said “open like a door', 'A ‘quoted like a thing’ word.', '“a” and “b” like a pair', "'tis the way a river runs", 'He muttered ‘ere we go’ the way a man might.',
];
const NASTY = [' ', '\t', '\n', '\r\n', '\n\n', ' \n \n ', ' ', ' ', '﻿', '　', '😀', '𝒜', 'é', 'é', '”', '“', '’', '‘', '"', "'", '.', '!', '...', '…', '|', '```', '~~~'];

function words(count: number): string {
  return Array.from({ length: count }, () => rng.pick(WORDS)).join(' ');
}

const SHORT_WORDS = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'];
function shortWords(count: number): string {
  return Array.from({ length: count }, () => rng.pick(SHORT_WORDS)).join(' ');
}

function sentence(): string {
  const roll = rng.next();
  if (roll < 0.1) return `${words(rng.int(2, 8))} ${rng.pick(STOCK)} ${words(rng.int(0, 4))}.`;
  if (roll < 0.25) return `${words(rng.int(1, 5))} ${rng.pick(SIMILES)} ${words(rng.int(1, 5))}.`;
  if (roll < 0.3) return `${rng.pick(NON_SIMILES)} ${words(rng.int(1, 4))}.`;
  if (roll < 0.35) return rng.pick(ORNATE);
  if (roll < 0.5) return `“${words(rng.int(2, 8))},” ${rng.chance(0.5) ? rng.pick(NAMES) + ' ' : ''}${rng.pick(rng.chance(0.5) ? SAID : ALTERNATIVES)}.`;
  if (roll < 0.55) return rng.pick(FRAGMENTS);
  return `${words(rng.int(3, 20))}.`;
}

function paragraph(sentences = rng.int(1, 5)): string {
  return Array.from({ length: sentences }, sentence).join(rng.pick([' ', ' ', '  ', '\n']));
}

function chapter(paragraphCount: number, joiner?: string): string {
  const separators = ['\n\n', '\n\n', '\r\n\r\n', '\n \n', '\n\n\n', '\n\t\n'];
  return Array.from({ length: paragraphCount }, paragraph).join(joiner ?? rng.pick(separators));
}

function nasty(maxPieces: number): string {
  let out = '';
  for (let i = 0; i < rng.int(0, maxPieces); i++) out += rng.chance(0.4) ? rng.pick(WORDS) : rng.pick(NASTY);
  return out;
}

function repeated(text: string, times: number, glue = '\n\n'): string {
  return Array.from({ length: times }, () => text).join(glue);
}

const LONG_PARAGRAPH = `${words(30)}. ${words(22)}.`;
const longWordsParagraph = (count: number): string => `${words(count)}.`;

const LONE_SURROGATE = /[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]/g;
const withoutLoneSurrogates = (findings: { severity: string; text: string }[]) => findings.map((finding) => ({ ...finding, text: finding.text.replace(LONE_SURROGATE, '') }));

const mechanicalCases: unknown[] = [];
function mechanicalCase(markdown: string, prior: string[], target: unknown): void {
  const resolved = target ? { ...(target as object), aim: 0 } : undefined;
  mechanicalCases.push([markdown, prior, target, withoutLoneSurrogates(mechanical.checkDraftMechanics(markdown, prior, resolved as never))]);
}

const lowTarget = { min: 5, max: 20 };
const midTarget = { min: 650, max: 700 };
const smallBand = { min: 40, max: 120 };
const fractional = { min: 100.5, max: 300.25 };

for (const body of ['', ' ', 'one', words(10), words(100), shortWords(700), shortWords(2000)]) {
  mechanicalCase(body, [], null);
  mechanicalCase(body, [], lowTarget);
  mechanicalCase(body, [], midTarget);
  if (body.length < 1000) mechanicalCase(body, [], fractional);
}
for (const count of [1100, 1199, 1200, 1799, 1800, 2600, 2601, 3200, 3201]) mechanicalCase(`${shortWords(count)}.`, [], null);
for (const count of [49, 50, 51, 649, 650, 700, 701, 1299, 1300, 1301]) mechanicalCase(`${shortWords(count)}.`, [], { min: 650, max: 700 });
for (const count of [-595, -1, 0]) mechanicalCase(words(5), [], { min: count, max: 10 });
mechanicalCase(words(30), [], { min: 700, max: 100 });
mechanicalCase(words(30), [], { min: 0, max: 0 });

for (const prose of ['```\n' + words(10) + '\n```', '```js\n' + words(10), `${words(40)}\n\n\`\`\`${words(5)}\n${words(40)}`, '~~~ ' + words(90) + '\nafter', '```' + '😀'.repeat(60) + '\n' + words(5)]) {
  mechanicalCase(prose, [], smallBand);
  mechanicalCase(`${words(30)}\n\n${prose}`, [], null);
}
mechanicalCase('```system\nHP 10\n```\n' + words(60), [], smallBand);
mechanicalCase('| a | b |\n| - | - |\n| 1 | 2 |\n' + words(60), [], smallBand);

const dupParagraph = longWordsParagraph(24);
const shortParagraph = longWordsParagraph(10);
const twentyWords = `${words(19)} end`;
const nineteenWords = `${words(18)} end`;
const dupCases = [
  repeated(dupParagraph, 2),
  repeated(dupParagraph, 3),
  `${dupParagraph}\n\n${words(5)}.\n\n${dupParagraph}`,
  `${dupParagraph}\n\n${dupParagraph.replace(/ /g, '  ')}`,
  `${dupParagraph}\n\n${dupParagraph.toUpperCase()}`,
  `${dupParagraph}\n\n${dupParagraph}\r\n\r\n${LONG_PARAGRAPH}\n\n${LONG_PARAGRAPH}`,
  `${dupParagraph}\n \n  ${dupParagraph}\n\t\n${dupParagraph}`,
  repeated(shortParagraph, 4),
  repeated(twentyWords, 2),
  repeated(nineteenWords, 2),
  `${dupParagraph}\n${dupParagraph}`,
  repeated('😀 ' + dupParagraph, 2),
  repeated('é' + dupParagraph, 2) + '\n\n' + repeated('é' + dupParagraph, 2),
  repeated(`${words(80)} ${'x'.repeat(100)}.`, 2),
  repeated(`${'😀'.repeat(50)} ${words(30)}.`, 2),
  repeated(`${words(30)} ${'😀'.repeat(40)}`, 2),
  `${dupParagraph} \n\n${dupParagraph}`,
  `${dupParagraph} ${dupParagraph}\n\n${dupParagraph} ${dupParagraph}`,
];
for (const body of dupCases) mechanicalCase(body, [], smallBand);

const echoClosing = 'Mira stood at the harbour wall and watched the ships come in under a grey and heavy sky until the last lamp went dark.';
const echoOpening = 'Mira stood at the harbour wall and watched the ships come in under a grey sky. Then she turned and walked home alone through the rain.';
const prior = [`${words(40)}. ${echoClosing}`, chapter(2)];
mechanicalCase(echoOpening + ' ' + words(60), prior, smallBand);
mechanicalCase(`${words(30)}. ${echoOpening}`, prior, smallBand);
mechanicalCase(echoOpening + ' ' + words(60), [chapter(3)], smallBand);
mechanicalCase(echoOpening, ['', echoClosing], smallBand);
mechanicalCase(echoOpening, [''], smallBand);
mechanicalCase(echoOpening, [echoClosing], smallBand);
mechanicalCase(words(5) + ' ' + echoClosing, [echoClosing], smallBand);
mechanicalCase('```system\n' + echoClosing + '\n```\n' + words(40), [echoClosing], smallBand);
mechanicalCase(words(40), ['```\n' + echoClosing + '\n```'], smallBand);
mechanicalCase('one two three four five six seven', ['one two three four five six seven'], null);
mechanicalCase('one two three four five', ['one two three four five six'], null);
mechanicalCase('ONE two, three four! five six', ['One TWO three four five six'], null);

const ngramBank = ['the old lighthouse keeper climbed slowly', 'rain drummed against the shuttered window again', 'she carried the letter across the harbour road', 'nobody on the quay remembered his name'];
const ngramPrior = ngramBank.join(' ') + ' ' + words(30);
for (const rate of [0, 1, 2, 4]) {
  const body = ngramBank.slice(0, rate).join('. ') + '. ' + words(rng.int(60, 120)) + '.';
  mechanicalCase(body, [ngramPrior], smallBand);
  mechanicalCase(body, [ngramPrior, chapter(2), chapter(1)], smallBand);
}
mechanicalCase(ngramBank.join(' ') + ' ' + ngramBank.join(' '), [ngramBank.join(' ')], null);

const stockBody = (count: number) => Array.from({ length: count }, () => `${words(3)} ${rng.pick(STOCK)}.`).join(' ') + ' ' + words(40) + '.';
for (const count of [0, 3, 5, 6, 7, 10, 14]) mechanicalCase(stockBody(count), [], smallBand);
mechanicalCase(Array.from({ length: 4 }, (_, i) => `${STOCK[i % 2]}. ${STOCK[(i + 4) % 5]}.`).join(' ') + ' ' + words(30), [], smallBand);
mechanicalCase(['her eyes narrowed', 'his jaw tightened', 'her breath hitched', 'a ghost of a smile'].flatMap((phrase, index) => Array.from({ length: index + 2 }, () => `${phrase}.`)).join(' '), [], smallBand);
mechanicalCase(
  ['his eyes widened', 'her stomach dropped', 'his blood ran cold', 'she raised an eyebrow'].flatMap((phrase) => Array.from({ length: 2 }, () => `${phrase}.`)).join(' '),
  [],
  smallBand,
);

const simileBody = (frame: string, count: number, filler: number): string =>
  Array.from({ length: count }, () => `${words(rng.int(2, 6))} ${frame} ${words(rng.int(1, 4))}.`).join(' ') + ' ' + shortWords(filler) + '.';
for (const frame of ['like a lantern', 'like she was lost', 'the way a door closes', 'the kind of silence', 'the sort of thing', 'like an owl']) {
  for (const [count, filler] of [[4, 100], [5, 100], [5, 1500], [6, 100], [9, 400], [12, 700]] as const) mechanicalCase(simileBody(frame, count, filler), [], smallBand);
}
for (const frame of NON_SIMILES) mechanicalCase(simileBody(frame, 6, 80), [], smallBand);
for (const frame of SIMILES) mechanicalCase(simileBody(`“${frame}”`, 6, 80), [], smallBand);
mechanicalCase(simileBody('like a lantern', 6, 80).replace(/ like a lantern/g, ' "like a lantern" and like a lantern'), [], smallBand);
mechanicalCase(simileBody('like a lantern', 6, 80).replace(/ like a lantern/g, ' ‘like a lantern’ ‘like a lantern’'), [], smallBand);
mechanicalCase(
  Array.from({ length: 6 }, () => `She said ‘it’s like a thing’ and left. He wasn’t like a king.\n\n‘Don’t,’ he said, like a man.`).join('\n\n') + ' ' + words(60),
  [],
  smallBand,
);
mechanicalCase(Array.from({ length: 6 }, () => 'It was like a lantern “and like a lantern').join('\n\n') + ' ' + words(20), [], smallBand);
mechanicalCase(Array.from({ length: 6 }, () => 'like a lantern ‘open like a lantern and more').join('\n\n') + ' ' + words(20), [], smallBand);
mechanicalCase(Array.from({ length: 6 }, () => 'Like a lantern. “Quoted” like a lantern.\nlike a lantern').join('\n \n') + ' ' + words(20), [], smallBand);
mechanicalCase(Array.from({ length: 6 }, () => 'The way a river runs. like a bell. the\tway\ta thing. like\na lantern').join('\n\n') + ' ' + words(20), [], smallBand);
mechanicalCase(Array.from({ length: 8 }, () => 'don’t like a lantern. didn’t like a lantern. wouldn’t like a lantern. WASN’T LIKE A LANTERN. I’d like a lantern. I like a lantern. like a lantern').join('\n\n'), [], null);
mechanicalCase(Array.from({ length: 6 }, () => '😀 like a lantern 😀 the kind of é').join('\n\n') + ' ' + words(20), [], smallBand);

const tagBody = (count: number, verbs: readonly string[], filler: number): string =>
  Array.from({ length: count }, () => `“${words(rng.int(2, 5))},” ${rng.chance(0.3) ? rng.pick(NAMES) + ' ' : ''}${rng.pick(verbs)}.`).join(' ') + ' ' + shortWords(filler) + '.';
for (const [count, filler] of [[2, 100], [9, 60], [10, 60], [11, 60], [10, 600], [40, 500], [12, 200]] as const) {
  mechanicalCase(tagBody(count, ALTERNATIVES, filler), [], smallBand);
  mechanicalCase(tagBody(count, SAID, filler), [], smallBand);
  mechanicalCase(tagBody(count, [...SAID, ...ALTERNATIVES], filler), [], smallBand);
}
mechanicalCase(tagBody(10, [...Array.from({ length: 5 }, () => 'said'), ...Array.from({ length: 5 }, () => 'hissed')], 800), [], smallBand);
mechanicalCase(Array.from({ length: 10 }, (_, i) => `“${words(3)},” ${i % 2 ? 'hissed' : 'said'}.`).join(' ') + ' ' + words(800), [], smallBand);
mechanicalCase(Array.from({ length: 11 }, (_, i) => `“${words(3)},” ${i % 2 ? 'hissed' : 'said'}.`).join(' ') + ' ' + words(800), [], smallBand);

for (let i = 0; i < 24; i++) {
  const priors = Array.from({ length: rng.int(0, 3) }, () => chapter(rng.int(1, 3)));
  const body = chapter(rng.int(1, 6));
  const sources = [null, smallBand, lowTarget, fractional];
  mechanicalCase(body + (rng.chance(0.2) ? '\n\n' + repeated(longWordsParagraph(rng.int(18, 26)), 2) : ''), priors, rng.pick(sources));
}
for (let i = 0; i < 24; i++) mechanicalCase(nasty(25), [nasty(10), nasty(10)].slice(0, rng.int(0, 2)), rng.pick([null, smallBand, lowTarget]));

const lazyDialogue = Array.from({ length: 6 }, () => 'She said ‘a’ like a lantern ‘b’ and left.').join('\n\n') + ' ' + shortWords(60) + '.';
mechanicalCase(lazyDialogue, [], smallBand);
mechanicalCase(Array.from({ length: 6 }, () => 'He said ‘a’ the way a river runs ‘b’ and ‘c’ the kind of man ‘d’.').join('\n') + ' ' + shortWords(60) + '.', [], smallBand);
const fewPhrases = [...Array.from({ length: 3 }, () => 'her eyes narrowed.'), ...Array.from({ length: 3 }, () => 'his jaw tightened.')].join(' ') + ' ' + shortWords(40) + '.';
mechanicalCase(fewPhrases, [], smallBand);
mechanicalCase(Array.from({ length: 6 }, () => 'her breath hitched.').join(' ') + ' ' + shortWords(40) + '.', [], smallBand);
mechanicalCase(Array.from({ length: 5 }, () => 'her breath hitched.').join(' ') + ' ' + shortWords(40) + '.', [], smallBand);

const simileCases: unknown[] = [];
const simileBodies: string[] = [''];
for (const body of ['like a like a like a like a like a', words(3), 'like a lantern'.repeat(2)]) simileBodies.push(body);
for (let i = 0; i < 30; i++) simileBodies.push(simileBody(rng.pick(SIMILES), rng.int(3, 8), rng.int(20, 800)));
for (let i = 0; i < 8; i++) simileBodies.push(chapter(rng.int(2, 5)));
for (const body of simileBodies) simileCases.push([body, mechanical.findSimileFrameOveruse(body)]);

const boundaryCases: unknown[] = [];
const echoInputs: [string, string | null][] = [
  ['', null], ['', ''], [echoOpening, ''], [echoOpening, echoClosing], [words(8), words(8)], ['a b c d e f', 'a b c d e f'], ['a b c d e', 'a b c d e f'],
  [words(70) + ' x y z a b c d', 'q r s t u v ' + words(70)],
];
for (const [body, prev] of echoInputs) boundaryCases.push([body, prev, mechanical.findBoundaryEcho(body, prev ?? undefined)]);
for (let i = 0; i < 24; i++) {
  const shared = words(rng.int(6, 9));
  const head = words(rng.int(0, 70));
  const tail = words(rng.int(0, 70));
  const body = rng.chance(0.5) ? `${head} ${shared} ${tail}` : `${shared} ${tail}`;
  const prev = rng.chance(0.8) ? `${tail} ${shared} ${head}` : chapter(2);
  boundaryCases.push([body, prev, mechanical.findBoundaryEcho(body, prev)]);
}

const duplicateCases: unknown[] = [];
for (const body of dupCases) {
  duplicateCases.push([body, null, mechanical.findDuplicatedParagraphs(body)]);
  duplicateCases.push([body, 5, mechanical.findDuplicatedParagraphs(body, 5)]);
  duplicateCases.push([body, 0, mechanical.findDuplicatedParagraphs(body, 0)]);
}
duplicateCases.push(['', null, mechanical.findDuplicatedParagraphs('')]);
duplicateCases.push(['a\n\n\n\na\n\nb\n\nb\n\nA', 1, mechanical.findDuplicatedParagraphs('a\n\n\n\na\n\nb\n\nb\n\nA', 1)]);

const boundsCases = [{ min: 1800, max: 2600 }, { min: 650, max: 700 }, { min: -5, max: 0.5 }, { min: 100.25, max: 1e21 }, { min: 0, max: 0 }].map((target) => [
  target,
  mechanical.resolveWordCountHardBounds({ ...target, aim: 0 }),
]);

const READABILITY_BODIES: string[] = [];
const longSentence = (count: number): string => `${shortWords(count)}.`;
const plainSentence = (): string => `${rng.chance(0.5) ? shortWords(rng.int(4, 12)) : words(rng.int(4, 12))}.`;
function plainChapter(sentences: number): string {
  const paragraphs: string[] = [];
  for (let i = 0; i < sentences; i += 3) paragraphs.push(Array.from({ length: Math.min(3, sentences - i) }, plainSentence).join(' '));
  return paragraphs.join('\n\n');
}
READABILITY_BODIES.push('', words(10), plainChapter(10), plainChapter(40), plainChapter(50), plainChapter(100));
for (const body of [plainChapter(40), plainChapter(50)]) {
  READABILITY_BODIES.push(body.replace(/\n\n/g, ' '));
  READABILITY_BODIES.push(body + '\n\n' + ORNATE.join(' ') + ' ' + ORNATE.join(' '));
  READABILITY_BODIES.push(body + '\n\n' + Array.from({ length: 6 }, () => longSentence(rng.int(31, 45))).join(' '));
  READABILITY_BODIES.push(ORNATE.join(' ') + ' ' + body + ' ' + Array.from({ length: 8 }, () => longSentence(rng.int(31, 45))).join(' '));
  READABILITY_BODIES.push(body + '\n\n```system\nHP\n```\n' + ORNATE[0]);
}
READABILITY_BODIES.push(Array.from({ length: 16 }, () => 'The architecture of her grief held the house together.').join(' ') + ' ' + shortWords(400) + '.');
READABILITY_BODIES.push(Array.from({ length: 3 }, () => ORNATE[0]).join(' ') + ' ' + plainChapter(100));
READABILITY_BODIES.push(Array.from({ length: 2 }, () => ORNATE[0]).join(' ') + ' ' + shortWords(300) + '.');
READABILITY_BODIES.push(`${'a '.repeat(199)}b😀 ${'a '.repeat(10)}end. ${shortWords(400)}.`, `${'a '.repeat(199)}😀 ${'a '.repeat(10)}end. ${shortWords(400)}.`, longSentence(399), longSentence(400), longSentence(401), longSentence(450), `${words(399)}`, `${words(400)}`);
READABILITY_BODIES.push(Array.from({ length: 12 }, () => longSentence(60)).join('\n\n'));
READABILITY_BODIES.push(Array.from({ length: 6 }, () => `${'😀'.repeat(300)} ${longSentence(40)}`).join(' '));
READABILITY_BODIES.push(Array.from({ length: 6 }, () => `“${longSentence(60)}” ${longSentence(10)}`).join('\n'));
READABILITY_BODIES.push(Array.from({ length: 3 }, () => `${'extraordinarily '.repeat(100)}.`).join('\n\n'));
READABILITY_BODIES.push(`${'x'.repeat(900)}. ${words(400)}.`);
READABILITY_BODIES.push(Array.from({ length: 5 }, () => `${words(30)} ${'é'.repeat(150)} ${words(10)}.`).join(' ') + ' ' + words(400) + '.');
READABILITY_BODIES.push(`${words(405)}.\n\n${'😀'.repeat(150)} ${'a'.repeat(140)}${'😀'.repeat(60)} ${words(40)}.`);
for (let i = 0; i < 5; i++) READABILITY_BODIES.push(chapter(rng.int(12, 24), '\n\n'));

const readabilityCases: unknown[] = [];
for (const body of READABILITY_BODIES) {
  const evidence = readability.assessReadability(body);
  readabilityCases.push([body, evidence ? { metrics: evidence.metrics, overLimits: evidence.overLimits, flagged: evidence.flagged } : null, evidence ? readability.renderReadabilityEvidence(evidence).replace(LONE_SURROGATE, '') : null, readability.readabilityNote(evidence)]);
}

const constants = {
  mechanicalPrefix: mechanical.MECHANICAL_PREFIX,
  wordCountHardSlack: mechanical.WORD_COUNT_HARD_SLACK,
  wordCountHardMin: mechanical.WORD_COUNT_HARD_MIN,
  wordCountHardMax: mechanical.WORD_COUNT_HARD_MAX,
  duplicateParagraphMinWords: mechanical.DUPLICATE_PARAGRAPH_MIN_WORDS,
  readabilityPrefix: readability.READABILITY_PREFIX,
  readabilityMinWords: readability.READABILITY_MIN_WORDS,
  averageSentenceWordsMax: readability.AVERAGE_SENTENCE_WORDS_MAX,
  longSentenceShareMax: readability.LONG_SENTENCE_SHARE_MAX,
  averageParagraphWordsMax: readability.AVERAGE_PARAGRAPH_WORDS_MAX,
  readingGradeMax: readability.READING_GRADE_MAX,
  ornateHitsPer1000WordsMax: readability.ORNATE_HITS_PER_1000_WORDS_MAX,
  ornateHitsMin: readability.ORNATE_HITS_MIN,
  simileFrames: mechanical.SIMILE_FRAMES.map((frame: { label: string; pattern: RegExp }) => [frame.label, frame.pattern.source, frame.pattern.flags]),
};

const here = dirname(fileURLToPath(import.meta.url));
function write(name: string, value: unknown): void {
  writeFileSync(join(here, name), JSON.stringify(value) + '\n');
}

write('mechanical.json', mechanicalCases);
write('similes.json', [constants, simileCases, boundaryCases, duplicateCases, boundsCases]);
write('readability.json', readabilityCases);
