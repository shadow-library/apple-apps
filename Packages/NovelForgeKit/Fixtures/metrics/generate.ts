import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');

const evalDir = join(platformRepo, 'apps/novel-forge-server/src/modules/eval');
const metrics = await import(join(evalDir, 'deterministic-metrics.ts'));
const prose = await import(join(evalDir, 'chapter-prose.ts'));

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

const rng = createRng(0x4d37);

const WORDS = [
  'the', 'a', 'and', 'she', 'he', 'they', 'walked', 'door', 'light', 'rain', 'Mira', 'Tomas', 'quietly', 'heart', 'eyes', 'hands', 'night', 'river', 'lamp',
  'stone', 'across', 'before', 'under', 'window', 'carried', 'silence', 'toward', 'morning', 'bread', 'letter', 'Dr', 'Mrs', 'about', 'there', 'where', 'never',
  'remembered', 'between', 'every', 'harbour', 'sixteen', 'cities', 'rhythm', 'queue', 'eyes', 'toes', 'Naïve', 'café', 'ſtone', 'K', 'İstanbul', 'ΣΑΣ',
];
const NAMES = ['Mira', 'Tomas', 'Old Ben', 'Ines', 'Mr Voss', 'Kael', 'Ada Lin'];
const ENDERS = ['.', '.', '.', '.', '!', '?', '...', '!!', '?!', '."', '!"', '?”', '.”', '.’', '.)', '.]', '.\'"', '. ', '…'];
const NASTY = [
  ' ', ' ', ' ', '\t', '\n', '\r\n', '\r', ' ', ' ', ' ', '﻿', '　', '᠎', '\u0085', '​', ' ', '😀', '𝒜', 'é', 'é', 'İ', 'K',
  'ſ', 'ß', 'Σ', 'ς', '”', '“', '’', '‘', '"', "'", '.', '!', '?', '…', '(', ')', ']', '|', '\\', '`', '~', '#', '>', '-', '*', '_', ':', 'a', 'b', 'Z', 'y', 'e', 'd', 's',
  '1', '3.5', 'said', 'asked', 'Mr.', 'e.g.', "don't", 'I’m', 'The', 'system',
];

const STOCK = [
  'her eyes narrowed', 'he narrowed his eyes', 'his jaw tightened', 'her breath hitched', 'a mixture of fear and awe', 'his heart was pounding',
  "she let out a breath she didn't know she was holding", 'his eyes widened', 'her voice, barely above a whisper', 'a shiver ran down her spine', 'he clenched his fists',
  'her stomach dropped', 'his blood ran cold', 'time seemed to slow', 'the world seemed to freeze', "he couldn't help but laugh", 'a ghost of a smile', 'she let out a heavy sigh',
  'her eyes flickered', 'he swallowed the lump in his throat', 'she raised an eyebrow', 'he released a breath he did not realize he was holding', 'EYES WIDENED',
];
const ORNATE = [
  'The architecture of her grief held the house together.', 'He knew the way one remembers songs.', "It was fate's idea of a joke.", 'Her voice like a bell carried.',
  'The silence had a weight she could taste.', 'The room held its breath.', 'The way one of them spoke was plain.', 'The cartography of their silence.',
];
const VERBS = ['said', 'asked', 'exclaimed', 'growled', 'whispered', 'SHOUTED', 'Muttered', 'hissed', 'laughed', 'added', 'agreed', 'replied', 'sighed', 'nodded'];
const CONTRACTIONS = [
  "I don't know", 'I do not know', "it's fine", 'it is fine', "I'm here", 'I am here', "we’ll go", 'we will go', "can't", 'cannot', "let's", 'let us', "THEY'RE", 'they are',
  "doesn't", 'does not', "he's", 'he is', "I've", 'I have', "you’re", 'you are', "won't", 'will not', 'there is', "that's",
];
const HOOKS = ['cliffhanger', 'question', 'reveal', 'quiet', 'Cliffhanger', '2', '10', '01', '1', 'a b', '😀', 'é', 'é', ' ', 'x'];

function words(count: number): string {
  const out: string[] = [];
  for (let i = 0; i < count; i++) out.push(rng.pick(WORDS));
  return out.join(' ');
}

function sentenceLength(): number {
  const roll = rng.next();
  if (roll < 0.25) return rng.int(1, 5);
  if (roll < 0.7) return rng.int(6, 22);
  if (roll < 0.9) return rng.int(23, 30);
  return rng.int(31, 45);
}

function sentence(): string {
  const roll = rng.next();
  if (roll < 0.08) return `${rng.pick(NAMES)} ${rng.pick(['met', 'saw'])} ${rng.pick(['Dr.', 'Mrs.', 'Mr.', 'Prof.', 'J.', 'etc.', 'e.g.', 'a.m.', 'No.', 'Mt.'])} ${words(rng.int(2, 8))}${rng.pick(ENDERS)}`;
  if (roll < 0.14) return `It was ${rng.pick(['3.30', '10.5', '4.', 'v1.2'])} ${words(rng.int(2, 8))}${rng.pick(ENDERS)}`;
  if (roll < 0.28) return `“${words(rng.int(2, 10))}${rng.pick([',', '.', '!', '?'])}” ${rng.chance(0.5) ? rng.pick(NAMES) + ' ' : ''}${rng.pick(VERBS)}${rng.pick(ENDERS)}`;
  if (roll < 0.34) return `"${rng.pick(CONTRACTIONS)} ${words(rng.int(1, 5))}${rng.pick(['.', '?', '!'])}" ${rng.pick(NAMES)} ${rng.pick(VERBS)}${rng.pick(ENDERS)}`;
  if (roll < 0.4) return `${words(rng.int(1, 6))} ${rng.pick(STOCK)} ${words(rng.int(0, 5))}${rng.pick(ENDERS)}`;
  if (roll < 0.44) return rng.pick(ORNATE);
  return `${words(sentenceLength())}${rng.pick(ENDERS)}`;
}

function paragraph(): string {
  const out: string[] = [];
  const count = rng.int(1, rng.chance(0.15) ? 14 : 5);
  for (let i = 0; i < count; i++) out.push(sentence());
  return out.join(rng.pick([' ', ' ', ' ', '  ', '\n', ' \t ']));
}

function markdownBlock(): string {
  const roll = rng.next();
  if (roll < 0.06) return ['```system', 'HP 10', '| a | b |', '```'].join(rng.pick(['\n', '\r\n']));
  if (roll < 0.1) return ['```', words(4), 'kept line', '```'].join('\n');
  if (roll < 0.13) return ['~~~text', words(3), '~~~~'].join('\n');
  if (roll < 0.15) return ['```js', words(3), 'no close'].join('\n');
  if (roll < 0.18) return ['| Name | Value |', '| --- | :---: |', '| a | 1 |', '| b | 2 |', words(3)].join('\n');
  if (roll < 0.2) return ['a | b', '--|--', 'c | d', '', 'after'].join('\n');
  if (roll < 0.22) return `# ${words(3)}`;
  if (roll < 0.24) return `> ${words(5)}.`;
  if (roll < 0.26) return ['- one', '- two', '* three', '1. four', '1) five'].join('\n');
  if (roll < 0.28) return '---';
  if (roll < 0.3) return '    indented code ' + words(2);
  return paragraph();
}

function chapterBody(blocks: number, markdown = true): string {
  const out: string[] = [];
  for (let i = 0; i < blocks; i++) out.push(markdown ? markdownBlock() : paragraph());
  return out.join(rng.pick(['\n\n', '\n\n', '\n', '\r\n\r\n', '\n\n\n']));
}

function nasty(maxPieces: number): string {
  const count = rng.int(0, maxPieces);
  let out = '';
  for (let i = 0; i < count; i++) out += rng.chance(0.3) ? rng.pick(WORDS) : rng.pick(NASTY);
  return out;
}

function textInput(): string {
  const roll = rng.next();
  if (roll < 0.3) return nasty(12);
  if (roll < 0.6) return paragraph();
  if (roll < 0.8) return chapterBody(rng.int(1, 3), false);
  return nasty(40);
}

const HANDWRITTEN_TEXT = [
  '', ' ', '\n', '   ﻿', 'one', '  one  ', 'one two', 'one\ttwo\nthree\r\nfour five six　seven﻿eight', 'a᠎b', 'a​b', 'a\u0085b', '😀 😀', 'é é',
  'Hello. World! Really? Yes... maybe', 'No end', 'One.Two. Three', 'Wait... what?! no', '...', '. . .', '!!!', 'a.', '.a', 'a. ', ' a .', '"Hi." He left.', 'He said "go." Then left.', 'end.”  Next',
  'Dr. Smith went. Mrs. Jones stayed.', 'Costs 3.30 today. Then 4.', 'x'.repeat(40), 'ends with abbreviation etc.', 'J. R. R. Tolkien wrote it.', 'A. B', 'a.b.c.d', 'TOKENS: ſtone İstanbul K',
];

const proseOnlyCases: [string, string, string | null][] = [];
const proseInputs: string[] = [
  '',
  '```',
  '```\n',
  '```\ncode',
  '```\ncode\n```',
  '```system\nHP 10\n```\ntext',
  '``` SYSTEM panel\nx\n```',
  '```systems\nx\n```',
  '```system\nunclosed',
  '~~~\nkept\n~~~~~',
  '~~~\nkept\n~~',
  '~~~\ntilde\n```\n~~~',
  '````\ninner ```\n````',
  '```a`b\nx\n```',
  '   ```\nindented fence\n   ```',
  '    ```\nfour spaces\n```',
  '| a | b |\n| - | - |\n| 1 | 2 |\nafter',
  '| a | b |\n| - | - |\n| 1 | 2 |\n\nafter',
  '| a | b |\n| - |\n| 1 |',
  'a | b\n:-: | -:\n1 | 2\n# heading\nrest',
  '|a|b|\n|---|---|\n|x\\|y|z|\ntext',
  '||\n||',
  '|\n|',
  'x | y\n--- | ---\nrow\n- item\ntext',
  'x | y\n--- | ---\nrow\n    indented\ntext',
  'x | y\n--- | ---\nrow\n***\ntext',
  'x | y\n--- | ---\nrow\n> quote\ntext',
  'x | y\n--- | ---\nrow\n```\ncode\n```',
  'line one\r\nline two\rline three\nline four',
  '```\r\ncrlf\r\n```\r\ntail',
  'a b c',
  '``` x\n```',
  '```system x\ny\n```',
  '~~~~~ info\nbody\n~~~~~   \nnext',
  '```\nbody\n```  ',
  '```\nbody\n``` x',
  '1. one\n2) two',
  'x | y\n---|---\n1. a',
  'x | y\n---|---\n+ a',
  'x | y\n---|---\n+a',
  'x | y\n---|---\n___\nafter',
  'x | y\n---|---\n- - -\nafter',
  'x | y\n---|---\n* * *\nafter',
  'x | y\n---|---\n\tTab\nafter',
  'x | y\n---|---\n#hash\nafter',
  'x | y\n---|---\n####### seven\nafter',
  'x | y\n---|---\n###### six\nafter',
  'x | y\n---|---\n   > q\nafter',
  'a | b\n :--- | ---: \nz | z',
  'a | b\nxx | yy',
  'a | b\n--- | --- | ---',
  'a | b \\|\n--|--|\nafter',
  'a | b \\|\n--|--\nafter',
  'a | b\n--|--\nc | d \\|\nafter',
  '````\n```\nkept\n````\nafter',
  '````\n```\nunclosed by three\n```',
  '~~~~~\n~~~\nkept\n~~~~~\nafter',
  '~~~~~\n~~~\n~~~~\nrest',
  'head\n| a |\n| - |\n',
  '😀 | é\n--- | ---\n😀 | é',
];
for (const input of proseInputs) proseOnlyCases.push([input, prose.proseOnly(input), prose.splitChapterProse(input).unclosedFence]);
for (let i = 0; i < 60; i++) {
  const input = chapterBody(rng.int(1, 7));
  proseOnlyCases.push([input, prose.proseOnly(input), prose.splitChapterProse(input).unclosedFence]);
}
for (let i = 0; i < 20; i++) {
  const input = nasty(30);
  proseOnlyCases.push([input, prose.proseOnly(input), prose.splitChapterProse(input).unclosedFence]);
}

function bodies(count: number): string[] {
  const out = [...HANDWRITTEN_TEXT];
  for (let i = 0; i < count; i++) out.push(textInput());
  return out;
}

const textInputs = bodies(40);
const countWordsCases = textInputs.map((text) => [text, metrics.countWords(text)]);
const sentenceSplitCases = textInputs.map((text) => [text, metrics.splitSentences(text)]);
const sentenceLengthCases = textInputs.map((text) => [text, metrics.computeSentenceLengthMetrics(text)]);
const tokenizeCases = textInputs.slice(0, 80).map((text) => [text, metrics.tokenizeWords(text)]);
const paragraphCases = textInputs.slice(0, 80).map((text) => [text, metrics.splitProseParagraphs(text)]);

const syllableWords = [
  '', 'a', 'the', 'cake', 'make', 'house', 'jumped', 'wanted', 'yes', 'yellow', 'rhythm', 'queue', 'eyes', 'toes', 'beautiful', 'Cities', 'sixteen', 'ſtone', 'İstanbul', 'K', 'Kelvin',
  "don't", 'e-mail', '1234', 'a1b2c3', 'yyyy', 'aeiou', 'aeiouy', 'baaad', 'table', 'little', 'apple', 'ties', 'tied', 'fades', 'lyes', 'ayes', 'ale', 'ole', 'ye', 'yed', 'ed', 'es', 'bees', 'Naïve', 'café', '😀', 'ß', 'ΣΑΣ',
];
for (let i = 0; i < 150; i++) {
  let word = '';
  const length = rng.int(0, 12);
  for (let j = 0; j < length; j++) word += rng.pick(['a', 'e', 'i', 'o', 'u', 'y', 'b', 'c', 'd', 'l', 's', 't', 'r', 'n', 'E', 'Y', "'", '-', 'é']);
  syllableWords.push(word);
}
const syllableCases = syllableWords.map((word) => [word, metrics.countSyllables(word)]);

const ornateSources: [string, string, string][] = [
  ['global dot', '\\.', 'g'],
  ['global lower', '[a-z]+', 'g'],
  ['word group', '(\\bstone\\b)', 'i'],
  ['sticky-free caret', '^The', ''],
];
const readabilityCases: unknown[] = [];
for (const text of [...textInputs, ...Array.from({ length: 12 }, () => chapterBody(rng.int(2, 6)))]) {
  readabilityCases.push([text, null, metrics.computeReadabilityMetrics(text)]);
}
for (const text of textInputs.slice(20, 40)) {
  const patterns = ornateSources.map(([label, source, flags]) => ({ label, pattern: new RegExp(source, flags) }));
  readabilityCases.push([text, ornateSources, metrics.computeReadabilityMetrics(text, patterns)]);
}

const ngramBank = [
  'she walked across the quiet river toward the old harbour',
  'the lamp light fell across the stone floor and the bread',
  "he couldn't help but remember the letter from the morning",
  'every night the rain returned to the window above the door',
];
function ngramText(): string {
  const out: string[] = [];
  const count = rng.int(0, 7);
  for (let i = 0; i < count; i++) out.push(rng.chance(0.55) ? rng.pick(ngramBank) + rng.pick(['.', ',', '!', '', ' -- ']) : words(rng.int(1, 9)) + '.');
  return out.join(' ');
}
const withinCases: unknown[] = [];
const crossCases: unknown[] = [];
for (let i = 0; i < 60; i++) {
  const body = ngramText();
  withinCases.push([body, null, metrics.computeWithinChapterRepeatedNgrams(body)]);
  const priors = Array.from({ length: rng.int(0, 3) }, ngramText);
  crossCases.push([body, priors, null, metrics.computeCrossChapterRepeatedNgrams(body, priors)]);
}
for (const sizes of [[1], [2, 3], [5, 5], [4, 12], []]) {
  const body = ngramText() + ' ' + ngramBank[0] + ' ' + ngramBank[0];
  const priors = [ngramText(), ngramBank[0]!];
  withinCases.push([body, sizes, metrics.computeWithinChapterRepeatedNgrams(body, sizes)]);
  crossCases.push([body, priors, sizes, metrics.computeCrossChapterRepeatedNgrams(body, priors, sizes)]);
}
const ngramsCases: unknown[] = [];
for (const tokens of [[], ['a'], ['a', 'b'], ['a', 'b', 'a', 'b', 'a'], ['x', 'y', 'z', 'x', 'y', 'z', 'x']]) {
  for (const n of [1, 2, 3, 5]) ngramsCases.push([tokens, n, metrics.ngrams(tokens, n)]);
}

const stockSources: [string, string, string][] = [
  ['plain global', 'eyes', 'gi'],
  ['plain non-global', 'eyes', 'i'],
  ['grouped non-global', '(eyes)( widened)?', 'i'],
  ['grouped global', '(eyes)( widened)?', 'gi'],
  ['never', 'zzzzqq', 'g'],
  ['empty global', '', 'g'],
  ['empty non-global', '', ''],
];
const stockCases: unknown[] = [];
for (let i = 0; i < 70; i++) {
  const body = [paragraph(), rng.pick(STOCK), rng.pick(STOCK), rng.pick(STOCK).toUpperCase(), paragraph()].slice(0, rng.int(1, 5)).join(' ');
  stockCases.push([body, null, metrics.computeStockPhraseCounts(body)]);
}
for (let i = 0; i < 20; i++) {
  const body = [rng.pick(STOCK), 'eyes widened wide eyes', paragraph()].join(' ');
  const phrases = stockSources.map(([label, source, flags]) => ({ label, pattern: new RegExp(source, flags) }));
  stockCases.push([body, stockSources, metrics.computeStockPhraseCounts(body, phrases)]);
}
for (const body of ['', 'EYES WIDENED', 'eyes widened', 'eyes  widened', 'clenched her fist', 'clenched his fists', 'Time Seemed To Stand Still', 'a mixture of ſtone and K', 'ghost of a smile ghost of a smile']) {
  stockCases.push([body, null, metrics.computeStockPhraseCounts(body)]);
}

const dialogueCases: unknown[] = [];
const dialogueInputs = [
  ...textInputs,
  '“Go,” said Mira.',
  '“Go,” Mira said.',
  '"Go", asked Old Ben',
  '"Go" SAID',
  '“Go,”   \n  whispered the wind',
  '“Go,” Mira Voss growled. “No,” he added. "Yes," laughed Tomas.',
  '“Go,”saidx',
  '“Go,” mira said',
  '“Go,” Mira said',
  '“Go,” Mira Ann Lee said',
  '”said',
  '"asked" "said"',
  '“Go,” ſaid',
  '“Go,” Kasked',
  '“x”   said',
  '“x” muttered',
  ...Array.from({ length: 15 }, () => chapterBody(rng.int(1, 4), false)),
];
for (const body of dialogueInputs) dialogueCases.push([body, metrics.computeDialogueTagMetrics(body)]);

const contractionPairsCustom: [string, string][][] = [
  [["don't", 'do not']],
  [['a.b', 'c|d']],
  [["it's", 'it is'], ["'tis", 'it is']],
  [['(', 'x']],
  [['x', '[']],
  [],
];
const contractionCases: unknown[] = [];
const contractionInputs = [
  ...textInputs.slice(0, 50),
  '“I don’t know,” she said. “I do not care.”',
  '"it\'s fine" and "it is fine" and it\'s outside',
  '“I\'M here” “I AM here” “i am here”',
  '“we’ll go” “we will go” “WE\'LL”',
  '“cannot” “can\'t” “can’t” “cant”',
  '“don\'t”',
  'no quotes don\'t do not',
  '“unclosed don\'t',
  '“a” don\'t “b”',
  '“don\'t do not',
  '"don\'t" “don\'t”',
  '“ſtone it\'s K’s”',
  '“let\'s” “let us” “lets”',
  '“x\ndon\'t\ny”',
  ...Array.from({ length: 40 }, () => {
    const parts: string[] = [];
    const count = rng.int(1, 5);
    for (let i = 0; i < count; i++) parts.push(rng.chance(0.7) ? `“${rng.pick(CONTRACTIONS)} ${words(rng.int(0, 3))}”` : `${rng.pick(CONTRACTIONS)} ${words(2)}`);
    return parts.join(' ');
  }),
];
for (const body of contractionInputs) contractionCases.push([body, null, metrics.computeDialogueContractionRate(body)]);
for (const pairs of contractionPairsCustom) {
  for (const body of ['“don\'t do not it\'s it is a.b c|d”', '“x [ ( don’t”']) {
    let expected: unknown;
    try {
      expected = metrics.computeDialogueContractionRate(body, pairs);
    } catch {
      expected = 'throws';
    }
    contractionCases.push([body, pairs, expected]);
  }
}

const endingCases: unknown[] = [];
for (let i = 0; i < 70; i++) {
  const entries = Array.from({ length: rng.int(0, 12) }, (_, index) => ({ chapter: index + 1, hookType: rng.chance(0.2) ? null : rng.pick(HOOKS) }));
  endingCases.push([entries, metrics.computeEndingModeDistribution(entries)]);
}
for (const hookTypes of [[], [null], [''], ['a', 'a', 'b'], ['b', '2', 'a', '1', '10', '1'], ['é', 'é', 'é'], ['4294967295', '4294967294', '0', '00'], ['x', '', null, 'x']]) {
  const entries = hookTypes.map((hookType, index) => ({ chapter: index, hookType }));
  endingCases.push([entries, metrics.computeEndingModeDistribution(entries)]);
}

const targetSources: unknown[] = [undefined, null, {}, { wordTargetMin: 1000 }, { wordTargetMax: 3000 }, { wordTargetMin: 1000, wordTargetMax: 3000 }, { wordTargetMin: null, wordTargetMax: null },
  { wordTargetMin: 0, wordTargetMax: 0 }, { wordTargetMin: 1, wordTargetMax: 2 }, { wordTargetMin: -3, wordTargetMax: 2 }, { wordTargetMin: 1.25, wordTargetMax: 2.5 }, { wordTargetMin: 1999, wordTargetMax: 2000 },
  { wordTargetMin: 5, wordTargetMax: 2 }, { wordTargetMin: -2, wordTargetMax: -1 }, { wordTargetMin: 0.1, wordTargetMax: 0.2 }];
const targetCases = targetSources.map((source) => [source === undefined ? 'undefined' : source, metrics.resolveWordTarget(source as never)]);

const wordCountCases: unknown[] = [];
for (let i = 0; i < 30; i++) {
  const chapters = Array.from({ length: rng.int(0, 6) }, (_, index) => ({ chapter: index + 1 + rng.int(0, 2), body: chapterBody(rng.int(0, 4)) }));
  const target = rng.chance(0.5) ? null : { min: rng.int(5, 80), max: rng.int(60, 300), aim: 0 };
  wordCountCases.push([chapters, target, metrics.computeWordCountDistribution(chapters, (target ?? undefined) as never)]);
}
for (let i = 0; i < 12; i++) {
  const chapters = Array.from({ length: rng.int(1, 5) }, (_, index) => ({ chapter: index + 1, body: words(rng.int(0, 12)) }));
  const target = { min: rng.int(1, 6), max: rng.int(4, 10), aim: 0 };
  wordCountCases.push([chapters, target, metrics.computeWordCountDistribution(chapters, target)]);
}

const reportCases: unknown[] = [];
for (let i = 0; i < 6; i++) {
  const count = rng.int(1, 3);
  const chapters = Array.from({ length: count }, (_, index) => ({ chapter: index + 1, body: chapterBody(rng.int(1, 5)), ...(rng.chance(0.7) ? { hookType: rng.chance(0.8) ? rng.pick(HOOKS) : null } : {}) }));
  const priorEntries: [number, string[]][] = [];
  for (let c = 1; c <= count; c++) if (rng.chance(0.6)) priorEntries.push([c, Array.from({ length: rng.int(0, 2) }, () => ngramBank.join(' ') + ' ' + chapterBody(1, false))]);
  const target = rng.chance(0.4) ? null : { min: rng.int(10, 100), max: rng.int(100, 400), aim: 0 };
  const report = metrics.computeDeterministicMetricsReport(chapters, new Map(priorEntries), (target ?? undefined) as never);
  reportCases.push([chapters, priorEntries, target, report]);
}
for (const body of ['', ngramBank.join(' ') + ngramBank.join(' '), '```system\nHP\n```\n“I don’t,” said Mira. Her eyes widened.']) {
  const chapters = [{ chapter: 7, body, hookType: 'cliffhanger' }];
  const priorEntries: [number, string[]][] = [[7, [ngramBank.join(' ')]]];
  reportCases.push([chapters, priorEntries, null, metrics.computeDeterministicMetricsReport(chapters, new Map(priorEntries))]);
}
const chapterCases: unknown[] = [];
for (let i = 0; i < 5; i++) {
  const input = { chapter: i, body: chapterBody(rng.int(1, 5)), ...(rng.chance(0.5) ? { hookType: rng.pick(HOOKS) } : {}) };
  const priors = [ngramBank[1]! + ' ' + chapterBody(1, false)].slice(0, rng.int(0, 1));
  chapterCases.push([input, priors, metrics.computeChapterMetrics(input, priors)]);
}

const here = dirname(fileURLToPath(import.meta.url));
function write(name: string, cases: unknown[]): void {
  writeFileSync(join(here, name), JSON.stringify(cases) + '\n');
}

write('prose.json', proseOnlyCases);
write('sentences.json', [countWordsCases, sentenceSplitCases, sentenceLengthCases, paragraphCases]);
write('readability.json', [readabilityCases, syllableCases]);
write('ngrams.json', [tokenizeCases, ngramsCases, withinCases, crossCases]);
write('phrases.json', [stockCases, dialogueCases, contractionCases]);
write('reports.json', [endingCases, targetCases, wordCountCases, chapterCases, reportCases]);
