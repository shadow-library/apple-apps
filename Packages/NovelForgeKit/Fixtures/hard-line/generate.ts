import { plugin } from 'bun';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');

const server = join(platformRepo, 'apps/novel-forge-server/src');
const classes = await import(join(server, 'classes/app-error-code.ts'));

plugin({
  name: 'hard-line-fixture-stubs',
  setup(build) {
    build.module('@server/classes', () => ({ exports: { AppErrorCode: classes.AppErrorCode }, loader: 'object' }));
    build.module('@langchain/core/messages', () => ({ exports: {}, loader: 'object' }));
  },
});

const hardLine = await import(join(server, 'modules/ai/hard-line.ts'));
const { AppError } = await import(join(platformRepo, 'node_modules/@shadow-library/common'));

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

type Tagged = null | boolean | number | string | Tagged[] | { o: [string, Tagged][] };

function materialize(value: Tagged): unknown {
  if (Array.isArray(value)) return value.map(materialize);
  if (value === null || typeof value !== 'object') return value;
  const out: Record<string, unknown> = {};
  for (const [key, entry] of value.o) Object.defineProperty(out, key, { value: materialize(entry), enumerable: true, writable: true, configurable: true });
  return out;
}

const obj = (...entries: [string, Tagged][]): Tagged => ({ o: entries });

const sourceText = readFileSync(join(server, 'modules/ai/hard-line.ts'), 'utf8');

function tableKeys(name: string): string[] {
  const start = sourceText.indexOf(`const ${name}`);
  const end = sourceText.indexOf('\n};', start);
  return [...sourceText.slice(start, end).matchAll(/^ {2}(\w+):/gm)].map(match => match[1] as string);
}

const SUPPLIED_KEYS = tableKeys('SUPPLIED_INPUTS');
const BACKGROUND_KEYS = tableKeys('BACKGROUND_INPUTS');

const rng = createRng(0x0d10);

const STANDALONE = ['lolicon', 'shotacon', 'loli', 'shota', 'csam', 'CSAM', 'Child Porn', 'child porn', 'child pornography', 'CHILD PORNOGRAPHY', 'pedophilic', 'paedophilic', 'Pedophilic'];
const STANDALONE_NEAR = ['lolita', 'shotas', 'pedophile', 'child  porn', 'child-porn', 'csams', 'lolis', 'pedophilia', 'cs am', 'lo li'];
const MINOR = [
  'child', 'Child', 'CHILD', 'children', 'Childs', 'childs', 'minors', 'underage', 'under-age', 'UNDERAGE', 'preteen', 'pre-teens', 'preteens', 'prepubescent', 'pubescent', 'toddler', 'toddlers', 'infant',
  'infants', 'schoolgirl', 'schoolgirls', 'schoolboy', 'schoolboys', 'gradeschooler', 'grade-schoolers', 'middleschoolers', 'middle-schooler', 'young teen', 'young teens', 'little girl', 'little boys',
  'little girls', 'little  girl', '7 years old', '12-year-old', '17yrs old', '1 yr old', '9 YEARS OLD', 'aged 9', 'age of 16', 'Age of seventeen', 'age 4', 'aged ten', '15 yo', '8yo', '17 YO', 'nine-years-old',
  'eleven year old', 'sixteen-yr-old', 'seventeen yrs old', '17 yo', '12 years old', '3-yo',
];
const NOT_MINOR = [
  'adult', 'woman', 'minor', 'kid', 'baby', '18 years old', 'aged 18', 'age of 30', '19 yo', '117 yo', '1700 years old', 'age of eighteen', 'twenty-year-old', 'childhood', "children's", 'childless',
  'child_', 'child2', '10 y o', 'aged  9', 'age of', '0 years old', '07 yo', 'nineteen years old', 'seventeen', 'yo',
];
const GLUED_MINOR = ['échild', 'childé', 'child😀', '😀child', 'ſchoolgirl', 'ſchoolgirls', 'Kchild', 'child́', 'échild', 'ａｇｅｄ 9', 'İchild', 'ǆchild', 'children​', '​child'];
const SEXUAL = [
  'sex', 'Sex', 'SEX', 'sexual', 'sexually', 'sexualised', 'sexualized', 'sexualise', 'sexualize', 'sexy', 'erotic', 'erotica', 'erotically', 'eroticism', 'orgasm', 'orgasms', 'orgasmic', 'intercourse',
  'sexual intercourse', 'genital', 'genitals', 'genitalia', 'fondle', 'fondled', 'fondles', 'fondling', 'molest', 'molested', 'molester', 'molesting', 'molestation', 'molests', 'grope', 'groped', 'gropes',
  'groping', 'made love', 'making love', 'make love', 'Made Love', 'porn', 'pornographic', 'pornography', 'masturbate', 'masturbated', 'masturbates', 'masturbating', 'masturbation', 'lewd', 'ſex',
  'sex́', 'éSEX', 'sex😀', 'sexual intercourse', 'sexual  intercourse',
];
const SEXUAL_NEAR = ['sexton', 'essex', 'middlesex', 'sexes', 'groper', 'fondly', 'lewdly', 'grop', 'molestor', 'pornos', 'intercourses', 'genitale', 'erotics', 'orgasmically', 'lovemaking', 'madelove', 'sex_', 'sex1'];
const FILLER = ['The', 'she said', 'He walked home', 'They met at the market', 'Then rain fell', '"quoted"', 'ordinary prose', '', ' ', 'é', '😀', 'é', 'ſ', 'K', 'İ', '𝒳', 'a‍b', ' ', '﻿'];
const GLUE = [' ', ' ', ' ', ' ', '', '-', '_', ' ', '  ', '\t', '😀', 'é', '́', '﻿', ' ', '/', "'", '"', ',', '(', ')'];
const SEPS = ['. ', '! ', '? ', '; ', '\n', '\r\n', ' ', ', ', '", "', '","', '" ,\n"', '" , "', ' ', ' ', '\r', '...', '.\n', ' - ', ': ', ' and ', '\t', '﻿', '.', '\n\n', '!?'];

function phrase(): string {
  const roll = rng.int(0, 11);
  const parts: string[] = [];
  if (roll < 4) parts.push(rng.pick(MINOR));
  else if (roll === 4) parts.push(rng.pick(NOT_MINOR));
  else if (roll === 5) parts.push(rng.pick(GLUED_MINOR));
  if (rng.chance(roll < 4 ? 0.7 : 0.2)) parts.push(rng.chance(0.12) ? rng.pick(SEXUAL_NEAR) : rng.pick(SEXUAL));
  if (rng.chance(0.04)) parts.push(rng.chance(0.5) ? rng.pick(STANDALONE) : rng.pick(STANDALONE_NEAR));
  for (let i = rng.int(0, 2); i > 0; i--) parts.push(rng.pick(FILLER));
  for (let i = parts.length - 1; i > 0; i--) {
    const j = rng.int(0, i);
    [parts[i], parts[j]] = [parts[j] as string, parts[i] as string];
  }
  return parts.reduce((joined, part, index) => (index === 0 ? part : joined + rng.pick(GLUE) + part), '');
}

function text(): string {
  if (rng.chance(0.03)) return '';
  const segments: string[] = [];
  for (let i = rng.int(1, 4); i > 0; i--) segments.push(phrase());
  return segments.reduce((joined, segment, index) => (index === 0 ? segment : joined + rng.pick(SEPS) + segment), '');
}

function lexiconDump(lexicon: Record<string, RegExp[]>): Record<string, [string, string][]> {
  const out: Record<string, [string, string][]> = {};
  for (const key of Object.keys(lexicon)) out[key] = (lexicon[key] as RegExp[]).map(term => [term.source, term.flags]);
  return out;
}

function hand(texts: string[], scope?: string): [string[], string | null, string | null] {
  return [texts, scope ?? null, hardLine.findHardLine(texts, scope)];
}

const HAND_TEXTS: string[][] = [
  [],
  [''],
  ['lolicon'],
  ['LOLICON'],
  ['a loli.'],
  ['éloli'],
  ['loliá'],
  ['loli_'],
  ['loli2'],
  ['child porn'],
  ['child porn'],
  ['child pornography'],
  ['a child. sex'],
  ['a child; sex'],
  ['a child\nsex'],
  ['a child\r\nsex'],
  ['a child\rsex'],
  ['a child sex'],
  ['a child! sex'],
  ['a child? sex'],
  ['a child, sex'],
  ['a child sex'],
  ['"child", "sex"'],
  ['"child","sex"'],
  ['"child" , "sex"'],
  ['"child" , "sex"'],
  ['["a child", "a story", "sex"]'],
  ['the child said "sex" loudly'],
  ['child', 'sex'],
  ['child sex', 'x'],
  ['x', 'child sex'],
  ['x', 'csam'],
  ['child orgasm'],
  ['child intercourse'],
  ['child sexual intercourse'],
  ['child erotic'],
  ['child masturbation'],
  ['child lewd'],
  ['child porn'],
  ['child genitals'],
  ['child sexy'],
  ['child molested'],
  ['child groping'],
  ['child made love'],
  ['child fondling'],
  ['aged 17 sex'],
  ['aged 18 sex'],
  ['age of seventeen sex'],
  ['seventeen-year-old sex'],
  ['17 yo erotic'],
  ['17yo erotic'],
  ['17 yo erotic'],
  ['117 yo sex'],
  ['1700 years old sex'],
  ['7 years old porn'],
  ['10 yrs old intercourse'],
  ['ſchoolgirl sex'],
  ['schoolgirl ſex'],
  ['Kid sex'],
  ['CHILD SEX'],
  ['Child Sex.'],
  ['child'],
  ['sex'],
  ['a'.repeat(1200) + ' child sex'],
  ['child sex ' + 'a'.repeat(1200)],
  [('child. ').repeat(80) + 'sex'],
  ['😀 child 😀 sex 😀'],
  ['child́ sex'],
  ['child sex́'],
  ['échild sex'],
];

const find = HAND_TEXTS.flatMap(texts => [hand(texts, 'supplied'), hand(texts, 'background'), hand(texts)]);
for (let i = 0; i < 450; i++) {
  const texts: string[] = [];
  for (let n = rng.pick([1, 1, 1, 2, 3]); n > 0; n--) texts.push(text());
  find.push(hand(texts, rng.pick(['supplied', 'background', undefined as never])));
}

const customLexicon = {
  standalone: [/zz/i, /\bq\b/],
  minor: [/kid/i, /\bmini\b/],
  sexual: [/spicy/, /\bhot\b/i],
  explicit: [/\bexplicit\b/],
};
const custom: [string[], string, string | null][] = [];
for (const texts of [['ZZ'], ['q'], ['Q'], ['kid spicy'], ['KID hot'], ['kid explicit'], ['mini hot', 'x'], ['mini. hot'], ['mini explicit.'], ['mini, explicit'], ['x'], [], ['SPICY kid']]) {
  for (const scope of ['supplied', 'background']) custom.push([texts, scope, hardLine.findHardLine(texts, scope, customLexicon)]);
}

const SOURCES = ['Your message', "Chapter 4's summary", 'The generated text', 'The Story Bible', 'The request', '', 'Chapter {x} 100% {source}', 'The "quoted" ❮source❯ 😀', 'é summary', '\\{x}'];
const REFS = [[], ['chapter:4'], ['entity:mira', 'fact:lamp'], ['é', '😀'], [''], ['chapter:'], ['a', 'a']];

function screened(texts: string[], scope?: string): [string, string, string, string[] | null] {
  return [rng.pick(texts), rng.pick([scope ?? 'supplied', 'supplied', 'background']), rng.pick(SOURCES), rng.chance(0.5) ? null : (rng.pick(REFS) as string[])];
}

const hits: unknown[] = [];
for (let i = 0; i < 300; i++) {
  const items: [string, string, string, string[] | null][] = [];
  for (let n = rng.int(0, 4); n > 0; n--) items.push(screened(rng.chance(0.6) ? [text()] : rng.pick(HAND_TEXTS.slice(1)).concat(['']), undefined));
  const runtime = items.map(([itemText, scope, source, sourceRefs]) => ({ text: itemText, scope, source, ...(sourceRefs === null ? {} : { sourceRefs }) }));
  const hit = hardLine.screenTexts(runtime);
  const refusal = hit === null ? null : hardLine.hardLineError(hit);
  hits.push([items, hit === null ? null : [hit.rule, hit.source, hit.sourceRefs], refusal === null ? null : [refusal.code, refusal.message, refusal.status]]);
}

const refusalKinds = [
  ['hard-line', hardLine.isHardLineRefusal(hardLine.hardLineError({ rule: 'standalone-term', source: 'x', sourceRefs: [] }))],
  ['other-app-error', hardLine.isHardLineRefusal(classes.AppErrorCode.AI_014.create())],
  ['other-app-error-2', hardLine.isHardLineRefusal(classes.AppErrorCode.AI_024.create())],
  ['plain-error', hardLine.isHardLineRefusal(new Error('AI_015'))],
  ['string', hardLine.isHardLineRefusal('AI_015')],
  ['null', hardLine.isHardLineRefusal(null)],
  ['undefined', hardLine.isHardLineRefusal(undefined)],
  ['lookalike', hardLine.isHardLineRefusal({ code: 'AI_015' })],
];
if (!AppError.is(hardLine.hardLineError({ rule: 'standalone-term', source: 'x', sourceRefs: [] }))) throw new Error('hardLineError must build an AppError');

const LABEL_KINDS = ['chapter', 'entity', 'bible_doc', 'fact', 'world_fact', 'thread', 'mystery', 'volume', 'doc'];
const VALUES = ['mira', '', '4', '😀', 'é', 'é', 'a:b', ':', 'x y', '"q"', ' ', 'ſ', 'Å', 'Å'];
const KEYS = ['brief', 'Brief', 'brief ', 'characters', 'recent_events', 'world_state', 'a__b', '_', '', 'é_é', '😀_😀', 'plot', 'summary_text'];

function ref(): string {
  const roll = rng.int(0, 9);
  if (roll === 0) return rng.pick(['', ':', 'chapter', 'chapter:', 'nocolon', ':chapter', 'Chapter:4', 'chapter :4', 'chapteŕ:4', 'chaptKr:4']);
  return `${rng.pick(roll === 1 ? ['unknown', 'Entity', 'ENTITY', 'chapters', 'doc ', 'é'] : LABEL_KINDS)}:${rng.pick(VALUES)}${rng.chance(0.15) ? ':' + rng.pick(VALUES) : ''}`;
}

const describe: [string, string[], string][] = [];
for (let i = 0; i < 500; i++) {
  const refs: string[] = [];
  for (let n = rng.pick([0, 1, 1, 2, 3, 4]); n > 0; n--) refs.push(ref());
  const key = rng.chance(0.4) ? 'brief' : rng.pick(KEYS);
  describe.push([key, refs, hardLine.describeSection(key, refs)]);
}
for (const [key, refs] of [
  ['brief', ['chapter:']],
  ['brief', ['chapter:4', 'chapter:5']],
  ['brief', ['entity:mira', 'chapter:7']],
  ['brief', []],
  ['x_y_z', []],
  ['___', []],
  ['characters', ['entity:a:b']],
] as [string, string[]][]) describe.push([key, refs, hardLine.describeSection(key, refs)]);

const classification = [...SUPPLIED_KEYS, ...BACKGROUND_KEYS, 'Message', 'message ', 'userMessagé', 'brief', 'unknown', '', '0', 'é', '😀', 'chapterNumbers', 'BODY'].map(key => {
  const screens = hardLine.inputScreens({ [key]: 'x' });
  return [key, hardLine.isClassifiedInput(key), screens.map((screen: { scope: string; source: string }) => [screen.scope, screen.source])];
});

const ROLES = ['generation', 'fix', 'revision', 'chat', 'Generation', 'chat ', '', 'summary', 'planning', 'review', 'constructor', '__proto__', 'toString', 'illustration', 'é'];
const roles = ROLES.map(role => [role, hardLine.outputScope(role)]);

const PROTOTYPE_KEYS = ['constructor', '__proto__', 'toString', 'hasOwnProperty', 'valueOf', 'isPrototypeOf', 'propertyIsEnumerable', 'toLocaleString', '__defineGetter__', '__defineSetter__', '__lookupGetter__', '__lookupSetter__'];
const prototypeKeys = PROTOTYPE_KEYS.map(key => {
  const screens = hardLine.inputScreens(materialize(obj([key, 'x'])) as Record<string, unknown>);
  let label: string;
  try {
    label = typeof hardLine.describeSection('characters', [`${key}:v`]);
  } catch (error) {
    label = error instanceof TypeError ? 'throws' : 'unexpected';
  }
  return [key, hardLine.isClassifiedInput(key), screens.map((screen: { scope: string; source: unknown }) => [screen.scope, typeof screen.source]), label];
});

const CONTENT_TEXTS = ['child sex', 'hello', '', 'a. b', 'lolicon', '😀', 'é', 'child', 'sex'];

function partTagged(allowPrimitive: boolean): Tagged {
  const roll = rng.int(0, allowPrimitive ? 11 : 8);
  switch (roll) {
    case 0:
    case 1:
    case 2:
      return obj(['type', 'text'], ['text', rng.pick(CONTENT_TEXTS)]);
    case 3:
      return obj(['type', 'image_url'], ['image_url', obj(['url', 'data:x'])]);
    case 4:
      return obj(['text', rng.pick<Tagged>([5, null, true, [], obj(), ['child']])]);
    case 5:
      return obj();
    case 6:
      return [rng.pick(CONTENT_TEXTS)];
    case 7:
      return obj(['text', rng.pick(CONTENT_TEXTS)]);
    case 8:
      return obj(['Text', 'child sex'], ['text', rng.pick(CONTENT_TEXTS)], ['text', 'overwritten']);
    case 9:
      return rng.pick(CONTENT_TEXTS);
    case 10:
      return rng.pick<Tagged>([null, 5, true]);
    default:
      return rng.pick<Tagged>([0, false, '']);
  }
}

function contentTagged(allowPrimitive: boolean): Tagged {
  const roll = rng.int(0, 9);
  if (roll < 3) return rng.pick(CONTENT_TEXTS);
  if (roll < 7) {
    const parts: Tagged[] = [];
    for (let n = rng.int(0, 4); n > 0; n--) parts.push(partTagged(allowPrimitive));
    return parts;
  }
  return rng.pick<Tagged>([5, null, true, obj(['text', 'child sex']), obj(), 0, false]);
}

const wire: unknown[] = [];
const wireDeviations: unknown[] = [];
for (let i = 0; i < 300; i++) {
  const messages: Tagged[] = [];
  for (let n = rng.int(0, 4); n > 0; n--) messages.push(rng.chance(0.1) ? obj() : obj(['role', rng.pick(['user', 'system', 'assistant'])], ['content', contentTagged(false)]));
  wire.push([messages, hardLine.wireMessageTexts(materialize(messages as never) as never)]);
}
for (let i = 0; i < 60; i++) {
  const content = contentTagged(true);
  if (!Array.isArray(content) || !content.some(part => part === null || typeof part !== 'object')) continue;
  const messages: Tagged[] = [obj(['content', content])];
  let threw = false;
  try {
    hardLine.wireMessageTexts(materialize(messages as never) as never);
  } catch (error) {
    threw = error instanceof TypeError;
  }
  if (!threw) throw new Error('a primitive content part must raise a TypeError in the reference');
  const stripped = content.map(part => (typeof part === 'string' ? obj(['text', part]) : part === null || typeof part !== 'object' ? obj() : part));
  wireDeviations.push([messages, hardLine.wireMessageTexts(materialize([obj(['content', stripped])] as never) as never)]);
}

function safeContent(value: Tagged): Tagged {
  if (!Array.isArray(value)) return value;
  return value.every(part => part !== null && typeof part === 'object') ? value : contentTagged(false);
}

function valueTagged(depth: number): Tagged {
  const roll = rng.int(0, depth <= 0 ? 4 : 12);
  switch (roll) {
    case 0:
    case 1:
      return text();
    case 2:
      return rng.pick<Tagged>([null, true, false, 0, 7, 1.5, -2]);
    case 3:
      return rng.pick(CONTENT_TEXTS);
    case 4:
      return '';
    case 5:
    case 6: {
      const items: Tagged[] = [];
      for (let n = rng.int(0, 4); n > 0; n--) items.push(valueTagged(depth - 1));
      return items;
    }
    case 7:
    case 8:
      return obj(['role', 'user'], ['content', contentTagged(false)]);
    case 9:
      return obj(['content', safeContent(valueTagged(depth - 1))], ['other', valueTagged(depth - 1)]);
    case 10:
      return [obj(['content', contentTagged(false)]), obj(['content', 'x', ], ['content', 'child sex']), [obj(['content', contentTagged(false)])]];
    default: {
      const entries: [string, Tagged][] = [];
      for (let n = rng.int(0, 4); n > 0; n--) entries.push([rng.pick(['b', 'a', '10', '2', '1', '01', '4294967295', '4294967294', 'é', 'é', 'x y']), valueTagged(depth - 1)]);
      return { o: entries };
    }
  }
}

const INPUT_KEYS = [...SUPPLIED_KEYS, ...BACKGROUND_KEYS, 'unknown', 'extra', 'Message', '0', '1', '10', '2', '4294967295', 'é', 'é', '😀', 'body ', ''];
const inputs: unknown[] = [];
for (let i = 0; i < 300; i++) {
  const entries: [string, Tagged][] = [];
  for (let n = rng.int(0, 6); n > 0; n--) entries.push([rng.pick(INPUT_KEYS), valueTagged(3)]);
  const screens = hardLine.inputScreens(materialize({ o: entries }) as Record<string, unknown>);
  inputs.push([entries, screens.map((screen: { text: string; scope: string; source: string }) => [screen.text, screen.scope, screen.source])]);
}

const outputs: unknown[] = [];
for (let i = 0; i < 300; i++) {
  const value = valueTagged(3);
  const role = rng.pick(['generation', 'fix', 'revision', 'chat', 'summary', 'planning', 'Chat', '']);
  const screens = hardLine.outputScreens(materialize(value), role);
  outputs.push([value, role, screens.map((screen: { text: string; scope: string; source: string }) => [screen.text, screen.scope, screen.source])]);
}

const sections: unknown[] = [];
for (let i = 0; i < 200; i++) {
  const list: [string, string, string[]][] = [];
  for (let n = rng.int(0, 4); n > 0; n--) {
    const refs: string[] = [];
    for (let r = rng.pick([0, 1, 2]); r > 0; r--) refs.push(ref());
    list.push([rng.chance(0.4) ? 'brief' : rng.pick(KEYS), text(), refs]);
  }
  const screens = hardLine.sectionScreens(list.map(([key, rendered, sourceRefs]) => ({ key, rendered, sourceRefs })));
  sections.push([list, screens.map((screen: { text: string; scope: string; source: string; sourceRefs: string[] }) => [screen.text, screen.scope, screen.source, screen.sourceRefs])]);
}

const systemLine = hardLine.HARD_LINE_SYSTEM_LINE;
const systemLineFindsNothing = hardLine.findHardLine([systemLine], 'supplied') === null && hardLine.findHardLine([systemLine], 'background') === null;

function write(name: string, value: unknown): void {
  writeFileSync(join(dirname(fileURLToPath(import.meta.url)), name), JSON.stringify(value) + '\n');
}

write('hard-line.json', {
  lexicon: lexiconDump(hardLine.HARD_LINE_LEXICON),
  systemLine,
  systemLineFindsNothing,
  find,
  custom,
  hits,
  refusalKinds,
  describe,
  classification,
  roles,
  prototypeKeys,
  wire,
  wireDeviations,
  inputs,
  outputs,
  sections,
});
