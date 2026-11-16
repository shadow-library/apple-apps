import { readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const repo = process.env['PLATFORM_REPO'];
if (!repo) throw new TypeError('PLATFORM_REPO must name the reference checkout');

const SERVER = 'apps/novel-forge-server/src';
const ts: typeof import('typescript') = await import(join(repo, 'node_modules/typescript/lib/typescript.js')).then(module => module.default ?? module);
const regexppPath = Bun.resolveSync('@eslint-community/regexpp', realpathSync(join(repo, 'node_modules/eslint/package.json')));
const { RegExpParser } = (await import(regexppPath)) as typeof import('@eslint-community/regexpp');
const { escapeRegExp } = (await import(join(repo, SERVER, 'common/term-text.ts'))) as { escapeRegExp: (term: string) => string };
const { revealTermPattern } = (await import(join(repo, SERVER, 'common/reveal-term.ts'))) as { revealTermPattern: (term: string, global?: boolean) => RegExp | null };

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
  return {
    int: (min, max) => min + Math.floor(next() * (max - min + 1)),
    chance: p => next() < p,
    pick: items => items[Math.floor(next() * items.length)] as never,
  };
}

interface Entry {
  location: string;
  kind: 'literal' | 'constructor';
  source: string | null;
  flags: string | null;
  resolved?: string;
}

type Operation = { kind: 'replace'; template: string } | { kind: 'replaceFunction' } | { kind: 'split' } | { kind: 'none' };

interface Instance {
  entry: number;
  source: string;
  flags: string;
  vocabulary: string[];
}

const PIECES = [
  'a', 'b', 'Z', 's', 'S', 'i', 'I', '0', '7', ' ', '-', '.', '?', '!', "'", '"', '_', '|', '\\', '$', '&', '`', ':', '/', 'é', 'Ö', 'ñ', 'é', '́', '𝒜', '𠀀',
  '😀', '👍🏽', '\t', '\n', '\v', '\f', '\r', '\u0085', ' ', ' ', '᠎', ' ', '​', ' ', ' ', ' ', '　', '﻿', '\r\n',
  'İ', 'ı', 'ß', 'ẞ', 'Σ', 'σ', 'ς', 'ﬀ', 'ǅ', 'K', 'Ω', 'Å', 'ſ', '٣', '１', 'Ⅻ', '‍', '中', '。', 'あ', 'カ', 'ー', 'ไ', '’', '“', '”', '—', '…', 'ͅ', '𝟘',
];
const NEIGHBOURS = ['𝒜', '𠀀', '😀', '𝟘', 'ͅ', 'ſ', 'K', 'a', '_', '1', ' ', 'é'];
const SEPARATORS = ['', ' ', ' ', '\n', '\t', ' ', ' ', '﻿', '\r\n', '  '];
const LOOKALIKES: Record<string, string[]> = { s: ['ſ', 'S'], S: ['ſ'], k: ['K', 'K'], K: ['K'], i: ['İ', 'ı'], I: ['ı', 'İ'], ß: ['ẞ'], σ: ['ς', 'Σ'] };
const TERM_WORDS = [
  'the', 'Heir', 'secret', 'naïve', 'Ödön', 'a.b', '(x)', '$5', 'c++', 'x|y', '[note]', '{k}', '^up', 'back\\slash', 'don’t', "it's", '“quoted”', '—', 'well-known',
  '中文', 'かな', 'ſtraße', 'Kelvin', '**bold**', '_it_', 'end.', 'a?', 'Straße', 'ǅemal', 'İstanbul', '😀ok',
];
const INPUTS_PER_ENTRY = 32;
const MINIMUM_INPUTS_PER_INSTANCE = 8;

const REPLACE_TEMPLATES: Record<string, string> = {
  'writer-disclosure-policy.ts:55': '', 'writer-disclosure-policy.ts:56': '', 'writer-disclosure-policy.ts:57': '', 'term-text.ts:2': '\\$&', 'hard-line.ts:134': ' ',
  'mechanical-check.ts:70': ' ', 'mechanical-check.ts:122': ' ', 'deterministic-metrics.ts:219': ' ', 'deterministic-metrics.ts:343': '', 'deterministic-metrics.ts:346': '',
  'deterministic-metrics.ts:336': ' ', 'deterministic-metrics.ts:389': '', 'write-policy.ts:170': '', 'write-policy.ts:173': ' ', 'write-policy.ts:187': "'",
  'write-policy.ts:188': '"', 'write-policy.ts:189': '-', 'write-policy.ts:190': ' ', 'write-policy.ts:195': '', 'write-policy.ts:215': '', 'negation-echo.ts:140': '',
  'negation-echo.ts:162': "'", 'negation-echo.ts:165': '', 'idea-id.ts:41': ' ', 'passage-context.ts:108': '\n   ',
};
const SPLITS = new Set([
  'writer-disclosure-policy.ts:54', 'writer-disclosure-policy.ts:75', 'writer-disclosure-policy.ts:86', 'hard-line.ts:83', 'mechanical-check.ts:90', 'mechanical-check.ts:121',
  'deterministic-metrics.ts:170', 'deterministic-metrics.ts:335', 'deterministic-metrics.ts:360', 'deterministic-metrics.ts:386', 'chapter-prose.ts:23', 'chapter-prose.ts:41',
  'write-policy.ts:169', 'write-policy.ts:172', 'negation-echo.ts:122', 'prose-paragraphs.ts:59',
]);
const REPLACE_FUNCTIONS = new Set(['writer-disclosure-policy.ts:89', 'writer-disclosure-policy.ts:100', 'reveal-term.ts:15']);

function shortLocation(location: string): string {
  return location.slice(location.lastIndexOf('/') + 1);
}

function operation(entry: Entry): Operation {
  const at = shortLocation(entry.location);
  if (at === 'deterministic-metrics.ts:316') return entry.source === '\\s+' ? { kind: 'split' } : { kind: 'replace', template: '' };
  if (at === 'deterministic-metrics.ts:516') return entry.kind === 'literal' ? { kind: 'replace', template: "['’]" } : { kind: 'none' };
  if (at in REPLACE_TEMPLATES) return { kind: 'replace', template: REPLACE_TEMPLATES[at] as string };
  if (SPLITS.has(at)) return { kind: 'split' };
  if (REPLACE_FUNCTIONS.has(at)) return { kind: 'replaceFunction' };
  return { kind: 'none' };
}

function topLevelConstants(path: string): Map<string, string> {
  const file = ts.createSourceFile(path, readFileSync(join(repo as string, path), 'utf8'), ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  const initializers = new Map<string, string>();
  for (const statement of file.statements) {
    if (!ts.isVariableStatement(statement)) continue;
    for (const declaration of statement.declarationList.declarations) {
      if (ts.isIdentifier(declaration.name) && declaration.initializer) initializers.set(declaration.name.text, declaration.initializer.getText(file));
    }
  }
  return initializers;
}

function evaluateConstants(path: string, names: string[]): Record<string, unknown> {
  const initializers = topLevelConstants(path);
  const values = new Map<string, unknown>();
  const evaluate = (name: string): unknown => {
    if (values.has(name)) return values.get(name);
    const initializer = initializers.get(name);
    if (initializer === undefined) throw new TypeError(`${path} declares no top-level ${name}`);
    const script = ts.transpile(`(${initializer})`, { target: ts.ScriptTarget.ES2022 }).replace(/^"use strict";/, '').trim().replace(/;$/, '');
    const dependencies = [...initializers.keys()].filter(other => other !== name && new RegExp(`\\b${other}\\b`).test(initializer));
    const value = new Function(...dependencies, `return ${script};`)(...dependencies.map(evaluate));
    values.set(name, value);
    return value;
  };
  return Object.fromEntries(names.map(name => [name, evaluate(name)]));
}

function wordsCallTerms(path: string): string[] {
  const file = ts.createSourceFile(path, readFileSync(join(repo as string, path), 'utf8'), ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  const terms: string[] = [];
  const visit = (node: import('typescript').Node): void => {
    if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === 'words') {
      for (const argument of node.arguments) if (ts.isStringLiteral(argument) && !terms.includes(argument.text)) terms.push(argument.text);
    }
    ts.forEachChild(node, visit);
  };
  visit(file);
  return terms;
}

function fromResolved(resolved: string, scope: Record<string, unknown>): string {
  return new Function(...Object.keys(scope), `return String.raw\`${resolved}\`;`)(...Object.values(scope));
}

function words(source: string): string[] {
  return source.replace(/\\[a-zA-Z](\{[^}]*\})?/g, ' ').match(/[\p{L}']{2,}/gu) ?? [];
}

function instancesOf(entry: Entry, index: number, rng: Rng): Instance[] {
  const at = shortLocation(entry.location);
  const make = (source: string, flags: string, vocabulary: string[] = []): Instance => ({ entry: index, source, flags, vocabulary: [...vocabulary, ...words(source)] });
  if (entry.kind === 'literal' && entry.source !== null) return [make(entry.source, entry.flags ?? '')];
  const resolved = entry.resolved ?? entry.source ?? '';
  if (!resolved.includes('${')) return [make(resolved, entry.flags ?? '')];
  switch (at) {
    case 'writer-disclosure-policy.ts:89': {
      const policy = `${SERVER}/modules/bible/fact/writer-disclosure-policy.ts`;
      const { LIST_MARKER, EMPHASIS, TRAILING_PUNCTUATION, CHARACTER_CLASSES, WORD_GAP } = evaluateConstants(policy, [
        'LIST_MARKER', 'EMPHASIS', 'TRAILING_PUNCTUATION', 'CHARACTER_CLASSES', 'WORD_GAP',
      ]) as { LIST_MARKER: RegExp; EMPHASIS: RegExp; TRAILING_PUNCTUATION: RegExp; CHARACTER_CLASSES: [RegExp, string][]; WORD_GAP: string };
      const charPattern = (char: string): string => CHARACTER_CLASSES.find(([matches]) => matches.test(char))?.[1] ?? escapeRegExp(char);
      return Array.from({ length: 5 }, () => {
        const passage = rng.pick(['', '- ', '1. ', '## ']) + Array.from({ length: rng.int(2, 5) }, () => rng.pick(TERM_WORDS)).join(rng.pick([' ', '\n', '  '])) + rng.pick(['', '.', '!?']);
        const trimmed = passage.replace(LIST_MARKER, '').replace(EMPHASIS, '').replace(TRAILING_PUNCTUATION, '').trim();
        const body = trimmed.split(/\s+/).map(word => [...word].map(charPattern).join('')).join(WORD_GAP);
        return make(fromResolved(resolved, { body }), entry.flags ?? '', trimmed.split(/\s+/));
      });
    }
    case 'writer-disclosure-policy.ts:100':
      return ['fact:heir_secret', 'fact:a.b*c', 'the_[x]_key', 'fact:Ödön_ß', 'fact:$1(2)|3', 'fact:k_ſ'].map(key => make(fromResolved(resolved, { escapeRegExp, key }), entry.flags ?? '', [key]));
    case 'reveal-term.ts:15':
      return ['Will', 'the heir', 'kelvin', 'a+b?', 'Ægir', 'naïve.', '中文名', '(secret)', 'x|y', 'ſtar', 'strasse', 'Σίσυφος'].flatMap((term, offset) => {
        const pattern = revealTermPattern(term, offset % 2 === 0);
        return pattern ? [make(pattern.source, pattern.flags, [term])] : [];
      });
    case 'hard-line.ts:45':
      return wordsCallTerms(`${SERVER}/modules/ai/hard-line.ts`).map(term => make(fromResolved(resolved, { term }), entry.flags ?? ''));
    case 'deterministic-metrics.ts:477': {
      const { DIALOGUE_TAG_VERBS } = evaluateConstants(`${SERVER}/modules/eval/deterministic-metrics.ts`, ['DIALOGUE_TAG_VERBS']);
      return [make(fromResolved(resolved, { DIALOGUE_TAG_VERBS }), entry.flags ?? '', ['Mary Ann', 'Tom'])];
    }
    case 'deterministic-metrics.ts:516':
    case 'deterministic-metrics.ts:517': {
      const { CONTRACTION_PAIRS } = evaluateConstants(`${SERVER}/modules/eval/deterministic-metrics.ts`, ['CONTRACTION_PAIRS']) as { CONTRACTION_PAIRS: [string, string][] };
      return CONTRACTION_PAIRS.map(([contractedForm, expandedForm]) =>
        make(fromResolved(resolved, { contractedForm, expandedForm }), entry.flags ?? '', [contractedForm, expandedForm, contractedForm.replace(/'/g, '’')]),
      );
    }
    case 'chapter-prose.ts:14':
    case 'prose-paragraphs.ts:81':
      return ['```', '````', '~~~', '~~~~~~', '`````````'].map(marker => make(fromResolved(resolved, { marker }), entry.flags ?? '', [marker, '```', '~~~~']));
    default:
      throw new TypeError(`no instances for the run-time pattern at ${entry.location}`);
  }
}

type Node = import('@eslint-community/regexpp').AST.Node;

class Sampler {
  private readonly pattern: import('@eslint-community/regexpp').AST.Pattern;
  private readonly members = new Map<string, RegExp>();
  private readonly ignoreCase: boolean;
  private readonly unicode: boolean;
  readonly anchoredAtStart: boolean;
  readonly anchoredAtEnd: boolean;

  constructor(
    private readonly instance: Instance,
    private readonly rng: Rng,
  ) {
    this.unicode = instance.flags.includes('u');
    this.ignoreCase = instance.flags.includes('i');
    this.pattern = new RegExpParser().parsePattern(instance.source, 0, instance.source.length, { unicode: this.unicode });
    this.anchoredAtStart = this.pattern.alternatives.every(alternative => alternative.elements[0]?.type === 'Assertion' && alternative.elements[0].kind === 'start');
    this.anchoredAtEnd = this.pattern.alternatives.some(alternative => alternative.elements.at(-1)?.type === 'Assertion' && alternative.elements.at(-1)?.raw === '$');
  }

  input(): string {
    return dropLoneSurrogates(this.composed());
  }

  private composed(): string {
    if (this.unicode && /\(\?<?[!=]/.test(this.instance.source) && this.rng.chance(0.5)) {
      return this.rng.pick(NEIGHBOURS) + this.sample(this.pattern) + this.rng.pick(NEIGHBOURS);
    }
    if (this.rng.chance(this.anchoredAtStart && this.anchoredAtEnd ? 0.4 : 0.15)) return this.sample(this.pattern);
    const segments = this.rng.int(1, 3);
    let text = '';
    for (let index = 0; index < segments; index++) {
      if (index > 0) text += this.rng.pick(SEPARATORS);
      const anchored = (index === 0 && this.anchoredAtStart) || (index === segments - 1 && this.anchoredAtEnd);
      text += anchored && this.rng.chance(0.6) ? this.sample(this.pattern) : this.segment();
    }
    return text;
  }

  private segment(): string {
    const kind = this.rng.int(0, 19);
    if (kind <= 6) return this.sample(this.pattern);
    if (kind <= 10) return (this.rng.chance(0.6) ? this.rng.pick(NEIGHBOURS) : '') + this.sample(this.pattern) + (this.rng.chance(0.6) ? this.rng.pick(NEIGHBOURS) : '');
    if (kind <= 12) return this.mutated(this.sample(this.pattern));
    if (kind <= 15) return this.cased(this.rng.pick(this.instance.vocabulary.length > 0 ? this.instance.vocabulary : ['word']));
    if (kind <= 18) return Array.from({ length: this.rng.int(1, 3) }, () => this.rng.pick(PIECES)).join('');
    return (this.rng.chance(0.5) ? this.sample(this.pattern) : this.rng.pick(PIECES)).repeat(this.rng.int(3, 8));
  }

  private mutated(text: string): string {
    const characters = [...text];
    if (characters.length === 0) return this.rng.pick(PIECES);
    const at = this.rng.int(0, characters.length - 1);
    const kind = this.rng.int(0, 2);
    if (kind === 0) characters.splice(at, 1);
    else if (kind === 1) characters.splice(at, 1, this.rng.pick(PIECES));
    else characters.splice(at, 0, this.rng.pick(PIECES));
    return characters.join('');
  }

  private cased(text: string): string {
    const kind = this.rng.int(0, 3);
    if (kind === 0) return text.toUpperCase();
    if (kind === 1) return text.charAt(0).toUpperCase() + text.slice(1);
    if (kind === 2) return [...text].map(character => this.variant(character)).join('');
    return text;
  }

  private variant(character: string): string {
    const lookalikes = LOOKALIKES[character];
    if (lookalikes && this.rng.chance(0.1)) return this.rng.pick(lookalikes);
    if (!this.ignoreCase || !this.rng.chance(0.5)) return character;
    return this.rng.pick([character.toUpperCase(), character.toLowerCase()].filter(other => [...other].length === 1));
  }

  private sample(node: Node): string {
    switch (node.type) {
      case 'Pattern':
      case 'Group':
      case 'CapturingGroup':
        return this.sample(this.rng.pick(node.alternatives));
      case 'Alternative':
        return node.elements.map(element => this.sample(element)).join('');
      case 'Assertion':
        return '';
      case 'Quantifier': {
        const upper = Math.min(node.max, node.min + (this.rng.chance(0.1) ? 8 : 3));
        return Array.from({ length: this.rng.int(node.min, upper) }, () => this.sample(node.element)).join('');
      }
      case 'Character':
        return this.variant(this.unicode ? String.fromCodePoint(node.value) : String.fromCharCode(node.value));
      case 'CharacterSet':
      case 'CharacterClass':
        return this.member(node);
      default:
        return this.rng.pick(PIECES);
    }
  }

  private member(node: Node & { raw: string }): string {
    let test = this.members.get(node.raw);
    if (!test) {
      test = new RegExp(`^(?:${node.raw})$`, this.instance.flags.replace('g', ''));
      this.members.set(node.raw, test);
    }
    for (let attempt = 0; attempt < 40; attempt++) {
      const candidate = this.candidate(node);
      if (test.test(candidate)) return candidate;
    }
    return this.rng.pick(PIECES);
  }

  private candidate(node: Node): string {
    if (node.type === 'CharacterSet') return this.setCandidate(node);
    if (node.type !== 'CharacterClass' || node.negate || node.elements.length === 0 || !this.rng.chance(0.7)) return this.rng.pick(PIECES);
    const element = this.rng.pick(node.elements);
    if (element.type === 'Character') return String.fromCodePoint(element.value);
    if (element.type === 'CharacterClassRange') return String.fromCodePoint(this.rng.int(element.min.value, Math.min(element.max.value, element.min.value + 200)));
    if (element.type === 'CharacterSet') return this.setCandidate(element);
    return this.rng.pick(PIECES);
  }

  private setCandidate(node: Node & { type: 'CharacterSet' }): string {
    if (node.negate || !this.rng.chance(0.7)) return this.rng.pick(PIECES);
    switch (node.kind) {
      case 'digit':
        return this.rng.pick(['0', '1', '7', '9']);
      case 'space':
        return this.rng.pick([' ', '\t', '\n', ' ', ' ', '﻿', '　']);
      case 'word':
        return this.rng.pick(['a', 'Z', '_', '5', 's']);
      case 'property':
        return this.rng.pick(['é', '中', 'あ', 'カ', 'ไ', 'A', 'Ö', 'z', '٣', 'Ⅻ', '𝒜', 'ǅ', '𠀀', '𝟘', '1']);
      default:
        return this.rng.pick(PIECES);
    }
  }
}

function dropLoneSurrogates(text: string): string {
  let out = '';
  for (let index = 0; index < text.length; index++) {
    const unit = text.charCodeAt(index);
    const next = text.charCodeAt(index + 1);
    if (unit >= 0xd800 && unit <= 0xdbff && next >= 0xdc00 && next <= 0xdfff) {
      out += text[index] + (text[index + 1] as string);
      index++;
    } else if (unit < 0xd800 || unit > 0xdfff) {
      out += text[index];
    }
  }
  return out;
}

interface Result {
  t: string;
  m: number[];
  g?: (string | null)[][];
  o: [number, number, number];
  r?: string;
  s?: string[];
}

function evaluate(instance: Instance, operation: Operation, text: string): Result {
  const regex = new RegExp(instance.source, instance.flags);
  const all = new RegExp(instance.source, instance.flags.includes('g') ? instance.flags : `${instance.flags}g`);
  const matches = [...text.matchAll(all)];
  const result: Result = { t: text, m: matches.flatMap(match => [match.index, match.index + match[0].length]), o: [0, -1, -1] };
  if (matches.some(match => match.length > 1)) result.g = matches.map(match => match.slice(1).map(group => (group === undefined ? null : dropLoneSurrogates(group))));
  regex.lastIndex = 0;
  const test = regex.test(text);
  regex.lastIndex = 0;
  const exec = regex.exec(text);
  regex.lastIndex = 0;
  result.o = [test ? 1 : 0, exec ? exec.index : -1, text.search(regex)];
  if (operation.kind === 'replace') result.r = dropLoneSurrogates(text.replace(regex, operation.template));
  if (operation.kind === 'replaceFunction') result.r = dropLoneSurrogates(text.replace(regex, (...args) => `<${args[args.length - 2]}>`));
  if (operation.kind === 'split') result.s = text.split(regex).map(piece => dropLoneSurrogates(piece ?? ''));
  return result;
}

function inputsFor(instance: Instance, operation: Operation, count: number, rng: Rng): Result[] {
  const sampler = new Sampler(instance, rng);
  const matching: Result[] = [];
  const missing: Result[] = [];
  const spare: Result[] = [];
  for (let attempt = 0; attempt < count * 8 && matching.length + missing.length < count; attempt++) {
    const result = evaluate(instance, operation, sampler.input());
    if (result.m.length > 0 && matching.length < Math.ceil(count / 2)) matching.push(result);
    else if (result.m.length === 0 && missing.length < Math.floor(count / 2)) missing.push(result);
    else spare.push(result);
  }
  return [...matching, ...missing, ...spare].slice(0, count);
}

function propertyRanges(pattern: string): number[] {
  const runs = new RegExp(`(?:${pattern})+`, 'gu');
  const out: number[] = [];
  for (let block = 0; block < 0x110000; block += 0x10000) {
    const parts: string[] = [];
    for (let cp = block; cp < block + 0x10000; cp++) parts.push(cp >= 0xd800 && cp <= 0xdfff ? ' ' : String.fromCodePoint(cp));
    const width = block === 0 ? 1 : 2;
    for (const run of parts.join('').matchAll(runs)) {
      const first = block + run.index / width;
      const last = first + run[0].length / width - 1;
      if (out.length > 0 && out[out.length - 1] === first - 1) out[out.length - 1] = last;
      else out.push(first, last);
    }
  }
  return out;
}

function foldPairs(): string {
  const groups = new Map<string, number[]>();
  for (let cp = 0; cp <= 0x1ffff; cp++) {
    if (cp >= 0xd800 && cp <= 0xdfff) continue;
    const character = String.fromCodePoint(cp);
    for (const key of [`U${character.toUpperCase()}`, `L${character.toLowerCase()}`, `F${character.toUpperCase().toLowerCase()}`]) {
      const group = groups.get(key) ?? [];
      group.push(cp);
      groups.set(key, group);
    }
  }
  const pairs = new Set<string>();
  for (const group of groups.values()) {
    if (group.length < 2 || group.length > 8) continue;
    for (const first of group) for (const second of group) if (first < second) pairs.add(`${first.toString(16)}:${second.toString(16)}`);
  }
  const verdict = (first: number, second: number, flags: string): string => {
    if (flags === 'i' && (first > 0xffff || second > 0xffff)) return '-';
    const literal = flags === 'i' ? `\\u${first.toString(16).padStart(4, '0')}` : `\\u{${first.toString(16)}}`;
    return new RegExp(`^[${literal}]$`, flags).test(String.fromCodePoint(second)) ? '1' : '0';
  };
  return [...pairs]
    .map(pair => pair.split(':').map(part => Number.parseInt(part, 16)) as [number, number])
    .sort((left, right) => left[0] - right[0] || left[1] - right[1])
    .map(([first, second]) => `${first.toString(16)}:${second.toString(16)}:${verdict(first, second, 'i')}${verdict(first, second, 'iu')}`)
    .join(' ');
}

function main(): void {
  const { regexes } = JSON.parse(readFileSync(join(import.meta.dir, '../text/reference-regexes.json'), 'utf8')) as { regexes: Entry[] };
  const rng = createRng(0xd03);
  const lines: string[] = [];
  regexes.forEach((entry, index) => {
    const callSite = operation(entry);
    const instances = instancesOf(entry, index, rng);
    const perInstance = Math.max(MINIMUM_INPUTS_PER_INSTANCE, Math.ceil(INPUTS_PER_ENTRY / instances.length));
    for (const instance of instances) {
      const record = { entry: index, location: entry.location, source: instance.source, flags: instance.flags, operation: callSite, inputs: inputsFor(instance, callSite, perInstance, rng) };
      lines.push(JSON.stringify(record));
    }
  });
  const properties = ['\\p{L}', '\\p{N}', '\\p{Lu}', '\\p{Script=Han}', '\\p{Script=Hiragana}', '\\p{Script=Katakana}', '\\p{Script=Thai}'];
  const unicode = { runtime: `bun ${Bun.version}`, properties: Object.fromEntries(properties.map(pattern => [pattern, propertyRanges(pattern)])), foldPairs: foldPairs() };
  writeFileSync(join(import.meta.dir, 'cases.json'), `{"unicode":${JSON.stringify(unicode)},\n"cases":[\n${lines.join(',\n')}\n]}\n`);
}

main();
