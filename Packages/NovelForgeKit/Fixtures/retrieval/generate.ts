import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');
const src = join(platformRepo, 'apps/novel-forge-server/src');
const outDir = dirname(fileURLToPath(import.meta.url));

const chunker = await import(join(src, 'modules/ai/retrieval/chunker.ts'));

interface Rng {
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
  const int = (min: number, max: number): number => min + Math.floor(next() * (max - min + 1));
  return { int, chance: p => next() < p, pick: items => items[Math.floor(next() * items.length)] as never };
}

const units = (text: string): number[] => Array.from({ length: text.length }, (_, index) => text.charCodeAt(index));
const repeat = <T>(count: number, make: () => T): T[] => Array.from({ length: count }, make);

const HAND: [string, number | null][] = [
  ['', null],
  ['   ', null],
  ['\n\n', null],
  ['\n\n\n\n', 5],
  ['a', 1],
  ['ab', 1],
  ['abc', 1],
  ['Hello world.', 5],
  ['One. Two. Three.', 3],
  ['First paragraph.\n\nSecond paragraph.\n\n\nThird.', 10],
  ['First paragraph.\n\nSecond paragraph.\n\n\nThird.', 20],
  ['First paragraph.\n\nSecond paragraph.\n\n\nThird.', 2000],
  ['Ten chars. and then the rest of the line continues on and on', 10],
  ['Ten chars. and then the rest of the line continues on and on', 11],
  ['Ten chars. and then the rest of the line continues on and on', 9],
  ['Wow! Really? Yes. And then more text keeps on going and going', 8],
  ['No sentence end in this whole long paragraph at all whatsoever', 6],
  ['Ends.  Double space after the stop and more words follow here', 7],
  ['Stop.\tTab after the stop is not a sentence end for the chunker', 7],
  ['Quote." Then more words follow the quoted stop for a while', 7],
  ['😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀', 3],
  ['a😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀😀', 3],
  ['Tide. 😀😀😀😀😀😀😀😀😀😀😀😀😀😀', 4],
  ['これは長い文章です。そしてもっと長い文章が続きますがどこにも句読点はありません', 6],
  ['潮が満ちる。 そして引く！ また満ちる？ 終わりなく続く海の話です', 5],
  ['# Title\n\n- item one. - item two. **bold** text follows here and on\n\n> quote', 12],
  ['```\ncode. block\n```\n\nAfter the fence comes plain prose again.', 9],
  ['Line one\r\n\r\nLine two\r\n\r\nLine three', 4],
  ['para\n \npara with a space line between', 5],
  ['éééééééé tail', 3],
  ['Tide rises. Over the﻿ flats. and the　sea', 6],
  ['A. B. C. D. E. F. G. H. I. J. K. L. M. N. O. P.', 4],
  ['short\n\n' + 'x'.repeat(30) + '\n\nshort again', 10],
  ['x'.repeat(21) + '\n\n' + 'y'.repeat(5), 10],
  ['x'.repeat(20) + '\n\n' + 'y'.repeat(5), 10],
];

const WORDS = [
  'the', 'tide', 'keeper', 'Mara', 'salt', 'flats', 'lantern', 'harbour', 'bell', 'rang', 'over', 'water', 'and', 'night', 'café', 'naïve', 'Ærø',
  '物語', '潮', '海の話', '😀', '🌊', 'é', 'İstanbul', 'straße', '"quoted"', "o'clock", '(aside)', '[note]', '**bold**', '`code`', '#tag',
];
const STOPS = ['. ', '! ', '? ', '.', '!', '?', ', ', '; ', ' — ', ' ', ' ', ' ', ' ', '。', '！', '.\n', '\n'];
const BREAKS = ['\n\n', '\n\n\n', '\n \n', '\n\n\n\n', '\r\n\r\n'];

function sentence(rng: Rng, words: number): string {
  return repeat(words, () => rng.pick(WORDS)).join(' ') + rng.pick(STOPS);
}

function paragraph(rng: Rng, sentences: number, wordsPer: number): string {
  return repeat(sentences, () => sentence(rng, rng.int(1, wordsPer))).join('').trimEnd();
}

function document(rng: Rng, paragraphs: number, sentences: number, wordsPer: number): string {
  return repeat(paragraphs, () => paragraph(rng, rng.int(1, sentences), wordsPer)).join(rng.pick(BREAKS));
}

const randomSmall: [string, number | null][] = (() => {
  const rng = createRng(0xc4a7c);
  return repeat(400, (): [string, number | null] => [document(rng, rng.int(0, 5), 4, 6), rng.int(1, 40)]);
})();

const longCases: [string, number | null][] = (() => {
  const rng = createRng(0x10e6);
  const chapter = repeat(40, () => paragraph(rng, rng.int(2, 9), 14)).join('\n\n');
  const wall = repeat(1400, () => rng.pick(WORDS)).join(' ');
  const emojiWall = '🌊'.repeat(1200) + ' tail. ' + '😀'.repeat(2500);
  const cjk = repeat(2000, () => rng.pick(['物語', '潮が満ちる', '海の話', '。', '、'])).join('');
  const sentences = repeat(400, () => sentence(rng, rng.int(3, 12))).join('');
  const mixed = [chapter.slice(0, 3000), wall, sentences.slice(0, 2500), cjk, emojiWall].join('\n\n');
  return [
    [chapter, null],
    [wall, null],
    [emojiWall, null],
    [cjk, null],
    [sentences, null],
    [mixed, null],
    [sentences, 500],
    [mixed, 700],
  ];
})();

const cases = [...HAND, ...randomSmall, ...longCases].map(([text, target]) => {
  const chunks: { text: string; chunkIdx: number }[] = target === null ? chunker.chunkText(text) : chunker.chunkText(text, target);
  chunks.forEach((chunk, index) => {
    if (chunk.chunkIdx !== index) throw new Error(`chunk ${index} carries index ${chunk.chunkIdx}`);
  });
  return [text, target, chunks.map(chunk => units(chunk.text))];
});

writeFileSync(join(outDir, 'chunker.json'), JSON.stringify({ defaultTargetChars: 2000, cases }) + '\n');
process.exit(0);
