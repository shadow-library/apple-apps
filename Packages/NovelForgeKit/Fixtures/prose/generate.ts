import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');

const paragraphs = await import(join(platformRepo, 'packages/sdk/src/prose-paragraphs.ts'));
const anchor = await import(join(platformRepo, 'apps/novel-forge-server/src/modules/generation/passage-anchor.ts'));
const outDir = dirname(fileURLToPath(import.meta.url));

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

const LINES = [
  'The lamp burned low.', 'She walked on.', '😀 emoji line', 'é combining', '  indented two', '   indented three', ' ', '　lead ideographic', 'trail ',
  'café \u{1d11e} clef', 'a b', '', '', '', ' ', '\t', '  \t ',
  '***', '* * *', '*  *  *', '**', '- - -', '---', '----', '___', '_ _ _', ' ***', '   ---', '    ***', '-- -',
  '# Heading', '#hash', '###### six', '####### seven', '##', '#', '   # indented', '    # code',
  '```', '```js', '``` a ```', '````', '~~~', '~~~~ x', '~~', '  ```', '    ```', '`` `',
  '> quote', '>quote', '   > deep', '    > code', '>',
  '- item', '* item', '+ item', '-', '- ', '-item', '1. one', '1) one', '2. two', '10. ten', '1234567890. too long', '123456789. ok', '   - nested', '    - code-ish',
  '    code', '\tcode', '  \tmixed', '        deeper',
  '| a | b |', '|---|---|', '| --- | :-: |', 'a | b', '--- | ---', ':-:|:-:', '| a \\| b |', '|a|b|c|', '| x \\|', '|', '||', '| a |', '|-|', '| :--- | ---: |',
  '===', '==', '  ==  ', '= =', '-',
];

const SEPARATORS = ['\n', '\n', '\n', '\r\n', '\r'];

function randomText(rng: Rng): string {
  const count = rng.int(1, 14);
  let text = rng.chance(0.1) ? rng.pick(SEPARATORS) : '';
  for (let index = 0; index < count; index++) {
    text += rng.pick(LINES);
    if (index < count - 1) text += rng.pick(SEPARATORS);
  }
  if (rng.chance(0.15)) text += rng.pick(SEPARATORS);
  return text;
}

const HAND_WRITTEN = [
  '', '\n', '\r\n', '\r', '\n\n\n', ' ', 'one', 'one\ntwo\n\nthree', 'one\r\ntwo\r\n\r\nthree\rfour', ' ', ' \n ', 'x \n \ny',
  '```\ncode\n\nmore', '```\ncode\n```\nafter', '~~~\na\n~~~~\nb\n~~~', '````\n```\n````', '```\n```', '```', 'a\n```\nb',
  '| a | b |\n|---|---|\n| 1 | 2 |\n\nnext', '| a | b |\n|---|---|\n- item', 'a | b\n--- | ---\nc | d\n    code', '| a |\n|---|---|', 'a|b\n---|---|c',
  '- a\n\n- b\n\n  c\n\nafter', '- a\nlazy\n\nnext', '- a\n\nlazy\n---\nafter', '1. a\n2. b\n> q', '> q\nlazy\n- item\nafter', '> q\n> r\n\n> s',
  'text\n===\nmore', 'text\n---\nmore', 'text\n- list\n', 'text\n2. not a list', 'text\n1. a list', 'text\n# head\nmore', 'text\n***\nmore', 'text\n> q',
  '    code\n\n    more\n\ntext', '    code\ntext', '\n\n  lead\ntrail  \n\n',
  '😀 first\n😀 second', 'é\n\né', ' \nline ', 'a b\n\nc', '﻿bom start\n\nnext', ' em space\n\n ',
];

function paragraphCases(): unknown[] {
  const rng = createRng(0x0d07);
  const texts = [...HAND_WRITTEN];
  for (let index = 0; index < 1100; index++) texts.push(randomText(rng));
  return texts.map(text => {
    const found = paragraphs.proseParagraphs(text) as { start: number; end: number }[];
    const offsets = new Set<number>([-5, -1, 0, 1, text.length - 1, text.length, text.length + 1, text.length + 50]);
    for (const { start, end } of found) for (const offset of [start - 1, start, start + 1, end - 1, end, end + 1]) offsets.add(offset);
    const numbers = [...offsets].sort((a, b) => a - b).map(offset => [offset, paragraphs.paragraphAt(text, offset)]);
    return [text, found.map(({ start, end }) => [start, end]), numbers];
  });
}

const WORDS = ['lamp', 'the', 'heir', 'rain', 'café', 'é', '😀', '\u{1d11e}', ' ', '　', '﻿', '\n', '\r\n', '  ', '\t', '.', ',', 'x', 'a b'];

function randomBody(rng: Rng, length: number): string {
  let text = '';
  for (let index = 0; index < length; index++) text += (index > 0 && rng.chance(0.7) ? ' ' : '') + rng.pick(WORDS);
  return text;
}

const wellFormed = (text: string): boolean => text.isWellFormed();

interface AnchorShape {
  start: number;
  end: number;
  passageHash: string;
  passage: string;
  contextBefore: string;
  contextAfter: string;
}

function makeAnchor(body: string, start: number, end: number): AnchorShape | null {
  const passage = body.slice(start, end);
  const context = anchor.anchorContext(body, start, end);
  if (![passage, context.contextBefore, context.contextAfter].every(wellFormed)) return null;
  return { start, end, passageHash: anchor.passageHash(passage), passage, ...context };
}

function pack(shape: AnchorShape): unknown[] {
  return [shape.start, shape.end, shape.passageHash, shape.passage, shape.contextBefore, shape.contextAfter];
}

function locationOf(body: string, shape: AnchorShape): unknown[] {
  const found = anchor.locatePassage(body, shape);
  return [found.freshness, found.start, found.end];
}

function mutate(rng: Rng, body: string, shape: AnchorShape): [string, AnchorShape][] {
  const out: [string, AnchorShape][] = [[body, shape]];
  const insert = rng.pick(['moved ', 'x', '😀', '\n\n', '']);
  out.push([insert + body, shape]);
  out.push([body + insert, shape]);
  const middle = shape.start + Math.floor((shape.end - shape.start) / 2);
  out.push([body.slice(0, middle) + insert + body.slice(middle), shape]);
  out.push([body.slice(0, shape.start) + insert + body.slice(shape.start), shape]);
  out.push([body.slice(0, shape.end) + insert + body.slice(shape.end), shape]);
  const needle = shape.contextBefore + shape.passage + shape.contextAfter;
  out.push([body + '\n' + needle, shape]);
  out.push([needle + '\n' + body, shape]);
  out.push([body.replace(shape.passage, 'changed'), shape]);
  out.push([body, { ...shape, passageHash: shape.passageHash.replace(/^./, c => (c === '0' ? '1' : '0')) }]);
  out.push([body, { ...shape, passage: shape.passage + '!' }]);
  out.push([body, { ...shape, contextBefore: shape.contextBefore + 'q' }]);
  out.push([body, { ...shape, contextAfter: 'q' + shape.contextAfter }]);
  out.push([insert + body, { ...shape, start: shape.start + insert.length, end: shape.end + insert.length }]);
  out.push([body, { ...shape, start: shape.start + 1 }]);
  out.push([body, { ...shape, end: shape.end + 1 }]);
  out.push([body, { ...shape, start: -3 }]);
  out.push([body, { ...shape, start: shape.end, end: shape.start }]);
  out.push([body, { ...shape, start: body.length + 4, end: body.length + 9 }]);
  return out;
}

function pushLocated(into: unknown[], body: string, shape: AnchorShape): void {
  if (![body, shape.passage, shape.contextBefore, shape.contextAfter].every(wellFormed)) return;
  into.push([body, pack(shape), locationOf(body, shape)]);
}

function anchorCases(): unknown {
  const rng = createRng(0x0a01);
  const located: unknown[] = [];
  const contexts: unknown[] = [];
  for (let index = 0; index < 70; index++) {
    const body = randomBody(rng, rng.int(0, 22));
    const start = rng.int(0, body.length);
    const end = rng.chance(0.08) ? rng.int(0, body.length) : rng.int(start, Math.min(body.length, start + rng.int(0, 60)));
    const shape = makeAnchor(body, start, end);
    if (!shape) continue;
    for (const [candidate, candidateAnchor] of mutate(rng, body, shape)) pushLocated(located, candidate, candidateAnchor);
  }
  for (const [body, start, end] of [
    ['', 0, 0], ['', 5, 9], ['abc', 1, 1], ['abc', 0, 3], ['abcabc', 0, 3], ['abcabc', 3, 6], ['aaaa', 1, 2], ['aaaa', 0, 0], ['a😀b', 1, 3], ['a😀b', 0, 4], ['😀😀', 2, 4],
  ] as [string, number, number][]) {
    const shape = makeAnchor(body, start, end);
    if (!shape) continue;
    for (const [candidate, candidateAnchor] of mutate(rng, body, shape)) pushLocated(located, candidate, candidateAnchor);
  }
  const midPairBody = 'x😀y😀z😀';
  for (const start of [0, 1, 2, 3, 4, 5, 6]) {
    for (const end of [3, 4, 5, 6, 7, 8, 9]) {
      const passage = midPairBody.slice(start, end);
      const shape = {
        start,
        end,
        passageHash: anchor.passageHash(passage),
        passage: passage.isWellFormed() ? passage : '',
        contextBefore: '',
        contextAfter: '',
      };
      pushLocated(located, midPairBody, shape);
    }
  }
  for (let index = 0; index < 250; index++) {
    const body = randomBody(rng, rng.int(0, 30));
    const start = rng.int(-40, body.length + 40);
    const end = rng.int(-40, body.length + 40);
    const context = anchor.anchorContext(body, start, end);
    if (wellFormed(context.contextBefore) && wellFormed(context.contextAfter)) contexts.push([body, start, end, context.contextBefore, context.contextAfter]);
  }
  return { located, contexts };
}

function hashAndReplaceCases(): unknown {
  const rng = createRng(0x0a02);
  const hashes = ['', 'a', 'abc', 'é', 'é', '😀', ' ', 'line\r\nbreak', 'x'.repeat(6000), randomBody(rng, 30)].map(text => [text, anchor.passageHash(text)]);
  const padding = ['', ' ', '\n', '\n\n', '\t', '\r\n', ' ', ' ', '　', '﻿', '​', '\u0085', '᠎', ' \n '];
  const fits: unknown[] = [];
  for (const lead of padding) for (const trail of padding) for (const core of ['word', '', 'two words']) {
    for (const replacement of ['new', ' new ', '\n\nnew\n', '', '  ', ' x ', 'é']) fits.push([lead + core + trail, replacement, anchor.fitReplacement(lead + core + trail, replacement)]);
  }
  const replaces: unknown[] = [];
  for (let index = 0; index < 300; index++) {
    const body = randomBody(rng, rng.int(0, 20));
    const start = rng.int(-10, body.length + 10);
    const end = rng.int(-10, body.length + 10);
    const replacement = rng.pick(['', 'new', '😀', '\n', 'é']);
    const result = anchor.replacePassage(body, { start, end }, replacement);
    if (wellFormed(result)) replaces.push([body, start, end, replacement, result]);
  }
  return { hashes, fits, replaces };
}

function write(name: string, value: { [key: string]: unknown[] | unknown }): void {
  const entries = Object.entries(value).map(([key, entry]) => `${JSON.stringify(key)}:${Array.isArray(entry) ? `[\n${entry.map(item => JSON.stringify(item)).join(',\n')}\n]` : JSON.stringify(entry)}`);
  writeFileSync(join(outDir, name), `{\n${entries.join(',\n')}\n}\n`);
}

write('paragraphs.json', { cases: paragraphCases() });
write('anchor.json', anchorCases() as never);
write('anchor-text.json', hashAndReplaceCases() as never);
