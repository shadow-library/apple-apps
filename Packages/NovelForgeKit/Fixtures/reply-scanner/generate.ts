import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');

const { ReplyStreamScanner } = (await import(join(platformRepo, 'apps/novel-forge-server/src/modules/ai/reply-stream-scanner.ts'))) as {
  ReplyStreamScanner: new () => {
    push(chunk: string): string;
    takeChangeSetElements(): unknown[];
    readonly replyFound: boolean;
  };
};

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

type Style = 'compact' | 'spaced' | 'wild';

interface Doc {
  kind: string;
  source: string;
  chunkings: Chunking[];
}

type Chunking = 'whole' | 'units' | 'small' | 'medium' | 'boundaries';

const JSON_WS = [' ', '\t', '\n', '\r'];
const JS_ONLY_WS = [' ', ' ', ' ', '﻿', '　', '\v', '\f'];

function ws(rng: Rng, style: Style): string {
  if (style === 'compact') return '';
  if (style === 'spaced') return rng.chance(0.5) ? ' ' : '';
  if (!rng.chance(0.4)) return '';
  let out = '';
  for (let i = rng.int(1, 2); i > 0; i--) out += rng.pick(JSON_WS);
  return out;
}

const WORDS = ['the', 'bell', 'rang', 'Mara', 'tide', 'ash', 'and', 'of', 'a', 'draft'];
const PUNCT = [',', '.', ';', ':', '!', '?', '-', "'", '(', ')', '#', '*', '_', '`', '{', '}', '[', ']', '{"', '"}', ']}', '},{'];

function hex4(rng: Rng, code: number): string {
  const digits = code.toString(16).padStart(4, '0');
  return rng.chance(0.5) ? digits : digits.toUpperCase();
}

function escapedUnit(rng: Rng, code: number): string {
  return '\\u' + hex4(rng, code);
}

function textAtom(rng: Rng, allowLone: boolean): string {
  const roll = rng.int(0, 30);
  switch (roll) {
    case 0:
    case 1:
    case 2:
    case 3:
    case 4:
    case 5:
      return rng.pick(WORDS) + ' ';
    case 6:
      return rng.pick(PUNCT);
    case 7:
      return '\\"';
    case 8:
      return '\\\\';
    case 9:
      return '\\/';
    case 10:
      return rng.pick(['\\b', '\\f', '\\n', '\\r', '\\t']);
    case 11:
      return escapedUnit(rng, rng.int(0x20, 0x7e));
    case 12:
      return escapedUnit(rng, rng.pick([0, 0x22, 0x5c, 0x1f, 0x7f, 0xe9, 0x2028, 0xfeff, 0xfffd, 0xffff]));
    case 13:
      return rng.pick(['é', 'ß', '日本語', 'ñ', 'Ω', ' ', '﻿', ' ']);
    case 14:
    case 15:
      return rng.pick(['😀', '𝒜', '🧙‍♀️', '𐍈', '\u{10ffff}', '\u{1f600}']);
    case 16:
    case 17:
    case 18:
      return pairEscape(rng);
    case 19:
      return allowLone ? escapedUnit(rng, rng.int(0xd800, 0xdbff)) : pairEscape(rng);
    case 20:
      return allowLone ? escapedUnit(rng, rng.int(0xdc00, 0xdfff)) : pairEscape(rng);
    case 21:
      return allowLone ? escapedUnit(rng, rng.int(0xd800, 0xdbff)) + escapedUnit(rng, rng.int(0x20, 0x7e)) : pairEscape(rng);
    case 22:
      return allowLone ? escapedUnit(rng, rng.int(0xdc00, 0xdfff)) + escapedUnit(rng, rng.int(0xd800, 0xdbff)) : pairEscape(rng);
    case 23:
      return allowLone ? escapedUnit(rng, rng.int(0xd800, 0xdbff)) + escapedUnit(rng, rng.int(0xd800, 0xdbff)) + escapedUnit(rng, rng.int(0xdc00, 0xdfff)) : pairEscape(rng);
    case 24:
      return rng.pick(['\n', '\t', '\r', '\u0001']);
    case 25:
      return '\\"reply\\":\\"x\\"';
    case 26:
      return '\\u00e9\\u00E9';
    case 27:
      return '/';
    case 28:
      return rng.pick(['\\u', '\\ud83d\\', '\\ude']).length > 0 ? 'x' : 'y';
    default:
      return String(rng.int(0, 999)) + ' ';
  }
}

function pairEscape(rng: Rng): string {
  const point = rng.int(0x10000, 0x10ffff);
  const offset = point - 0x10000;
  return escapedUnit(rng, 0xd800 + (offset >> 10)) + escapedUnit(rng, 0xdc00 + (offset & 0x3ff));
}

function text(rng: Rng, atoms: number, allowLone: boolean): string {
  let out = '';
  for (let i = 0; i < atoms; i++) out += textAtom(rng, allowLone);
  return out;
}

const NUMBERS = [
  '0',
  '-0',
  '1',
  '-1',
  '7',
  '42',
  '-42',
  '1234567890',
  '9007199254740991',
  '0.5',
  '-0.25',
  '10.0',
  '3.14159',
  '1e5',
  '1E5',
  '1e+5',
  '1e-5',
  '-1.5E+3',
  '2.5e-2',
  '0e0',
  '0.0e-0',
  '1e300',
];

function number(rng: Rng): string {
  return rng.pick(NUMBERS);
}

function keySource(rng: Rng): string {
  return '"' + rng.pick(['a', 'name', 'body', 'type', 'id', 'x1', 'tags', 'k\\u0065y', 'ke\\"y', 'reply', 'changeSet', 'op', 'é', 'replying', 'changeSets']) + '"';
}

function value(rng: Rng, style: Style, depth: number, allowLone: boolean): string {
  const roll = rng.int(0, depth > 0 ? 9 : 5);
  switch (roll) {
    case 0:
      return '"' + text(rng, rng.int(0, 4), allowLone) + '"';
    case 1:
      return number(rng);
    case 2:
      return 'true';
    case 3:
      return 'false';
    case 4:
      return 'null';
    case 5:
      return '"' + text(rng, rng.int(1, 3), allowLone) + '"';
    case 6:
    case 7:
      return array(rng, style, depth - 1, allowLone);
    default:
      return object(rng, style, depth - 1, allowLone, []);
  }
}

function array(rng: Rng, style: Style, depth: number, allowLone: boolean): string {
  const count = rng.int(0, 3);
  const items: string[] = [];
  for (let i = 0; i < count; i++) items.push(ws(rng, style) + value(rng, style, depth, allowLone) + ws(rng, style));
  return '[' + (count === 0 ? ws(rng, style) : items.join(',')) + ']';
}

function object(rng: Rng, style: Style, depth: number, allowLone: boolean, leading: string[]): string {
  const members = [...leading];
  for (let i = rng.int(0, 3); i > 0; i--) members.push(keySource(rng) + ws(rng, style) + ':' + ws(rng, style) + value(rng, style, depth, allowLone));
  if (members.length === 0) return '{' + ws(rng, style) + '}';
  return '{' + members.map((member) => ws(rng, style) + member + ws(rng, style)).join(',') + '}';
}

function element(rng: Rng, style: Style, depth: number, allowLone: boolean): string {
  const op = '"op"' + ws(rng, style) + ':' + ws(rng, style) + '"' + rng.pick(['entity.upsert', 'bible.upsert', 'promise.create', 'premise.update', 'e\\u006ftity.x']) + '"';
  const members: string[] = [];
  for (let i = rng.int(0, 2); i > 0; i--) members.push(keySource(rng) + ws(rng, style) + ':' + ws(rng, style) + value(rng, style, depth, allowLone));
  members.splice(rng.int(0, members.length), 0, op);
  if (rng.chance(0.08)) members.push('"op"' + ws(rng, style) + ':' + ws(rng, style) + rng.pick(['"later"', '7', 'null', '["x"]', '{}']));
  return '{' + members.map((member) => ws(rng, style) + member + ws(rng, style)).join(',') + '}';
}

function changeSet(rng: Rng, style: Style, count: number, depth: number, allowLone: boolean): string {
  const items: string[] = [];
  for (let i = 0; i < count; i++) items.push(ws(rng, style) + element(rng, style, depth, allowLone) + ws(rng, style));
  return '[' + (count === 0 ? ws(rng, style) : items.join(',')) + ']';
}

function member(rng: Rng, style: Style, key: string, source: string): string {
  return key + ws(rng, style) + ':' + ws(rng, style) + source;
}

function decoys(rng: Rng, style: Style): string[] {
  const pool = [
    () => member(rng, style, '"replying"', '"not the field"'),
    () => member(rng, style, '"changeSets"', '[{"op":"hidden"}]'),
    () => member(rng, style, '"lookups"', '[{"args":{"reply":"n","changeSet":[{"op":"h"}],"q":"a}b]c"}}]'),
    () => member(rng, style, '"question"', '"Anything else?"'),
    () => member(rng, style, '"meta"', value(rng, style, 2, true)),
    () => member(rng, style, '"n"', number(rng)),
    () => member(rng, style, '"re\\u0070ly2"', 'null'),
    () => member(rng, style, '"flag"', rng.pick(['true', 'false', 'null'])),
  ];
  const picked: string[] = [];
  for (let i = rng.int(1, 1); i > 0; i--) picked.push(rng.pick(pool)());
  return picked;
}

interface DocOptions {
  style: Style;
  replyAtoms: number;
  elements: number;
  elementDepth: number;
  replyFirst: boolean | null;
  extras: boolean;
  allowLone: boolean;
  replyKey: string;
  changeSetKey: string;
  omitChangeSet: boolean;
  omitReply: boolean;
}

function defaults(rng: Rng): DocOptions {
  return {
    style: rng.pick<Style>(['compact', 'compact', 'spaced', 'wild']),
    replyAtoms: rng.int(1, 4),
    elements: rng.int(0, 2),
    elementDepth: rng.int(0, 1),
    replyFirst: null,
    extras: false,
    allowLone: false,
    replyKey: '"reply"',
    changeSetKey: '"changeSet"',
    omitChangeSet: false,
    omitReply: false,
  };
}

function buildDoc(rng: Rng, overrides: Partial<DocOptions> = {}, replyOverride?: string): string {
  const options = { ...defaults(rng), ...overrides };
  const members: string[] = [];
  const replyMember = member(rng, options.style, options.replyKey, replyOverride ?? '"' + text(rng, options.replyAtoms, options.allowLone) + '"');
  const changeSetMember = member(
    rng,
    options.style,
    options.changeSetKey,
    changeSet(rng, options.style, options.elements, options.elementDepth, options.allowLone),
  );
  const replyFirst = options.replyFirst ?? rng.chance(0.5);
  const core: string[] = [];
  if (!options.omitReply) core.push(replyMember);
  if (!options.omitChangeSet) core.push(changeSetMember);
  if (!replyFirst) core.reverse();
  members.push(...core);
  if (options.extras) for (const extra of decoys(rng, options.style)) members.splice(rng.int(0, members.length), 0, extra);
  return '{' + members.map((entry) => ws(rng, options.style) + entry + ws(rng, options.style)).join(',') + '}';
}

const PROSE_BEFORE = [
  'Sure, here you go:\n```json\n',
  'Here is the JSON {as requested}:\n',
  'Thinking... {"draft": maybe} ',
  '```\n',
  'Fill the `{reply}` field then: ',
  '{} ',
  '  \n\n',
  'Output { not json } and [ also not ] ',
  '{"changeSet":[{"op":"early"}]} ',
  '{"reply',
];
const PROSE_AFTER = [
  '\n```',
  '\n\nignored trailer text {not json} "reply": "fake"',
  '\n{"reply":"second","changeSet":[{"op":"b"}]}',
  ' }}}]]]',
  '\u0000',
  '{"reply":"x"',
  '   ',
];

function unitsOf(source: string): number[] {
  const units: number[] = [];
  for (let i = 0; i < source.length; i++) units.push(source.charCodeAt(i));
  return units;
}

function sliceChunks(units: number[], cuts: number[]): number[][] {
  const points = [...new Set(cuts)].filter((cut) => cut > 0 && cut < units.length).sort((a, b) => a - b);
  const chunks: number[][] = [];
  let previous = 0;
  for (const point of points) {
    chunks.push(units.slice(previous, point));
    previous = point;
  }
  chunks.push(units.slice(previous));
  return chunks;
}

function boundaryCuts(source: string): number[] {
  const cuts: number[] = [];
  for (let i = 0; i < source.length; i++) {
    const code = source.charCodeAt(i);
    const next = source.charCodeAt(i + 1);
    if (code === 0x5c) {
      cuts.push(i, i + 1);
      if (next === 0x75) for (let k = 2; k <= 5; k++) cuts.push(i + k);
    }
    if (code >= 0xd800 && code <= 0xdbff) cuts.push(i + 1);
    if (code === 0x7b || code === 0x7d) cuts.push(i + 1);
  }
  return cuts;
}

function randomCuts(rng: Rng, length: number, minSize: number, maxSize: number): number[] {
  const cuts: number[] = [];
  let position = 0;
  while (position < length) {
    position += rng.int(minSize, maxSize);
    cuts.push(position);
  }
  return cuts;
}

function chunk(rng: Rng, source: string, chunking: Chunking): number[][] {
  const units = unitsOf(source);
  switch (chunking) {
    case 'whole':
      return [units];
    case 'units':
      return units.map((unit) => [unit]);
    case 'small':
      return sliceChunks(units, randomCuts(rng, units.length, 3, 9));
    case 'medium':
      return sliceChunks(units, randomCuts(rng, units.length, 3, 40));
    case 'boundaries':
      return sliceChunks(units, boundaryCuts(source));
  }
}

const STANDARD: Chunking[] = ['whole', 'units', 'small', 'boundaries'];
const LEAN: Chunking[] = ['whole', 'small', 'boundaries'];
const LONG: Chunking[] = ['whole', 'medium'];

const docs: Doc[] = [];

function add(kind: string, source: string, chunkings: Chunking[] = STANDARD): void {
  docs.push({ kind, source, chunkings });
}

const rng = createRng(0x5eed1234);

const RAW_PAYLOAD =
  '{"changeSet":[{"op":"upsert","target":"bible:x","value":{"reply":"not me","note":"contains { and [ and \\"reply\\" text"}}],' +
  '"lookups":[{"tool":"search_lore","args":{"q":"a}b]c","n":42,"ok":true,"none":null}}],' +
  '"reply":"Hello \\"world\\"!\\nLine two\\twith tab, caf\\u00e9 \\ud83d\\ude00 and \\\\backslash\\\\ end."}';
add('spec', RAW_PAYLOAD);
add('spec', '{"reply":"hi 😀!"}');
add('spec', '{"reply":"a\\u12","after":"LEAK"}');
add('spec', '{"reply":"a\\u12\\nb"}');
add('spec', '{"changeSet":[{"reply":123}],"reply":"hi"}');
add('spec', '{"reply":"x","changeSet":[{"op":"a",},"text",42,["op"],{"op":7},{"kind":"thread"},{"op":undefined},{"op":"premise.update"},null]}');
add('spec', '{"reply":"x","changeSet":[{"op":"lost" oops},{"op":"kept","note":"a\\"}b"}]}');
add('spec', 'Here is the JSON {as requested}:\n{"reply":"hi"}');
add('spec', '{"replying":"not the field","reply":"the field"}');
add('spec', '{"reply":"x","changeSet":[{"op":"a"}]}\n{"reply":"y","changeSet":[{"op":"b"}]}');

for (let i = 0; i < 40; i++) add('keyOrder', buildDoc(rng, { replyFirst: i % 2 === 0 }));
for (let i = 0; i < 25; i++) add('extraKeys', buildDoc(rng, { extras: true, elements: rng.int(0, 3) }));
for (let i = 0; i < 25; i++) add('nestedElements', buildDoc(rng, { elements: rng.int(1, 2), elementDepth: rng.int(3, 4), extras: rng.chance(0.3) }));
for (let i = 0; i < 30; i++) add('escapes', buildDoc(rng, { replyAtoms: rng.int(4, 8), elements: rng.int(0, 1) }));
for (let i = 0; i < 40; i++) add('surrogates', buildDoc(rng, { replyAtoms: rng.int(3, 7), allowLone: true, elements: rng.int(0, 1) }));
for (let i = 0; i < 15; i++) add('astral', buildDoc(rng, { elements: rng.int(0, 2) }, '"' + (i % 2 === 0 ? '😀𝒜' : 'x') + text(rng, 4, false) + '😀"'));
for (let i = 0; i < 25; i++) add('whitespace', buildDoc(rng, { style: 'wild', elements: rng.int(1, 2), extras: false }));
for (let i = 0; i < 20; i++) {
  const numbers = Array.from({ length: rng.int(2, 6) }, () => number(rng));
  const source = '{"reply":"n","changeSet":[{"op":"num","values":[' + numbers.join(',') + '],"single":' + number(rng) + ',"nested":{"v":' + number(rng) + '}}]}';
  add('numbers', source);
}
for (const source of NUMBERS.map((n) => '{"reply":"r","changeSet":[{"op":"n","v":' + n + '}]}')) add('numbers', source, ['whole', 'boundaries']);

add('emptyReply', '{"reply":""}');
add('emptyReply', '{"reply":"","changeSet":[]}');
add('emptyReply', '{"changeSet":[{"op":"a"}],"reply":""}');
for (let i = 0; i < 5; i++) add('emptyReply', buildDoc(rng, {}, '""'), LEAN);

for (let i = 0; i < 4; i++) {
  const long = text(rng, 60 + i * 10, i % 2 === 0);
  add('longReply', buildDoc(rng, { elements: 2 }, '"' + long + '"'), LONG);
}
add('longReply', '{"reply":"' + 'x'.repeat(500) + '"}', LONG);
add('longReply', '{"reply":"' + '😀'.repeat(150) + '","changeSet":[{"op":"a"}]}', LONG);
add('longReply', '{"changeSet":[{"op":"big","body":"' + 'y'.repeat(400) + '"}],"reply":"after"}', LONG);

for (let i = 0; i < 20; i++) {
  const prefix = rng.chance(0.8) ? rng.pick(PROSE_BEFORE) : '';
  const suffix = rng.chance(0.8) ? rng.pick(PROSE_AFTER) : '';
  add('proseAroundObject', prefix + buildDoc(rng, { elements: rng.int(0, 2) }) + suffix, LEAN);
}

for (let i = 0; i < 28; i++) {
  const full = buildDoc(rng, { elements: rng.int(1, 2), extras: rng.chance(0.3), allowLone: rng.chance(0.4), replyAtoms: rng.int(3, 6) });
  const cut = rng.int(1, full.length - 1);
  add('truncated', full.slice(0, cut), LEAN);
}
for (let i = 0; i < 12; i++) {
  const full = buildDoc(rng, { elements: 2, replyAtoms: 8, allowLone: true });
  const anchors = [...full.matchAll(/\\u[0-9a-fA-F]{0,3}|\\|\\ud[89ab][0-9a-f]{2}/gi)].map((found) => found.index as number);
  const anchor = anchors.length > 0 ? rng.pick(anchors) : rng.int(1, full.length - 1);
  add('truncated', full.slice(0, anchor + rng.int(1, 4)), LEAN);
}

const MALFORMED_REPLIES = [
  '"bad \\q escape"',
  '"bad \\x41 escape"',
  '"short \\u12 escape"',
  '"short \\u1 "',
  '"short \\uZZZZ escape"',
  '"trailing backslash\\\\"',
  '5',
  'true',
  'null',
  '["leak"]',
  '{"reply":"leak"}',
  '-1.5e3',
  '"unterminated',
];
for (const reply of MALFORMED_REPLIES) {
  add('malformed', buildDoc(rng, { replyFirst: true }, reply), LEAN);
  add('malformed', buildDoc(rng, { replyFirst: false }, reply), LEAN);
}

const MALFORMED_CHANGE_SETS = [
  '{"op":"a"}',
  '"text"',
  'null',
  '5',
  '[1,2,3]',
  '[null,true,"x",[],{}]',
  '[{"op":"a"}{"op":"b"}]',
  '[{"op":"a"},,{"op":"b"}]',
  '[{"op":"a"},{"op":"b"},]',
  '[{"op":"a",}]',
  "[{'op':'a'}]",
  '[{op:"a"}]',
  '[{"op":"a" "x":1}]',
  '[{"op":"a","x":01}]',
  '[{"op":"a","x":+1}]',
  '[{"op":"a","x":.5}]',
  '[{"op":"a","x":1.}]',
  '[{"op":"a","x":NaN}]',
  '[{"op":"a","x":undefined}]',
  '[{"op":"a","x":"\\q"}]',
  '[{"op":"a","x":"\\u12"}]',
  '[{"op":"a","x":"tab\there"}]',
  '[{"op":"a","x":"line\nbreak"}]',
  '[{"op":7}]',
  '[{"op":null}]',
  '[{"op":["a"]}]',
  '[{"op":{"op":"a"}}]',
  '[{"kind":"thread"}]',
  '[{"OP":"a"}]',
  '[{"op":"a","op":7}]',
  '[{"op":7,"op":"a"}]',
  '[{"o\\u0070":"escaped key"}]',
  '[{"op":"a"}',
  '[{"op":"a"]',
  '[{"op":"a","x":[1,2}]',
  '[{"op":"a","x":{"y":1]}]',
  '[{"op":"a","x":1 }]',
  '[{ "op":"a"}]',
  '[ {"op":"a"}]',
  '[{"op":"a"},[{"op":"nested array"}],{"op":"b"}]',
  '[[{"op":"deep"}]]',
  '[{"op":"a","x":tru}]',
  '[{"op":"a","x":nul}]',
  '[{"op":"a","x":truee}]',
  '[{"op":"a","x":-}]',
  '[{"op":"a","x":1e}]',
  '[{"op":"a","x":1e+}]',
  '[{"op":"a","x":0x10}]',
  '[{"op":"a"} junk,{"op":"b"}]',
  '[{"op":"a"} ,{"op":"b"}]',
];
for (const changeSetSource of MALFORMED_CHANGE_SETS) {
  const replyMember = '"reply":"r"';
  const changeSetMember = '"changeSet":' + changeSetSource;
  add('malformed', '{' + replyMember + ',' + changeSetMember + '}', LEAN);
  add('malformed', '{' + changeSetMember + ',' + replyMember + '}', ['whole', 'small']);
}
add('malformed', '{"reply":"a" "changeSet":[{"op":"a"}]}', LEAN);
add('malformed', '{"reply":"a","changeSet":[{"op":"a"}]', LEAN);
add('malformed', '{"reply" "a"}', LEAN);
add('malformed', '{"reply":}', LEAN);
add('malformed', '{reply:"a"}', LEAN);
add('malformed', '{"reply":"a"]', LEAN);
add('malformed', '{"reply":"a","x":[}', LEAN);
add('malformed', '[{"reply":"a"}]', LEAN);
add('malformed', '{"x":"{","reply":"a"}', LEAN);
add('malformed', '{"reply":"a","reply":"b","changeSet":[{"op":"a"}],"changeSet":[{"op":"c"}]}', LEAN);
add('malformed', '{"changeSetX":[{"op":"hidden"}],"changeSet":[{"op":"seen"}],"reply":"r"}', LEAN);
add('malformed', '{"repl\\u0079":"escaped key","changeS\\u0065t":[{"op":"escaped key"}]}', LEAN);
add('malformed', '{"reply":"r","changeSet":[{"op":"a"}],"x":{"changeSet":[{"op":"hidden"}]}}', LEAN);
add('malformed', '{"x":{"reply":"hidden"},"reply":"shown"}', LEAN);
add('malformed', '{"x":[{"reply":"hidden"}],"reply":"shown"}', LEAN);
add('malformed', '{ "reply" : "r" , "changeSet" : [ { "op" : "a" } , { "op" : "b" } ] }', LEAN);
add('malformed', '{"reply":"r","changeSet":[{"op":"a"}] }  trailing', LEAN);

const MUTATION_ALPHABET = ['"', '\\', '{', '}', '[', ']', ',', ':', 'u', ' ', '\n', 'n', '0', ' ', '😀', 'e', '-'];
for (let i = 0; i < 40; i++) {
  const base = buildDoc(rng, { elements: rng.int(1, 2), extras: rng.chance(0.3), allowLone: rng.chance(0.3), replyAtoms: rng.int(2, 5) });
  const units = base.split('');
  for (let edits = rng.int(1, 3); edits > 0; edits--) {
    const position = rng.int(0, units.length);
    const operation = rng.int(0, 2);
    if (operation === 0) units.splice(position, 0, rng.pick(MUTATION_ALPHABET));
    else if (operation === 1) units.splice(position, 1);
    else units.splice(position, 1, rng.pick(MUTATION_ALPHABET));
  }
  add('mutated', units.join(''), LEAN);
}
for (let i = 0; i < 12; i++) {
  let garbage = '';
  for (let length = rng.int(5, 40); length > 0; length--) garbage += rng.pick(MUTATION_ALPHABET);
  add('mutated', garbage, LEAN);
}
for (let i = 0; i < 6; i++) add('rawSurrogates', buildDoc(rng, { elements: 1 }, '"x' + rng.pick(['\ud83d', '\ude00', '\ud83d😀', '\ude00\ud83d']) + 'y"'), LEAN);
add('rawSurrogates', '{"reply":"end\ud83d"}', STANDARD);
add('rawSurrogates', '{"reply":"end\ud83d', STANDARD);
add('rawSurrogates', '{"reply":"\\ud83d"}', STANDARD);
add('rawSurrogates', '{"reply":"\\ud83d', STANDARD);
add('rawSurrogates', '{"reply":"\\ude00\\ud83d\\ude00\\ud83d"}', STANDARD);

interface Outcome {
  reply: string;
  elements: string[];
  state: 'awaitingReply' | 'replyFound' | 'completed';
  dangling: boolean;
}

interface ChunkingRecord {
  name: Chunking;
  cuts: number[];
}

interface DocumentRecord {
  id: string;
  source: string;
  outcome: Outcome;
  chunkings: ChunkingRecord[];
}

function hexUnits(units: number[]): string {
  return units.map((unit) => unit.toString(16).padStart(4, '0')).join('');
}

function runReference(chunks: number[][]): Outcome {
  const scanner = new ReplyStreamScanner();
  let output = '';
  const elements: string[] = [];
  for (const units of chunks) {
    output += scanner.push(String.fromCharCode(...units));
    for (const parsed of scanner.takeChangeSetElements()) elements.push(JSON.stringify(parsed));
  }
  const internals = scanner as unknown as { state: string; pendingSurrogate: string };
  return {
    reply: hexUnits(unitsOf(output)),
    elements,
    state: internals.state === 'done' ? 'completed' : scanner.replyFound ? 'replyFound' : 'awaitingReply',
    dangling: internals.pendingSurrogate !== '',
  };
}

const records: DocumentRecord[] = [];
docs.forEach((doc, docIndex) => {
  const seen = new Set<string>();
  const runs: { name: Chunking; cuts: number[]; outcome: Outcome }[] = [];
  for (const chunking of doc.chunkings) {
    const chunks = chunk(createRng(0xc0ffee + docIndex * 31 + chunking.length), doc.source, chunking);
    const cuts = chunks.slice(0, -1).reduce<number[]>((all, part) => [...all, (all.at(-1) ?? 0) + part.length], []);
    const fingerprint = JSON.stringify(cuts);
    if (seen.has(fingerprint)) continue;
    seen.add(fingerprint);
    runs.push({ name: chunking, cuts, outcome: runReference(chunks) });
  }
  const shared = runs[0] as (typeof runs)[number];
  const identical = runs.every((run) => JSON.stringify(run.outcome) === JSON.stringify(shared.outcome));
  if (!identical) throw new Error(`reference output differs by chunking for ${doc.kind}-${docIndex}`);
  records.push({
    id: `${doc.kind}-${docIndex}`,
    source: hexUnits(unitsOf(doc.source)),
    outcome: shared.outcome,
    chunkings: runs.map((run) => ({ name: run.name, cuts: run.cuts })),
  });
});

const output = '[\n' + records.map((entry) => JSON.stringify(entry)).join(',\n') + '\n]\n';
writeFileSync(join(dirname(fileURLToPath(import.meta.url)), 'cases.json'), output);

const byKind = new Map<string, number>();
let caseCount = 0;
for (const entry of records) {
  const kind = entry.id.replace(/-\d+$/, '');
  byKind.set(kind, (byKind.get(kind) ?? 0) + entry.chunkings.length);
  caseCount += entry.chunkings.length;
}
process.stdout.write(`${records.length} documents, ${caseCount} cases ${JSON.stringify(Object.fromEntries(byKind))}\n`);
