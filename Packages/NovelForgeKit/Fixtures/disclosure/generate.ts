import { plugin } from 'bun';
import { createHash } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');

const server = join(platformRepo, 'apps/novel-forge-server/src');
const outDir = dirname(fileURLToPath(import.meta.url));
const classes = await import(join(server, 'classes/app-error-code.ts'));

// The policy builds its patterns with `new RegExp(source)`; recording the source as passed keeps it free of `RegExp.prototype.source`'s escaping.
const rawSources = new WeakMap<RegExp, string>();
globalThis.RegExp = new Proxy(RegExp, {
  construct(target, args) {
    const made = Reflect.construct(target, args) as RegExp;
    if (typeof args[0] === 'string') rawSources.set(made, args[0]);
    return made;
  },
}) as RegExpConstructor;

type Row = Record<string, unknown>;
type Condition = { op: string; args: unknown[] } | undefined;
type Column = { column: string };

let readerKnowsLabel = false;
const common: Record<string, unknown> = {};
const tables = new Map<string, unknown>();

function table(name: string): unknown {
  if (!tables.has(name)) tables.set(name, new Proxy({ name } as Row, { get: (target, column: string) => (column === 'name' ? target.name : { column }) }));
  return tables.get(name);
}

plugin({
  name: 'disclosure-fixture-stubs',
  setup(build) {
    const op = (name: string) => (...args: unknown[]) => ({ op: name, args });
    build.module('drizzle-orm', () => ({
      exports: {
        and: op('and'), or: op('or'), eq: op('eq'), lt: op('lt'), lte: op('lte'), gt: op('gt'), inArray: op('inArray'), notInArray: op('notInArray'), isNull: op('isNull'),
        isNotNull: op('isNotNull'), asc: op('asc'), desc: op('desc'), sql: (strings: TemplateStringsArray, ...values: unknown[]) => ({ op: 'sql', args: [[...strings], values] }),
      },
      loader: 'object',
    }));
    build.module('@server/database', () => ({ exports: { schema: new Proxy({}, { get: (_, name: string) => table(name) }) }, loader: 'object' }));
    build.module('@server/database/schemas', () => ({ exports: {}, loader: 'object' }));
    build.module('@server/classes', () => ({ exports: { AppErrorCode: classes.AppErrorCode }, loader: 'object' }));
    build.module('@server/constants', () => ({ exports: { APP_NAME: 'fixture' }, loader: 'object' }));
    build.module('@shadow-library/common', () => ({
      exports: {
        Logger: { getLogger: () => ({ warn() {}, info() {}, error() {}, debug() {} }) },
        Config: { get: (key: string) => (key === 'knowledge.reader-knows-label' ? readerKnowsLabel : undefined) },
      },
      loader: 'object',
    }));
    build.module('@server/common', () => ({ exports: common, loader: 'object' }));
    build.onResolve({ filter: /\/chapter-shift$/ }, () => ({ path: 'chapter-shift', namespace: 'stub' }));
    build.onLoad({ filter: /.*/, namespace: 'stub' }, () => ({ contents: 'export const shiftChapterNumber = () => 0;', loader: 'js' }));
  },
});

for (const file of ['reveal-term', 'term-text', 'brief-volume', 'plan-world', 'unlock-condition', 'open-canon', 'knowledge-contract', 'reveal-rule', 'bible-doc-title']) {
  Object.assign(common, await import(join(server, `common/${file}.ts`)));
}
const view = await import(join(server, 'modules/bible/fact/knowledge-view.ts'));
const disclosure = await import(join(server, 'modules/bible/fact/writer-disclosure-policy.ts'));
const provisional = await import(join(server, 'common/provisional-knowledge.ts'));
const revealTerm = await import(join(server, 'common/reveal-term.ts'));
const openCanon = await import(join(server, 'common/open-canon.ts'));
const planWorld = await import(join(server, 'common/plan-world.ts'));
const briefVolume = await import(join(server, 'common/brief-volume.ts'));

// An in-memory database that answers the reference's drizzle reads and writes by evaluating their conditions on plain rows.
function codePointCompare(left: string, right: string): number {
  const a = [...left].map(char => char.codePointAt(0) as number);
  const b = [...right].map(char => char.codePointAt(0) as number);
  for (let i = 0; i < Math.min(a.length, b.length); i++) if (a[i] !== b[i]) return (a[i] as number) - (b[i] as number);
  return a.length - b.length;
}

function compare(left: unknown, right: unknown): number {
  if (typeof left === 'string' && typeof right === 'string') return codePointCompare(left, right);
  return (left as number) < (right as number) ? -1 : (left as number) > (right as number) ? 1 : 0;
}

const camel = (snake: string): string => snake.replace(/_(\w)/g, (_, letter: string) => letter.toUpperCase());

function holds(condition: Condition, row: Row, excluded?: Row): boolean {
  if (!condition) return true;
  const [first, second] = condition.args as [Column, unknown];
  const value = (): unknown => row[first.column];
  const present = (candidate: unknown): boolean => candidate !== null && candidate !== undefined;
  switch (condition.op) {
    case 'and':
      return condition.args.every(part => holds(part as Condition, row, excluded));
    case 'or':
      return condition.args.some(part => holds(part as Condition, row, excluded));
    case 'eq':
      return present(value()) && present(second) && value() === second;
    case 'lt':
      return present(value()) && present(second) && compare(value(), second) < 0;
    case 'lte':
      return present(value()) && present(second) && compare(value(), second) <= 0;
    case 'gt':
      return present(value()) && present(second) && compare(value(), second) > 0;
    case 'inArray':
      return present(value()) && (second as unknown[]).includes(value());
    case 'notInArray':
      return present(value()) && !(second as unknown[]).includes(value());
    case 'isNull':
      return !present(value());
    case 'isNotNull':
      return present(value());
    case 'sql': {
      const [strings, values] = condition.args as [string[], Column[]];
      const match = /^excluded\.(\w+) < $/.exec(strings[0] ?? '');
      if (!match || !excluded || values.length !== 1) throw new Error(`unsupported sql ${strings.join('?')}`);
      return compare(excluded[camel(match[1] as string)], row[(values[0] as Column).column]) < 0;
    }
    default:
      throw new Error(`unsupported condition ${condition.op}`);
  }
}

function ordered(rows: Row[], orderBy: unknown): Row[] {
  if (!orderBy) return rows;
  const spec = orderBy as { op?: string; args?: [Column]; column?: string };
  const column = spec.column ?? (spec.args as [Column])[0].column;
  const direction = spec.op === 'desc' ? -1 : 1;
  return [...rows].sort((left, right) => direction * compare(left[column], right[column]));
}

function project(rows: Row[], columns: Record<string, Column>): Row[] {
  return rows.map(row => Object.fromEntries(Object.entries(columns).map(([name, column]) => [name, row[column.column]])));
}

function fakeDb(data: Record<string, Row[]>) {
  const rows = (name: string): Row[] => (data[name] ??= []);
  const query = new Proxy({} as Row, {
    get: (_, name: string) => ({
      findMany: async ({ where, orderBy }: { where?: Condition; orderBy?: unknown } = {}) => ordered(rows(name).filter(row => holds(where, row)), orderBy).map(row => ({ ...row })),
      findFirst: async ({ where, orderBy }: { where?: Condition; orderBy?: unknown } = {}) => {
        const found = ordered(rows(name).filter(row => holds(where, row)), orderBy)[0];
        return found && { ...found };
      },
    }),
  });
  const thenable = <T>(run: () => T) => {
    let result: { value: T } | undefined;
    const once = (): T => (result ??= { value: run() }).value;
    return { then: (resolve: (value: T) => unknown, reject: (error: unknown) => unknown) => Promise.resolve().then(once).then(resolve, reject) };
  };
  return {
    query,
    insert: (target: Row) => ({
      values: (incoming: Row[]) => ({
        onConflictDoUpdate: ({ target: keys, set, setWhere }: { target: Column[]; set: Row; setWhere: Condition }) =>
          thenable(() => {
            const seen = new Set<string>();
            for (const row of incoming) {
              const identity = keys.map(key => String(row[key.column])).join(':');
              if (seen.has(identity)) throw new Error('ON CONFLICT DO UPDATE command cannot affect row a second time');
              seen.add(identity);
              const existing = rows(target.name as string).find(candidate => keys.every(key => candidate[key.column] === row[key.column]));
              if (!existing) {
                rows(target.name as string).push({ source: 'manual', status: 'committed', note: null, draftRevision: null, ...row });
                continue;
              }
              if (!holds(setWhere, existing, row)) continue;
              for (const [column, value] of Object.entries(set)) {
                const expression = value as { op?: string; args?: [string[], unknown[]] };
                const excluded = expression.op === 'sql' ? /^excluded\.(\w+)$/.exec((expression.args as [string[]])[0][0] ?? '') : null;
                if (expression.op === 'sql' && !excluded) throw new Error('unsupported set expression');
                existing[column] = excluded ? row[camel(excluded[1] as string)] : value;
              }
            }
          }),
      }),
    }),
    delete: (target: Row) => ({
      where: (where: Condition) => {
        const run = (): Row[] => {
          const all = rows(target.name as string);
          const removed = all.filter(row => holds(where, row));
          data[target.name as string] = all.filter(row => !removed.includes(row));
          return removed;
        };
        let removed: Row[] | undefined;
        const once = (): Row[] => (removed ??= run());
        return { ...thenable(once), returning: (columns: Record<string, Column>) => thenable(() => project(once(), columns)) };
      },
    }),
    update: (target: Row) => ({
      set: (values: Row) => ({
        where: (where: Condition) => {
          const run = (): Row[] => {
            const changed = rows(target.name as string).filter(row => holds(where, row));
            for (const row of changed) Object.assign(row, Object.fromEntries(Object.entries(values).filter(([column]) => column !== 'updatedAt')));
            return changed;
          };
          let changed: Row[] | undefined;
          const once = (): Row[] => (changed ??= run());
          return { ...thenable(once), returning: (columns: Record<string, Column>) => thenable(() => project(once(), columns)) };
        },
      }),
    }),
  };
}

interface Rng {
  next(): number;
  int(min: number, max: number): number;
  chance(p: number): boolean;
  pick<T>(items: readonly T[]): T;
  some<T>(items: readonly T[], max: number): T[];
}

function createRng(seed: number): Rng {
  let state = seed | 0;
  const next = (): number => {
    state = (state + 0x6d2b79f5) | 0;
    let t = Math.imul(state ^ (state >>> 15), 1 | state);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  const rng: Rng = {
    next,
    int: (min, max) => min + Math.floor(next() * (max - min + 1)),
    chance: p => next() < p,
    pick: items => items[Math.floor(next() * items.length)] as never,
    some: (items, max) => Array.from({ length: rng.int(0, max) }, () => rng.pick(items)),
  };
  return rng;
}

type Encoded = string | number[];

const encode = (text: string): Encoded => (text.isWellFormed() ? text : Array.from({ length: text.length }, (_, i) => text.charCodeAt(i)));

const write = (name: string, value: unknown): void => writeFileSync(join(outDir, name), `${JSON.stringify(value)}\n`);

const rng = createRng(0x0d15);

// Inputs. Astral letters and U+0345 sit next to terms because JavaScriptCore and bun disagree there; the fixture holds bun's answer.
const NFC = 'café';
const NFD = 'café';
const TERMS = [
  'forgery', 'Forgery', 'FORGERY', 'planted', 'Will', 'will', 'tide court', 'Tide Court', 'ox', 'ax', 'heir', 'lost heir', 'a.b*c', '(x)', '[ref]', 'c++', 'what?', '$100', '^up',
  'a|b', 'back\\slash', '{brace}', 'ﬁre', 'fire', 'straße', 'STRASSE', 'İstanbul', 'istanbul', 'Kelvin', 'kelvin', 'σοφία', 'ΣΟΦΊΑ', 'ὀδυσσεύς', '𐐀ngel', '𐐨ngel',
  'ǅemal', '灯塔', '王国', 'ภาษา', ' padded ', ' nbsp ', 'xͅy', 'ͅͅͅ', 'ιota', 'Ιota', '"\u0301quoted', 'x—\u0301y', 'ab', '', '   ', NFC, NFD, 'ée', 'lamp_rank',
  'fact:lamp', 'forge', 'forgery planted', 'ledger', 'Elias', 'twin', '𝒜sh', 'x²y', '½ cup', 'it’s', "it's", 'a-b', 'a—b', 'ok\nnow', 'tab\tbed', 'ſtar', 'ﬆar', 'Ǆa',
];
const BOUNDARIES = [
  '', '', ' ', ' ', 'x', '_', '1', '𝒜', '𐐨', '😀', 'ͅ', 'é', '́', ' ', '-', "'", '’', '*', '**', '__', '`', '\n', '\r\n', '\t', '。', '٣', '²', 'ſ', 'K', 'K',
];
const WORDS = [
  'the', 'ledger', 'in', 'study', 'is', 'a', 'forgery', 'planted', 'by', 'Elias', 'Marlow', 'owed', 'gambling', 'debt', 'bell', 'rings', 'only', 'for', 'drowned', 'each', 'ring',
  'costs', 'ringer', 'year', 'keeper', 'lets', 'lamp', 'go', 'dark', 'Mara', 'heir', 'tide', 'court', 'harbour', 'Will', 'will', 'twin', 'ox', 'none', 'None', 'Reconciliation',
  "keeper's", 'keeper’s', '"last"', '“last”', 'one—two', 'x-y', '**bold**', '_soft_', '__deep__', '`code`', NFC, NFD, 'ΣΟΦΊΑ', 'σοφία', 'İstanbul', '𐐀ngel', '𝒜sh', 'xͅy',
  'a.b*c', '(x)', '[ref]', 'c++', '$100', 'back\\slash', 'ﬁre', 'straße', '灯塔守护者最终熄灭了灯火', '王国', 'ภาษาไทยดี', 'ひかり', 'カタカナ', '😀', '42', '7th', 'lamp_rank', '"\u0301quoted', '—\u0301', 'it’\u0301s', '«\u0301»',
];
const GAPS = [' ', ' ', ' ', '  ', '\n', '\r\n', '\n\n', '\t', '　', ' ', ' ', '\u000b', '\u0085', '﻿'];
const ENDS = ['.', '.', '!', '?', '', '…', '。', '！', '...', '?!', ';', ',', ':', '. ', '.\n'];
const LIST_MARKERS = ['', '', '', '- ', '* ', '+ ', '> ', '1. ', '12) ', '# ', '###### ', '####### ', '  - ', '-\t', '-x '];
const FIELDS = ['prose', 'summary', 'state', 'entity', 'reference', 'bible_page', 'heading', 'plan', 'style', 'writer_line', 'knowledge', 'note', 'plugin'] as const;
const FACT_KEYS = ['ledger_forgery', 'motive_debt', 'heir', 'lost_heir', 'service_door', 'secret_twin', 'bell_price', 'lamp_rank', 'a.b', 'x+y', `f_${NFC}`, `f_${NFD}`, 'F_É', 'lamp', 'fact'];
const ENTITY_KEYS = ['mira', 'amara', 'tobin', 'elias', NFC, NFD, 'ghost'];
const VOLUME_KEYS = ['v1', 'v2', 'v3', '', 'unknown', NFC, NFD];
const MILESTONE_KEYS = ['m1', 'm2', 'm3', `m_${NFC}`, `m_${NFD}`];

function sentence(rng: Rng): string {
  const words = Array.from({ length: rng.int(1, 6) }, () => rng.pick(WORDS));
  return words.map((word, index) => (index === 0 ? word : `${rng.chance(0.15) ? rng.pick(GAPS) : ' '}${word}`)).join('') + rng.pick(ENDS);
}

function passage(rng: Rng, max = 3): string {
  const count = rng.int(1, max);
  let out = rng.pick(LIST_MARKERS);
  for (let i = 0; i < count; i++) out += (i > 0 ? rng.pick([' ', ' ', '\n', '\n\n', '  ', '\r\n']) : '') + sentence(rng);
  return out;
}

function maybe<T>(rng: Rng, value: () => T, p = 0.6): T | null {
  return rng.chance(p) ? value() : null;
}

function variant(rng: Rng, source: string): string {
  switch (rng.int(0, 11)) {
    case 0:
      return source.toUpperCase();
    case 1:
      return source.toLowerCase();
    case 2:
      return source.replace(/ /g, () => rng.pick([' ', '\n  ', '\t', '  ', ' ']));
    case 3:
      return source.replace(/\S+/g, word => (rng.chance(0.3) ? `${rng.pick(['**', '_', '__', '`', '*'])}${word}${rng.pick(['**', '_', '__', '`', '*'])}` : word));
    case 4:
      return source.replace(/["']/g, quote => rng.pick(quote === '"' ? ['“', '”', '„', '«', '»'] : ['’', '‘', '`'])).replace(/[-—]/g, () => rng.pick(['-', '‐', '‑', '–', '—']));
    case 5:
      return source.replace(/[.!?。！？…]+\s*$/u, rng.pick(['!', '…', '', '?!', '.']));
    case 6: {
      const pieces = source.split(/(?<=[.!?。！？])\s+|\n+/u);
      return rng.pick(pieces);
    }
    case 7:
      return source.slice(0, rng.int(0, source.length));
    case 8:
      return `${rng.pick(LIST_MARKERS)}${source}`;
    default:
      return source;
  }
}

function surround(rng: Rng, core: string): string {
  return `${rng.pick(BOUNDARIES)}${core}${rng.pick(BOUNDARIES)}`;
}

interface Fact {
  factKey: string;
  text: string;
  constraintNote?: string | null;
  writerNote?: string | null;
  terms?: string[] | null;
  allowedClues?: string[] | null;
  subjects?: string[] | null;
  source?: string;
  disclosedInChapter?: number | null;
  revealChapter?: number | null;
  unlock?: { all: Row[] } | null;
}

function factLike(rng: Rng, factKey: string = rng.pick(FACT_KEYS)): Fact {
  const terms = maybe(rng, () => rng.some(TERMS, 3), 0.8);
  const clues = maybe(rng, () => [...rng.some([...WORDS, ...TERMS], 2).map(word => `Ink on the ${word}.`), ...rng.some(['', ' ', '  Elias avoids the study.  ', 'Elias avoids the study.'], 2)]);
  const fact: Fact = { factKey, text: rng.chance(0.15) ? rng.pick(['', ' ', 'ab', 'Ashwright', '灯塔', 'x']) : passage(rng) };
  if (rng.chance(0.85)) fact.constraintNote = maybe(rng, () => (rng.chance(0.3) ? rng.pick(['None', 'Extraordinarily', ' ', '']) : passage(rng, 2)));
  if (rng.chance(0.85)) fact.writerNote = maybe(rng, () => rng.pick(['Elias steers away from the study.', '   ', '', 'Keep calm — breathe.', 'knowledge leak: none here', sentence(rng)]));
  if (rng.chance(0.9)) fact.terms = terms;
  if (rng.chance(0.8)) fact.allowedClues = clues;
  return fact;
}

const FACT_FIELDS = ['factKey', 'text', 'constraintNote', 'writerNote', 'terms', 'allowedClues', 'subjects', 'source', 'disclosedInChapter', 'revealChapter', 'unlock'] as const;

// A fact as the Swift side reads it: an absent field and null are the same there, and both mean the same to the reference.
const factRow = (fact: Fact): unknown[] => FACT_FIELDS.map(field => fact[field] ?? null);

const termCases: unknown[] = [];
for (const term of TERMS) {
  for (const global of [false, true]) {
    const pattern: RegExp | null = revealTerm.revealTermPattern(term, global);
    const probes: unknown[] = [];
    if (!global) {
      const core = term.trim();
      const texts = [core, core.toUpperCase(), core.toLowerCase(), `${core}s`, `x${core}`, ...Array.from({ length: 10 }, () => surround(rng, rng.chance(0.5) ? core : variant(rng, core)))];
      for (const value of texts) {
        const match = pattern?.exec(value) ?? null;
        probes.push([value, match ? [match.index, match[0].length] : null]);
      }
    }
    termCases.push([term, global, pattern ? rawSources.get(pattern) : null, pattern ? pattern.flags : null, probes]);
  }
}

const clueCases = Array.from({ length: 150 }, () => {
  const clues = rng.chance(0.1) ? null : Array.from({ length: rng.int(0, 4) }, () => surround(rng, rng.chance(0.6) ? `${rng.pick(WORDS)} ${rng.pick(TERMS).trim()}` : sentence(rng)));
  const terms = rng.chance(0.1) ? null : rng.some(TERMS, 3);
  const before = rng.chance(0.2) ? null : rng.chance(0.5) ? { allowedClues: clues, terms } : { allowedClues: rng.chance(0.5) ? clues : rng.some(WORDS, 2), terms: rng.chance(0.5) ? terms : rng.some(TERMS, 2) };
  return [clues, terms, revealTerm.cluesNamingTerms(clues, terms), before, revealTerm.changedCluesNamingTerms(before, { allowedClues: clues, terms })];
});

const openCanonCases = [null, -5, -1, 0, 1, 2, 3, 100].map(chapter => [chapter, openCanon.isOpenCanon(chapter)]);

const LEAK_LINES = [
  'knowledge leak: "forgery" exposes [ledger_forgery] — …a forgery…',
  '[soft] knowledge leak: "planted" exposes [ledger_forgery]',
  'KNOWLEDGE LEAK: the cast names motive_debt',
  'KNOWLEDGE LEAK: "twin" exposes [secret_twin]',
  'İ knowledge leak: over-connection: the clues are linked to heir',
  'İİknowledge leak: 😀"x" exposes [heir]',
  'İknowledge leak: 😀 over-connection: lost_heir',
  'knowledge leak:   over-connection: Mara links the bell',
  'knowledge leak: "" exposes [heir]',
  'knowledge leak: "a]b" exposes [heir]',
  'knowledge leak: "x" exposes []',
  'knowledge leak: "unterminated exposes [heir',
  'note: knowledge leak: lamp_rank and lamp are both named',
  'knowledge leak: Over-Connection: twin',
  'knowledge leak: ',
  'knowledge leak:',
  'knowledge leak: "forgery" exposes [ghost_fact] — nothing',
  'knowledge leak: "Forgery" exposes [ledger_forgery]\r',
  'knowledge leak: the cast names loop_fact',
  'knowledge leak: "chain" exposes [chain_a]',
];

function leakText(rng: Rng): string {
  const lines = Array.from({ length: rng.int(1, 4) }, () => (rng.chance(0.55) ? rng.pick(LEAK_LINES) : sentence(rng)));
  return lines.join(rng.pick(['\n', '\n', '\r\n', '\n\n']));
}

const leakCases = Array.from({ length: 60 }, () => {
  const facts = Array.from({ length: rng.int(0, 4) }, () => factLike(rng));
  const pieces = facts.flatMap(fact => [...(fact.terms ?? []).map(term => surround(rng, rng.chance(0.7) ? term.trim() : variant(rng, term.trim()))), variant(rng, fact.text)]);
  const body = Array.from({ length: rng.int(1, 6) }, () => (pieces.length > 0 && rng.chance(0.6) ? rng.pick(pieces) : sentence(rng))).join(rng.pick([' ', '\n', ' 😀 ', '𝒜']));
  const padded = rng.chance(0.2) ? `${'😀'.repeat(rng.int(28, 31))}${body}${'𝒜'.repeat(rng.int(28, 31))}` : body;
  const prescan = Array.from({ length: rng.int(0, 3) }, () => ({ factKey: rng.chance(0.8) && facts.length > 0 ? rng.pick(facts).factKey : rng.pick(FACT_KEYS), term: rng.pick(TERMS) }));
  const judgeIssues = Array.from({ length: rng.int(0, 3) }, () => rng.pick([...LEAK_LINES.map(line => line.slice(line.indexOf(':') + 1)), sentence(rng), `over-connection: ${rng.pick(FACT_KEYS)}`, `  OVER-CONNECTION: ${rng.pick(FACT_KEYS)} and ${rng.pick(FACT_KEYS)}`, '']));
  const issues: { factKey: string; term: string; excerpt: string }[] = view.scanKnowledgeLeaks(padded, facts);
  return [
    facts.map(factRow),
    padded,
    issues.map(issue => [issue.factKey, issue.term, encode(issue.excerpt)]),
    prescan.map(leak => [leak.factKey, leak.term]),
    judgeIssues,
    view.writerSafeLeakLines(prescan, judgeIssues, facts),
  ];
});

const renderCases = Array.from({ length: 25 }, () => {
  const facts = Array.from({ length: rng.int(0, 4) }, () => factLike(rng));
  const pov = Array.from({ length: rng.int(0, 3) }, () => ({ entityKey: rng.pick(ENTITY_KEYS), name: rng.pick(['Mira', 'Amara', '', 'Tobin', NFD]) }));
  const known = new Set(rng.some(FACT_KEYS, 3));
  const learns = new Set(rng.some(FACT_KEYS, 3));
  const split = view.splitKnowledgeView(facts, known, learns);
  const keys = (list: Fact[]): string[] => list.map(fact => fact.factKey);
  return [
    facts.map(factRow),
    pov.map(member => [member.entityKey, member.name]),
    [...known],
    [...learns],
    [keys(split.known), keys(split.reveals), keys(split.hidden)],
    view.renderReaderKnows(facts, pov),
    view.renderJudgeReaderKnows(facts),
    view.renderKnownFacts(facts),
    view.renderChapterReveals(facts),
    view.renderHiddenConstraints(facts),
    keys(view.withWriterNotes(facts)),
    view.renderForbiddenFacts(facts),
  ];
});

write('terms.json', { termCases, clueCases, openCanonCases, leakCases, renderCases });

const REFS = [
  'volume:v1', 'volume:v2', 'volume:v3', 'volume:', 'volume', 'volume:unknown', `volume:${NFC}`, `volume:${NFD}`, 'Volume:v3', 'volume:v1:extra', 'chapter:3', 'chapter: 3 ', 'chapter:0x3',
  'chapter:3.0', 'chapter:3.5', 'chapter:1e1', 'chapter:-1', 'chapter:', 'chapter:Infinity', 'chapter:-Infinity', 'chapter:9007199254740993', 'chapter:1e400', 'chapter:1e-400',
  'chapter:0b11', 'chapter:0o7', 'chapter:+4', 'chapter:-0', 'chapter:٣', 'chapter:３', 'chapter: 4 ', 'chapter:0x', 'chapter:.5', 'chapter:5.', 'chapter:1_0', 'chapter:x',
  'chapter:00012', 'chapter:0X1F', 'chapter:+0x1', 'bible_doc:project/timeline', 'bible_doc:project/open-questions', 'bible_doc:story_state/volume-plan', 'bible_doc:story_state/volumes',
  'bible_doc:plot/escalation-map', 'bible_doc:project/premise', 'bible_doc:project', 'bible_doc:project/timeline/x', 'bible_doc:Project/timeline', 'bible_doc:/timeline',
  'bible_doc:project/Timeline', 'bible_doc:', 'entity:mira', 'x', '', ':', 'fact:heir', 'thread:t1', 'chapter:2:3',
];
const STATE_KEYS = ['establishedFacts', 'forgery', 'planted', 'Forgery', 'hp', '0', '1', '10', '01', '__proto__', 'constructor', 'notes', 'lamp_rank', 'fact:heir', '', 'x (2)', '[withheld]'];

function stateValue(rng: Rng, depth: number, pieces: string[]): unknown {
  const roll = rng.int(0, depth > 2 ? 3 : 6);
  if (roll === 0) return rng.pick([null, true, false, 0, 3, -1.5]);
  if (roll <= 2) return pieces.length > 0 && rng.chance(0.6) ? rng.pick(pieces) : sentence(rng);
  if (roll === 3) return rng.pick(['', ' ', 'knowledge leak: "forgery" exposes [ledger_forgery]']);
  if (roll === 4) return Array.from({ length: rng.int(0, 3) }, () => stateValue(rng, depth + 1, pieces));
  const out: Row = {};
  for (let i = rng.int(0, 4); i > 0; i--) {
    const key = rng.chance(0.4) && pieces.length > 0 ? rng.pick(pieces).slice(0, 30) : rng.pick(STATE_KEYS);
    const value = key === 'establishedFacts' && rng.chance(0.8) ? Array.from({ length: rng.int(0, 4) }, () => (rng.chance(0.8) ? rng.pick([...pieces, sentence(rng)]) : rng.pick([1, null, ['x']]))) : stateValue(rng, depth + 1, pieces);
    Object.defineProperty(out, key, { value, enumerable: true, writable: true, configurable: true });
  }
  return out;
}

// A writer note quoting a leak finding that cites its own fact makes the reference recurse without end; bun throws a RangeError.
const CYCLIC_NOTE: Fact = { factKey: 'loop_fact', text: 'The loop is endless.', writerNote: 'knowledge leak: loop_fact again', terms: ['loop'] };
const CHAINED_NOTES: Fact[] = [
  { factKey: 'chain_a', text: 'The chain starts here.', writerNote: 'knowledge leak: chain_b is hinted', terms: ['chain'] },
  { factKey: 'chain_b', text: 'The chain ends there.', writerNote: 'Stay calm — knowledge leak: over-connection: none', terms: ['links'] },
];

function probeText(rng: Rng, input: { lockedFacts: Fact[]; plannerOnly: string[]; plannerPages: string[] }): string {
  const sources = [
    ...input.lockedFacts.flatMap(fact => [fact.text, fact.constraintNote ?? '', `fact:${fact.factKey}`, fact.factKey, ...(fact.terms ?? [])]),
    ...input.plannerOnly,
    ...input.plannerPages,
  ].filter(text => text.trim() !== '');
  const parts = Array.from({ length: rng.int(1, 5) }, () => {
    const roll = rng.next();
    if (roll < 0.55 && sources.length > 0) return surround(rng, variant(rng, rng.pick(sources)));
    if (roll < 0.7) return rng.pick(LEAK_LINES);
    return sentence(rng);
  });
  return parts.join(rng.pick([' ', ' ', '\n', '\n\n', ' — ']));
}

function plannerPage(rng: Rng): string {
  const lines = Array.from({ length: rng.int(1, 5) }, () => (rng.chance(0.3) ? `## ${rng.pick(WORDS)}` : `${rng.pick(LIST_MARKERS)}${sentence(rng)}`));
  return lines.join('\n');
}

interface PolicyInput {
  chapter: number;
  lockedFacts: Fact[];
  plannerOnly: string[];
  plannerPages: string[];
  volumeOrdinals: Map<string, number>;
  currentVolumeOrdinal: number | null;
}

type Policy = InstanceType<typeof disclosure.WriterDisclosurePolicy>;

function attempt<T>(run: () => T): T | ['throws'] {
  try {
    return run();
  } catch (error) {
    if (!(error instanceof RangeError)) throw error;
    return ['throws'];
  }
}

function withholdings(policy: Policy): unknown[] {
  const list = (policy as unknown as { withholdings: { pattern: RegExp; weight: number; fields?: Set<string> }[] }).withholdings;
  const lines = list.map(entry => `${rawSources.get(entry.pattern)}\u0001${entry.pattern.flags}\u0001${entry.weight}\u0001${entry.fields ? 1 : 0}`);
  return [list.length, createHash('sha256').update(lines.join('\u0000')).digest('hex')];
}

function exercise(rng: Rng, policy: Policy, input: Omit<PolicyInput, 'chapter' | 'volumeOrdinals' | 'currentVolumeOrdinal'>): unknown[] {
  const scrubs = Array.from({ length: rng.int(2, 4) }, () => {
    const text = rng.chance(0.06) ? rng.pick(['', ' ', 'knowledge leak: anything']) : probeText(rng, input);
    const field = rng.pick(FIELDS);
    return [text, field, attempt(() => policy.scrub(text, field))];
  });
  const pieces = input.lockedFacts.flatMap(fact => [fact.text, ...(fact.terms ?? [])]).filter(text => text !== '');
  const states = Array.from({ length: rng.int(0, 2) }, () => {
    const value = stateValue(rng, 0, pieces);
    const max = rng.pick([0, 1, 2, 5, -1]);
    return [value, max, attempt(() => policy.scrubState(value, max))];
  });
  const refs = rng.some(REFS, 8).map(ref => [ref, policy.canResolve(ref)]);
  const opened = [null, -1, 0, 1, 4, 5, 6, 12].map(chapter => policy.opensBy(chapter));
  const bodies = Array.from({ length: rng.int(0, 2) }, () => {
    const body = probeText(rng, input);
    return [body, attempt(() => policy.leakLines(body))];
  });
  const leakLines = Array.from({ length: rng.int(0, 2) }, () => {
    const line = rng.pick([`remove or avoid "${rng.pick(TERMS)}" — ${probeText(rng, input)}`, `${rng.pick(TERMS)} — x — ${sentence(rng)}`, 'no dash here', ` — ${probeText(rng, input)}`]);
    return [line, attempt(() => policy.scrubLeakLine(line))];
  });
  const messages = rng.chance(0.3) ? Array.from({ length: rng.int(0, 2) }, () => probeText(rng, input)) : null;
  const scrubbedPolicy = attempt(() => policy.scrubPolicy(messages === null ? {} : { systemMessages: messages.map(content => ({ role: 'system', content })) }));
  const policyOut = Array.isArray(scrubbedPolicy) ? scrubbedPolicy : (scrubbedPolicy.systemMessages ?? null)?.map((message: { content: string }) => message.content) ?? null;
  const counts = [...policy.withheld.entries()];
  return [withholdings(policy), scrubs, states, refs, opened, policy.allowedClues(), bodies, leakLines, messages, policyOut, counts];
}

const policyCases: unknown[] = [];
for (let index = 0; index < 110; index++) {
  const planner = index % 23 === 0;
  const lockedFacts = Array.from({ length: rng.int(0, 3) }, () => factLike(rng));
  if (index % 37 === 5) lockedFacts.push(CYCLIC_NOTE);
  if (index % 29 === 3) lockedFacts.push(...CHAINED_NOTES);
  const input: PolicyInput = {
    chapter: rng.int(-1, 9),
    lockedFacts,
    plannerOnly: Array.from({ length: rng.int(0, 3) }, () => (rng.chance(0.25) ? rng.pick(['He lives on.', 'Bittersweet', 'None', 'Quiet harbour', '重逢', '灯塔守护者最终熄灭了灯火', ' ', '']) : passage(rng))),
    plannerPages: Array.from({ length: rng.int(0, 2) }, () => plannerPage(rng)),
    volumeOrdinals: new Map(rng.some(VOLUME_KEYS, 3).map(key => [key, rng.int(0, 4)])),
    currentVolumeOrdinal: rng.chance(0.3) ? null : rng.int(0, 4),
  };
  const policy: Policy = planner ? disclosure.WriterDisclosurePolicy.planner() : new disclosure.WriterDisclosurePolicy(input);
  const inputRow = planner ? null : [input.chapter, input.lockedFacts.map(factRow), input.plannerOnly, input.plannerPages, [...input.volumeOrdinals], input.currentVolumeOrdinal];
  const used = planner ? { lockedFacts: [], plannerOnly: [], plannerPages: [] } : input;
  policyCases.push([inputRow, exercise(rng, policy, used)]);
}

// Passages that differ only in spacing share a pattern but not a weight; which one the de-duplication keeps decides the order.
const SHARED_PATTERN_INPUTS: Omit<PolicyInput, 'chapter' | 'volumeOrdinals' | 'currentVolumeOrdinal'>[] = [
  { lockedFacts: [], plannerOnly: [], plannerPages: ['Mara walks the long harbour wall.', 'Mara  walks the long\n\tharbour wall!', 'Mara walks the long harbour'] },
  { lockedFacts: [{ factKey: 'wall_walk', text: 'Mara walks the long harbour wall.' }], plannerOnly: ['Mara  walks  the long harbour wall'], plannerPages: ['Mara walks the long harbour wall.'] },
];
for (const shared of SHARED_PATTERN_INPUTS) {
  const input: PolicyInput = { chapter: 4, volumeOrdinals: new Map(), currentVolumeOrdinal: null, ...shared };
  const policy: Policy = new disclosure.WriterDisclosurePolicy(input);
  policyCases.push([[input.chapter, input.lockedFacts.map(factRow), input.plannerOnly, input.plannerPages, [], null], exercise(rng, policy, input)]);
}

write('policy.json', { policyCases });

// Every order the reference could scrub equal-weight withholdings in: the facts as the database collates them, the volumes and pages as it returns them, and each tie
// run in any order. `hidden` is what at least one order withholds; the port must withhold all of it.
const permutations = <T>(items: readonly T[]): T[][] =>
  items.length <= 1 ? [[...items]] : items.flatMap((item, index) => permutations([...items.slice(0, index), ...items.slice(index + 1)]).map(rest => [item, ...rest]));

type PolicyEntry = { pattern: RegExp; weight: number; fields?: Set<string> };

function tieOrders(entries: PolicyEntry[]): PolicyEntry[][] {
  let orders: PolicyEntry[][] = [[]];
  for (let start = 0; start < entries.length; ) {
    let end = start;
    while (end < entries.length && (entries[end] as PolicyEntry).weight === (entries[start] as PolicyEntry).weight) end++;
    const group = permutations(entries.slice(start, end));
    orders = orders.flatMap(order => group.map(tail => [...order, ...tail]));
    start = end;
  }
  return orders;
}

function emulate(entries: PolicyEntry[], text: string, field: string): { text: string; kept: boolean[] } {
  let units = Array.from({ length: text.length }, (_, i) => [text.charCodeAt(i), i] as [number, number]);
  for (const entry of entries) {
    if (entry.fields && !entry.fields.has(field)) continue;
    const current = units.map(([unit]) => String.fromCharCode(unit)).join('');
    const next: [number, number][] = [];
    let cursor = 0;
    for (const match of current.matchAll(entry.pattern)) {
      next.push(...units.slice(cursor, match.index), ...[...'[withheld]'].map(char => [char.charCodeAt(0), -1] as [number, number]));
      cursor = match.index + match[0].length;
    }
    units = [...next, ...units.slice(cursor)];
  }
  const kept = Array.from({ length: text.length }, () => false);
  for (const [, origin] of units) if (origin >= 0) kept[origin] = true;
  return { text: units.map(([unit]) => String.fromCharCode(unit)).join(''), kept };
}

interface OrderInput {
  lockedFacts: Fact[];
  plannerOnly: string[];
  plannerPages: string[];
}

function orderCase(input: OrderInput, text: string, field: string): unknown {
  const outputs = new Set<string>();
  const hidden = Array.from({ length: text.length }, () => false);
  let orders = 0;
  for (const lockedFacts of permutations(input.lockedFacts)) {
    for (const plannerOnly of permutations(input.plannerOnly)) {
      for (const plannerPages of permutations(input.plannerPages)) {
        const policyInput = { chapter: 4, lockedFacts, plannerOnly, plannerPages, volumeOrdinals: new Map(), currentVolumeOrdinal: null };
        const entries = (new disclosure.WriterDisclosurePolicy(policyInput) as unknown as { withholdings: PolicyEntry[] }).withholdings;
        for (const order of tieOrders(entries)) {
          const policy = new disclosure.WriterDisclosurePolicy(policyInput);
          (policy as unknown as { withholdings: PolicyEntry[] }).withholdings = order;
          const scrubbed: string = policy.scrub(text, field);
          const emulated = emulate(order, text, field);
          if (emulated.text !== scrubbed) throw new Error(`emulation drifted on ${JSON.stringify(text)}`);
          outputs.add(scrubbed);
          emulated.kept.forEach((kept, index) => (hidden[index] ||= !kept));
          orders++;
        }
      }
    }
  }
  const spans: [number, number][] = [];
  hidden.forEach((isHidden, index) => {
    if (!isHidden) return;
    const last = spans[spans.length - 1];
    if (last && last[1] === index) last[1] = index + 1;
    else spans.push([index, index + 1]);
  });
  return [[4, input.lockedFacts.map(factRow), input.plannerOnly, input.plannerPages, [], null], text, field, orders, [...outputs], spans];
}

const termFact = (factKey: string, ...terms: string[]): Fact => ({ factKey, text: '', terms });
const orderCases: unknown[] = [
  orderCase({ lockedFacts: [termFact('a_x', 'red fox'), termFact('B_y', 'fox den')], plannerOnly: [], plannerPages: [] }, 'The red fox den was empty.', 'prose'),
  orderCase({ lockedFacts: [termFact('f1', 'ab cde'), termFact('f2', '-xy zw'), termFact('f3', 'cde-xy')], plannerOnly: [], plannerPages: [] }, 'ab cde-xy zw', 'prose'),
  orderCase({ lockedFacts: [termFact('f1', 'abcd'), termFact('f2', '-xyz')], plannerOnly: [], plannerPages: [] }, 'abcd-xyz and abcd -xyz', 'summary'),
  orderCase({ lockedFacts: [termFact('f1', 'withheld'), termFact('f2', 'was with')], plannerOnly: [], plannerPages: [] }, 'It was with withheld goods.', 'note'),
  orderCase({ lockedFacts: [termFact('f1', 'abcde', 'qqqqq'), termFact('f2', '-xyz')], plannerOnly: [], plannerPages: [] }, 'abcde-xyz', 'prose'),
  orderCase({ lockedFacts: [termFact('q', '-yzwv'), termFact('p', 'ab ab')], plannerOnly: [], plannerPages: [] }, 'xab ab ab-yzwv', 'prose'),
  orderCase({ lockedFacts: [{ factKey: 'door', text: 'the [withheld] door' }], plannerOnly: ['abcdefgh ijklmnopqr'], plannerPages: [] }, 'Then the abcdefgh ijklmnopqr door shut.', 'prose'),
  orderCase(
    { lockedFacts: [], plannerOnly: ['the keeper lets the lamp', 'lets the lamp go dark now'], plannerPages: [] },
    'At last the keeper lets the lamp go dark now.',
    'plan',
  ),
  orderCase(
    { lockedFacts: [termFact('wall', 'harbour wall')], plannerOnly: [], plannerPages: ['Mara walks the long harbour wall.', 'Mara  walks the long harbour\nwall!', 'walks the long harbour wall at dusk'] },
    'Then Mara walks the long harbour wall at dusk.',
    'bible_page',
  ),
];
const ORDER_WORDS = ['red', 'fox', 'den', 'ab', 'cde', 'xy', 'zw', 'Tide', 'court', 'bell', 'é', '𝒜sh', 'ox'];
const JOINS = [' ', ' ', ' ', '-', '—', ' "', "' ", '’'];
for (let index = 0; index < 70; index++) {
  let phrase = rng.pick(ORDER_WORDS);
  for (let i = rng.int(3, 5); i > 0; i--) phrase += rng.pick(JOINS) + rng.pick(ORDER_WORDS);
  const isWord = (char: string | undefined): boolean => char !== undefined && /[\p{L}\p{N}_]/u.test(char);
  const units = [...phrase];
  const windows: string[] = [];
  for (let start = 0; start < units.length; start++) {
    for (let end = start + 1; end <= units.length; end++) {
      const term = units.slice(start, end).join('');
      if (term.trim() !== term || term.length < 3 || (isWord(units[start - 1]) && isWord(units[start]))) continue;
      if (isWord(units[end]) && isWord(units[end - 1])) continue;
      windows.push(term);
    }
  }
  const length = rng.pick(windows).length;
  const sameLength = windows.filter(term => term.length === length);
  const terms = [...new Set(Array.from({ length: rng.int(2, 3) }, () => rng.pick(sameLength)))];
  const facts = terms.map((term, i) => termFact(rng.pick(['a_x', 'B_y', 'c_z', 'É_w']) + i, term));
  const text = `${rng.pick(BOUNDARIES)}${phrase}${rng.pick(['', ' ', ' and ' + phrase, '-' + phrase])}${rng.pick(BOUNDARIES)}`;
  orderCases.push(orderCase({ lockedFacts: facts, plannerOnly: [], plannerPages: [] }, text, rng.pick(FIELDS)));
}

write('orders.json', { orderCases });

type Tagged = null | boolean | number | string | Tagged[] | { o: [string, Tagged][] };

const obj = (...entries: [string, Tagged][]): Tagged => ({ o: entries });

function materialize(value: Tagged): unknown {
  if (Array.isArray(value)) return value.map(materialize);
  if (value === null || typeof value !== 'object') return value;
  const out: Row = {};
  for (const [key, entry] of value.o) Object.defineProperty(out, key, { value: materialize(entry), enumerable: true, writable: true, configurable: true });
  return out;
}

interface World {
  facts: Fact[];
  removedFacts: string[];
  entities: [string, string][];
  removedEntities: string[];
  knowledge: [string, string, number, string, string, number | null][];
  plans: [number, string | null, boolean, string[] | null, Tagged, Tagged][];
  milestones: [string, string, number | null][];
  volumes: [string, number, string | null, string | null, string | null][];
  ending: string | null;
  endingQuestion: string | null;
  pages: [string, string, string][];
  drafts: [number, number, string, string][];
}

function unlockFor(rng: Rng): { all: Row[] } {
  const terms = Array.from({ length: rng.int(1, 3) }, (): Row => {
    switch (rng.int(0, 3)) {
      case 0:
        return { milestone: rng.pick(MILESTONE_KEYS) };
      case 1:
        return { volume: rng.pick(VOLUME_KEYS.filter(key => key !== '')) };
      case 2:
        return { chapter: rng.int(1, 9) };
      default:
        return { ending: true };
    }
  });
  return { all: terms };
}

function contractFor(rng: Rng, facts: readonly string[], entities: readonly string[]): Tagged {
  const roll = rng.int(0, 13);
  if (roll === 0) return null;
  if (roll === 1) return rng.pick<Tagged>(['x', 7, [], obj(), obj(['pov', []]), obj(['pov', ['', 5]]), obj(['learns', [obj(['entityKey', 'mira'], ['factKey', 'heir'])]])]);
  const pov: Tagged[] = rng.some([...entities, ...entities, 'ghost', '', 5], 3);
  if (rng.chance(0.85) && entities.length > 0) pov.push(rng.pick(entities));
  const learns: Tagged[] = Array.from({ length: rng.int(0, 4) }, () => {
    if (rng.chance(0.07)) return rng.pick<Tagged>([null, 'x', obj(['entityKey', 'mira']), obj(['entityKey', 5], ['factKey', 'heir'])]);
    return obj(['entityKey', rng.chance(0.85) && entities.length > 0 ? rng.pick(entities) : rng.pick(ENTITY_KEYS)], ['factKey', rng.chance(0.85) && facts.length > 0 ? rng.pick(facts) : rng.pick(FACT_KEYS)]);
  });
  return obj(['pov', pov], ['learns', learns]);
}

function endingContractFor(rng: Rng, facts: readonly string[]): Tagged {
  const roll = rng.int(0, 7);
  if (roll <= 2) return null;
  if (roll === 3) return rng.pick<Tagged>(['x', 3, [], obj(), obj(['mustNotResolve', 'heir']), obj(['mustNotResolve', []])]);
  const entries: Tagged[] = Array.from({ length: rng.int(1, 3) }, () => {
    const key = rng.chance(0.8) && facts.length > 0 ? rng.pick(facts) : rng.pick(FACT_KEYS);
    return rng.pick<Tagged>([key, `fact:${key}`, ` ${key} `, `fact: ${key}`, `FACT:${key}`, 5, null]);
  });
  return obj(['mustNotResolve', entries], ...(rng.chance(0.3) ? [['mustResolve', ['x']] as [string, Tagged]] : []));
}

function worldFor(rng: Rng, endings: number): World {
  const factKeys = [...new Set(Array.from({ length: rng.int(1, 6) }, () => rng.pick(FACT_KEYS)))];
  const entityKeys = [...new Set(Array.from({ length: rng.int(1, 4) }, () => rng.pick(ENTITY_KEYS)))];
  const removedFacts = rng.chance(0.3) ? [rng.pick(FACT_KEYS.filter(key => !factKeys.includes(key)))] : [];
  const removedEntities = rng.chance(0.3) ? [rng.pick(ENTITY_KEYS.filter(key => !entityKeys.includes(key)))] : [];
  const facts = factKeys.map(factKey => {
    const fact = factLike(rng, factKey);
    fact.source = rng.pick(['brief', 'manual', 'import', 'seed', 'generated', 'manual', 'manual']);
    fact.revealChapter = rng.chance(0.35) ? null : rng.int(-1, 9);
    fact.unlock = rng.chance(0.6) ? null : unlockFor(rng);
    fact.disclosedInChapter = rng.chance(0.6) ? null : rng.int(0, 9);
    if (rng.chance(0.4)) fact.subjects = rng.some(ENTITY_KEYS, 2);
    return fact;
  });
  const knowledge: World['knowledge'] = [];
  const pairs = new Set<string>();
  for (let i = rng.int(0, 7); i > 0; i--) {
    const factKey = rng.pick([...factKeys, ...removedFacts]);
    const entityKey = rng.pick([...entityKeys, ...removedEntities]);
    if (pairs.has(`${factKey}\u0000${entityKey}`)) continue;
    pairs.add(`${factKey}\u0000${entityKey}`);
    const source = rng.pick(['brief', 'brief', 'manual', 'import', 'seed', 'generated']);
    knowledge.push([factKey, entityKey, rng.int(-1, 9), source, rng.pick(['provisional', 'committed']), source === 'brief' ? rng.int(1, 4) : null]);
  }
  const chapters = [...new Set(Array.from({ length: rng.int(0, 6) }, () => rng.int(-1, 9)))];
  let endingsLeft = endings;
  const plans: World['plans'] = chapters.map(chapter => {
    const isEnding = endingsLeft > 0 && rng.chance(0.25);
    if (isEnding) endingsLeft--;
    const claimed = rng.chance(0.5) ? null : rng.some(MILESTONE_KEYS, 2);
    return [chapter, rng.chance(0.25) ? null : rng.pick(VOLUME_KEYS), isEnding, claimed, contractFor(rng, factKeys, entityKeys), endingContractFor(rng, factKeys)];
  });
  const milestones: World['milestones'] = [...new Set(rng.some(MILESTONE_KEYS, 3))].map(key => {
    const state = rng.pick(['open', 'planned', 'reached', 'reached']);
    return [key, state, state === 'reached' ? (rng.chance(0.3) ? null : rng.int(0, 9)) : null];
  });
  const volumes: World['volumes'] = [...new Set(rng.some(VOLUME_KEYS, 3))].map(key => [
    key,
    rng.int(0, 4),
    maybe(rng, () => rng.pick(['Part one', '', 'Ⅱ'])),
    maybe(rng, () => (rng.chance(0.2) ? rng.pick(['', ' ']) : passage(rng, 2))),
    maybe(rng, () => (rng.chance(0.2) ? rng.pick(['', ' ']) : passage(rng, 2))),
  ]);
  const pages: World['pages'] = Array.from({ length: rng.int(0, 4) }, () => {
    const [section, slug] = rng.pick([
      ['project', 'timeline'], ['project', 'open-questions'], ['project', 'premise'], ['story_state', 'volume-plan'], ['Project', 'timeline'], ['project', 'Timeline'], ['project', 'timeline '],
    ] as const);
    return [section, slug, rng.chance(0.15) ? rng.pick(['', '  ']) : plannerPage(rng)];
  });
  const drafts: World['drafts'] = [...new Set(Array.from({ length: rng.int(0, 5) }, () => rng.int(-1, 9)))].map(chapter => [
    chapter,
    rng.int(1, 4),
    rng.pick(['draft', 'draft', 'final']),
    rng.pick(['generating', 'needs_review', 'contradiction', 'approved', 'approved', 'final']),
  ]);
  return {
    facts,
    removedFacts,
    entities: entityKeys.map(key => [key, rng.pick(['Mira', 'Amara', 'Tobin', key, ''])]),
    removedEntities,
    knowledge,
    plans,
    milestones,
    volumes,
    ending: maybe(rng, () => (rng.chance(0.2) ? rng.pick(['', ' ']) : passage(rng, 2))),
    endingQuestion: maybe(rng, () => (rng.chance(0.2) ? rng.pick(['', ' ']) : `${sentence(rng)}?`)),
    pages,
    drafts,
  };
}

// The real tables after a removal: deleting a fact or an entity cascades to its ledger rows.
function seed(world: World): Record<string, Row[]> {
  const factId = new Map(world.facts.map((fact, index) => [fact.factKey, BigInt(index + 1)]));
  const entityId = new Map(world.entities.map(([key], index) => [key, BigInt(index + 101)]));
  return {
    projects: [{ id: 1n, ending: world.ending, endingQuestion: world.endingQuestion, storyCurrentChapter: 0 }],
    canonFacts: world.facts.map(fact => ({
      id: factId.get(fact.factKey),
      projectId: 1n,
      ...Object.fromEntries(FACT_FIELDS.map(field => [field, fact[field] ?? null])),
      plannedChapter: null,
    })),
    entities: world.entities.map(([entityKey, name]) => ({ id: entityId.get(entityKey), projectId: 1n, entityKey, name })),
    characterKnowledge: world.knowledge
      .filter(([factKey, entityKey]) => factId.has(factKey) && entityId.has(entityKey))
      .map(([factKey, entityKey, learnedInChapter, source, status, draftRevision]) => ({
        projectId: 1n, factId: factId.get(factKey), entityId: entityId.get(entityKey), learnedInChapter, source, note: null, status, draftRevision,
      })),
    briefs: world.plans.map(([chapter, volumeKey, isEnding, claimedMilestones, knowledgeContract, endingContract], index) => ({
      id: BigInt(index + 1), projectId: 1n, chapter, volumeKey, isEnding, claimedMilestones, knowledgeContract: materialize(knowledgeContract), endingContract: materialize(endingContract), staleReason: null,
    })),
    milestones: world.milestones.map(([milestoneKey, state, reachedChapter], index) => ({ id: BigInt(index + 1), projectId: 1n, milestoneKey, state, reachedChapter })),
    volumes: world.volumes.map(([volumeKey, ordinal, title, objective, body]) => ({ projectId: 1n, volumeKey, ordinal, title, objective, body })),
    bibleDocuments: world.pages.map(([section, slug, body]) => ({ projectId: 1n, section, slug, frontmatter: {}, body })),
    drafts: world.drafts.map(([chapter, revision, status, reviewStatus]) => ({ projectId: 1n, chapter, revision, status, reviewStatus })),
    chapters: [],
  };
}

function worldRow(world: World): unknown[] {
  return [
    world.facts.map(factRow), world.removedFacts, world.entities, world.removedEntities, world.knowledge, world.plans, world.milestones, world.volumes, world.ending, world.endingQuestion,
    world.pages, world.drafts,
  ];
}

const contextRow = (ctx: { chapter: number; endingChapter: number | null; volumeKey: string | null; reachedMilestones: Set<string> }): unknown[] => [
  ctx.chapter, ctx.endingChapter, ctx.volumeKey, [...ctx.reachedMilestones].sort(codePointCompare),
];

const factKeysOf = (facts: Fact[]): string[] => facts.map(fact => fact.factKey);

function worldProbe(rng: Rng, world: World): string {
  const sources = [
    ...world.facts.flatMap(fact => [fact.text, fact.constraintNote ?? '', ...(fact.terms ?? []), `fact:${fact.factKey}`]),
    ...world.volumes.flatMap(([, , , objective, body]) => [objective ?? '', body ?? '']),
    world.ending ?? '', world.endingQuestion ?? '', ...world.pages.map(([, , body]) => body),
  ].filter(text => text.trim() !== '');
  return Array.from({ length: rng.int(2, 4) }, () => (sources.length > 0 && rng.chance(0.75) ? surround(rng, variant(rng, rng.pick(sources))) : sentence(rng))).join(rng.pick([' ', '\n']));
}

// The reference reads the ending plan the database returns first; the Swift port takes the later chapter. The main outputs use a table order where the two agree, and
// `endingVariant` records the other order's ending and ending question.
function endingFirst(world: World): World {
  const endings = world.plans.flatMap((plan, index) => (plan[2] ? [index] : []));
  if (endings.length < 2) return world;
  const [first, second] = endings as [number, number];
  if ((world.plans[first] as World['plans'][number])[0] >= (world.plans[second] as World['plans'][number])[0]) return world;
  const plans = [...world.plans];
  [plans[first], plans[second]] = [plans[second] as World['plans'][number], plans[first] as World['plans'][number]];
  return { ...world, plans };
}

async function endingVariant(world: World, chapter: number, overlay: unknown): Promise<unknown> {
  const swapped = swappedEndings(world);
  if (!swapped) return null;
  const sources = await disclosure.loadWriterDisclosureSources(fakeDb(seed(swapped)), 1n, chapter, overlay);
  return [sources.ending, sources.endingQuestion];
}

function swappedEndings(world: World): World | null {
  const endings = world.plans.flatMap((plan, index) => (plan[2] ? [index] : []));
  if (endings.length < 2) return null;
  const [first, second] = endings as [number, number];
  const plans = [...world.plans];
  [plans[first], plans[second]] = [plans[second] as World['plans'][number], plans[first] as World['plans'][number]];
  return { ...world, plans };
}

const viewCases: unknown[] = [];
for (let index = 0; index < 62; index++) {
  const world = endingFirst(worldFor(rng, index % 2 === 0 ? 2 : 1));
  const factKeys = world.facts.map(fact => fact.factKey);
  const entityKeys = [...world.entities.map(([key]) => key), ...world.removedEntities];
  const queries: unknown[] = [];
  const endingChapters = world.plans.filter(plan => plan[2]).map(plan => plan[0]);
  const between = endingChapters.length === 2 ? [Math.min(...endingChapters) + 1].filter(chapter => chapter < Math.max(...endingChapters)) : [];
  for (const chapter of [...new Set([...Array.from({ length: rng.int(1, 2) }, () => rng.int(-1, 10)), ...between])]) {
    readerKnowsLabel = rng.chance(0.4);
    const stored = world.plans.find(([at]) => at === chapter);
    const overlayRow = rng.chance(0.3)
      ? ([chapter, rng.chance(0.3) ? null : rng.pick(VOLUME_KEYS), rng.chance(0.2), rng.chance(0.5) ? null : rng.some(MILESTONE_KEYS, 2), contractFor(rng, factKeys, entityKeys), endingContractFor(rng, factKeys)] as const)
      : null;
    const overlay = overlayRow && {
      chapter: overlayRow[0], volumeKey: overlayRow[1], isEnding: overlayRow[2], claimedMilestones: overlayRow[3], knowledgeContract: materialize(overlayRow[4]), endingContract: materialize(overlayRow[5]),
    };
    const contractSource: Tagged = rng.chance(0.5) && stored ? stored[4] : contractFor(rng, factKeys, entityKeys);
    const contract = view.parseKnowledgeContract(materialize(contractSource)) as { pov: string[]; learns: unknown[] } | null;
    const readerKnows = rng.pick([undefined, true, false]);
    const db = fakeDb(seed(world));
    const knowledgeView = contract
      ? await view.loadKnowledgeView(db, 1n, chapter, contract, { readerKnows, ...(overlay ? { overlay } : {}) })
      : null;
    const viewRow = knowledgeView && [
      factKeysOf(knowledgeView.known), factKeysOf(knowledgeView.reveals), factKeysOf(knowledgeView.hidden), factKeysOf(knowledgeView.readerKnows),
      knowledgeView.pooledPov.map((member: { entityKey: string; name: string }) => [member.entityKey, member.name]),
      knowledgeView.learnedIn ? [...knowledgeView.learnedIn] : null,
    ];
    const facts = await db.query.canonFacts.findMany({});
    const hidden: Set<string> = await view.loadWriterHiddenFactKeys(fakeDb(seed(world)), 1n, chapter, facts, overlay ?? undefined);
    const forbidden: Fact[] = await view.loadWriterForbiddenFacts(fakeDb(seed(world)), 1n, chapter, overlay ?? undefined);
    const sources = await disclosure.loadWriterDisclosureSources(fakeDb(seed(world)), 1n, chapter, overlay ?? undefined);
    const sourcesRow = [
      factKeysOf(sources.lockedFacts), sources.ending, sources.endingQuestion,
      sources.laterVolumes.map((volume: Row) => [volume.volumeKey, volume.title, volume.objective, volume.body]),
      sources.plannerPages.map((page: Row) => [page.section, page.slug]), [...sources.volumeOrdinals], sources.currentVolumeOrdinal,
    ];
    const writer = disclosure.writerDisclosurePolicy(sources);
    const art = await disclosure.loadArtDisclosurePolicy(fakeDb(seed(world)), 1n, chapter);
    const probes = [worldProbe(rng, world)];
    const field = rng.pick(FIELDS);
    const notes = await view.loadFactWriterNotes(fakeDb(seed(world)), 1n, materialize(stored?.[5] ?? null));
    const contexts = await Promise.all([true, false].map(async conditioned => contextRow(await planWorld.chapterUnlockContext(fakeDb(seed(world)), 1n, chapter, conditioned, overlay ?? undefined))));
    const planned = (await planWorld.plannedUnlockContexts(fakeDb(seed(world)), 1n, true))(chapter);
    queries.push([
      chapter, readerKnowsLabel, overlayRow, contractSource, readerKnows ?? null, viewRow, [...hidden], factKeysOf(forbidden), sourcesRow, probes, field,
      probes.map(probe => attempt(() => writer.scrub(probe, field))), probes.map(probe => attempt(() => art.scrub(probe, field))), rng.some(REFS, 4).map(ref => [ref, writer.canResolve(ref)]),
      [...notes], await briefVolume.nearestVolumeKey(fakeDb(seed(world)), 1n, chapter), contexts, contextRow(planned), await endingVariant(world, chapter, overlay ?? undefined),
    ]);
  }
  viewCases.push([worldRow(world), queries]);
}

write('view.json', { viewCases });

// The ledger reads keys, schedules and contracts only. Its worlds lean towards plans whose learns the reveal rule lets through, so rows are written, revoked and re-ledgered.
function ledgerWorld(rng: Rng): World {
  const base = worldFor(rng, 2);
  const factKeys = base.facts.map(fact => fact.factKey);
  const entityKeys = base.entities.map(([key]) => key);
  const facts = base.facts.map(fact => ({
    factKey: fact.factKey,
    text: '',
    source: rng.pick(['manual', 'manual', 'brief', 'import', 'seed']),
    disclosedInChapter: rng.chance(0.85) ? null : rng.int(0, 6),
    revealChapter: rng.chance(0.15) ? null : rng.chance(0.1) ? 8 : rng.int(0, 4),
    unlock: rng.chance(0.75) ? null : unlockFor(rng),
  }));
  const chapters = [...new Set(Array.from({ length: rng.int(2, 5) }, () => rng.int(0, 8)))];
  const learnsFor = (): Tagged => {
    if (rng.chance(0.12)) return null;
    const learns: Tagged[] = Array.from({ length: rng.int(1, 3) }, () =>
      obj(['entityKey', rng.chance(0.9) ? rng.pick([...entityKeys, ...base.removedEntities]) : 'ghost'], ['factKey', rng.chance(0.9) ? rng.pick([...factKeys, ...base.removedFacts]) : 'unknown_fact']),
    );
    return obj(['pov', [rng.pick(entityKeys)]], ['learns', learns]);
  };
  const plans: World['plans'] = chapters.map(chapter => [chapter, rng.chance(0.3) ? null : rng.pick(VOLUME_KEYS), chapter === 8 && rng.chance(0.5), rng.chance(0.6) ? null : rng.some(MILESTONE_KEYS, 2), learnsFor(), null]);
  const drafts: World['drafts'] = chapters.filter(() => rng.chance(0.75)).map(chapter => [chapter, rng.int(1, 4), rng.pick(['draft', 'draft', 'final']), rng.pick(['approved', 'approved', 'needs_review', 'final'])]);
  return { ...base, facts, plans, drafts, volumes: base.volumes.map(([key, ordinal]) => [key, ordinal, null, null, null]), ending: null, endingQuestion: null, pages: [] };
}

type Op = [kind: 'ledger' | 'revoke' | 'commit' | 'disclose' | 'retract' | 'draft', ...args: unknown[]];

function ledgerState(data: Record<string, Row[]>, world: World): unknown[] {
  const factKey = new Map(world.facts.map((fact, index) => [BigInt(index + 1), fact.factKey]));
  const entityKey = new Map(world.entities.map(([key], index) => [BigInt(index + 101), key]));
  const rows = (data.characterKnowledge ?? []).map(row => [factKey.get(row.factId as bigint), entityKey.get(row.entityId as bigint), row.learnedInChapter, row.source, row.status, row.draftRevision]);
  const disclosed = (data.canonFacts ?? []).map(row => row.disclosedInChapter);
  return [rows, disclosed];
}

async function apply(op: Op, data: Record<string, Row[]>, world: World): Promise<unknown> {
  const db = fakeDb(data);
  switch (op[0]) {
    case 'ledger': {
      const outcome = await provisional.ledgerBriefReveals(db, 1n, op[1] as number, op[2] as number);
      return [outcome.applied, outcome.skipped];
    }
    case 'revoke':
      await provisional.revokeProvisionalReveals(db, 1n, op[1] as number[]);
      return null;
    case 'commit':
      await provisional.commitChapterKnowledge(db, 1n, op[1] as number, op[2] as number);
      return null;
    case 'disclose':
      await provisional.discloseChapterReveals(db, 1n, op[1] as number);
      return null;
    case 'retract':
      data.characterKnowledge = (data.characterKnowledge ?? []).filter(row => {
        const [[factKey, entityKey]] = ledgerState({ characterKnowledge: [row] }, world)[0] as unknown[][] as [unknown, unknown][];
        return !(factKey === op[1] && entityKey === op[2]);
      });
      return null;
    case 'draft':
      data.drafts = [...(data.drafts ?? []).filter(row => row.chapter !== op[1]), { projectId: 1n, chapter: op[1], revision: op[2], status: op[3], reviewStatus: op[4] }];
      return null;
  }
}

async function run(world: World, ops: Op[]): Promise<unknown> {
  const data = seed(world);
  const steps: unknown[] = [];
  let previous = JSON.stringify(ledgerState(data, world));
  for (const op of ops) {
    const result = await apply(op, data, world);
    const state = ledgerState(data, world);
    const unchanged = JSON.stringify(state) === previous;
    previous = JSON.stringify(state);
    steps.push([op, result, unchanged ? null : state]);
  }
  return [worldRow(world), steps];
}

function randomOp(rng: Rng, world: World, chapters: number[], rows: unknown[][]): Op {
  const roll = rng.int(0, 9);
  if (roll <= 2) return ['ledger', rng.pick(chapters), rng.int(1, 4)];
  if (roll <= 4) return ['revoke', rng.chance(0.7) ? [rng.pick(chapters)] : rng.some(chapters, 3)];
  if (roll === 5) return ['commit', rng.pick(chapters), rng.int(1, 4)];
  if (roll === 6) return ['disclose', rng.pick(chapters)];
  if (roll === 7 && rows.length > 0) return ['retract', ...rng.pick(rows).slice(0, 2)] as Op;
  return ['draft', rng.pick(chapters), rng.int(1, 4), rng.pick(['draft', 'final']), rng.pick(['needs_review', 'approved', 'final', 'generating'])];
}

const ledgerCases: unknown[] = [];
for (let index = 0; index < 75; index++) {
  const world = ledgerWorld(rng);
  const chapters = [...world.plans.map(([chapter]) => chapter), ...world.plans.map(([chapter]) => chapter), -1, 9];
  const data = seed(world);
  const ops: Op[] = [];
  for (let i = rng.int(2, 8); i > 0; i--) {
    const op = randomOp(rng, world, chapters, ledgerState(data, world)[0] as unknown[][]);
    await apply(op, data, world);
    ops.push(op);
  }
  ledgerCases.push(await run(world, ops));
}

// Two plans teach the same pair: revoking the earlier one re-ledgers the pair at the later claimant, committed when its draft is final, and never over a manual row.
const learnsPair = (pairs: [string, string][]): Tagged => obj(['pov', ['mira']], ['learns', pairs.map(([entityKey, factKey]) => obj(['entityKey', entityKey], ['factKey', factKey]))]);
const shared: World = {
  facts: [
    { factKey: 'heir', text: '', source: 'manual', revealChapter: 2, unlock: null, disclosedInChapter: null },
    { factKey: 'tide', text: '', source: 'manual', revealChapter: 4, unlock: null, disclosedInChapter: null },
    { factKey: 'bell', text: '', source: 'manual', revealChapter: 2, unlock: null, disclosedInChapter: null },
  ],
  removedFacts: [],
  entities: [['mira', 'Mira'], ['tobin', 'Tobin']],
  removedEntities: [],
  knowledge: [['bell', 'tobin', 6, 'manual', 'committed', null]],
  plans: [
    [3, null, false, null, learnsPair([['mira', 'heir'], ['tobin', 'bell']]), null],
    [5, null, false, null, learnsPair([['mira', 'heir'], ['mira', 'tide'], ['tobin', 'bell']]), null],
    [7, null, false, null, learnsPair([['mira', 'heir'], ['mira', 'tide']]), null],
  ],
  milestones: [],
  volumes: [],
  ending: null,
  endingQuestion: null,
  pages: [],
  drafts: [[3, 1, 'draft', 'approved'], [5, 2, 'final', 'final'], [7, 1, 'draft', 'approved']],
};
for (const ops of [
  [['ledger', 3, 1], ['ledger', 5, 2], ['ledger', 7, 1], ['revoke', [3]], ['revoke', [5]], ['commit', 7, 1], ['disclose', 5]],
  [['ledger', 7, 1], ['ledger', 3, 1], ['draft', 5, 2, 'draft', 'approved'], ['revoke', [3, 7]], ['commit', 5, 3], ['commit', 5, 2]],
  [['ledger', 3, 1], ['retract', 'bell', 'tobin'], ['ledger', 5, 2], ['revoke', [3]], ['ledger', 3, 4], ['commit', 3, 4]],
] as Op[][]) {
  ledgerCases.push(await run(shared, ops));
}

// Open canon is never disclosed by a chapter, with or without an unlock that holds there.
const openCanonWorld: World = {
  facts: [
    { factKey: 'open_rule', text: '', source: 'manual', revealChapter: 1, unlock: null, disclosedInChapter: null },
    { factKey: 'open_gate', text: '', source: 'manual', revealChapter: 1, unlock: { all: [{ chapter: 1 }] }, disclosedInChapter: null },
    { factKey: 'early_rule', text: '', source: 'manual', revealChapter: 0, unlock: null, disclosedInChapter: null },
    { factKey: 'dated', text: '', source: 'manual', revealChapter: 2, unlock: null, disclosedInChapter: null },
  ],
  removedFacts: [],
  entities: [['mira', 'Mira']],
  removedEntities: [],
  knowledge: [],
  plans: [[1, null, false, null, null, null], [2, null, false, null, null, null]],
  milestones: [],
  volumes: [],
  ending: null,
  endingQuestion: null,
  pages: [],
  drafts: [[1, 1, 'final', 'final']],
};
ledgerCases.push(await run(openCanonWorld, [['disclose', 1], ['commit', 1, 1], ['disclose', 2]]));

write('ledger.json', { ledgerCases });
