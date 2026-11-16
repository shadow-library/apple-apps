import { plugin } from 'bun';
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');

const server = join(platformRepo, 'apps/novel-forge-server/src');
const outDir = dirname(fileURLToPath(import.meta.url));
const classes = await import(join(server, 'classes/app-error-code.ts'));
const briefScenes = await import(join(server, 'common/brief-scenes.ts'));
const unlockCondition = await import(join(server, 'common/unlock-condition.ts'));
const docTitle = await import(join(server, 'common/bible-doc-title.ts'));

const tableProxy: unknown = new Proxy(() => undefined, { get: () => tableProxy, apply: () => tableProxy });
const noop = () => undefined;

plugin({
  name: 'ideas-fixture-stubs',
  setup(build) {
    build.module('@server/classes', () => ({ exports: { AppErrorCode: classes.AppErrorCode }, loader: 'object' }));
    build.module('@server/common', () => ({
      exports: {
        validateBriefScenes: briefScenes.validateBriefScenes,
        validateUnlockCondition: unlockCondition.validateUnlockCondition,
        deriveBibleDocTitle: docTitle.deriveBibleDocTitle,
        computeContentHash: noop,
      },
      loader: 'object',
    }));
    build.module('@server/database', () => ({ exports: { schema: tableProxy }, loader: 'object' }));
    build.module('@server/database/schemas', () => ({ exports: {}, loader: 'object' }));
    build.module('drizzle-orm', () => ({ exports: { and: noop, asc: noop, eq: noop, inArray: noop, isNotNull: noop, isNull: noop }, loader: 'object' }));
  },
});

const policy = await import(join(server, 'modules/refinement/write-policy.ts'));
const changeSet = await import(join(server, 'modules/refinement/change-set/index.ts'));
const ideaId = await import(join(server, 'modules/refinement/idea-id.ts'));
const ideaFilter = await import(join(server, 'modules/refinement/idea-filter.ts'));
const rejections = await import(join(server, 'modules/refinement/idea-rejections.ts'));
const artifactState = await import(join(server, 'modules/refinement/artifact-state.ts'));
const negation = await import(join(server, 'modules/refinement/negation-echo.ts'));

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

type Rec = Record<string, unknown>;
type Str = string | number[];

const encode = (value: string): Str => (value.isWellFormed() ? value : Array.from({ length: value.length }, (_, i) => value.charCodeAt(i)));
const OPTIONS = { entityMaterialization: false };
const validate = (ops: Rec[]): { ok: boolean; parsed: Rec[]; errors: string[] } => {
  const parsed = JSON.parse(JSON.stringify(ops)) as Rec[];
  const errors = changeSet.validateChangeSet(parsed, undefined, OPTIONS) as string[];
  return { ok: errors.length === 0, parsed, errors };
};

const GAPS = [' ', ' ', '  ', '\n', '\r\n', '\t', '　', ' ', '﻿', ' ', ' ', '\u000b', '\u000c', ' ', ' ', '　'];
const WORDS = [
  'tower', 'lantern', 'marsh', 'river', 'oath', 'queen', 'Tower', 'RIVER', 'Ｔｏｗｅｒ', 'ﬁre', 'ΟΔΟΣ', 'ΣΑΣ', 'İstanbul', 'straße', 'café', 'café', 'naïve', 'Å', 'Å',
  '😀', '王国', '灯笼', '𠀀', 'ひかり', 'ラーメン', '왕국', '𐐀ngel', '½', 'x²', '①', 'éclair', 'éclair', 'the', 'a', 'of', '42', "don't", 'mara’s', 'Mara',
];
const SECTIONS_PAGES: [string, string][] = [
  ['project', 'premise'], ['project', 'timeline'], ['project', 'open-questions'], ['project', 'cast'], ['project', 'notes'], ['story_state', 'volume-plan'], ['story_state', 'volumes'],
  ['story_state', 'now'], ['plot', 'escalation-map'], ['plot', 'beats'], ['world', 'setting-overview'], ['world', 'factions-and-locations'], ['world', 'harbour'],
  ['power', 'system-and-limits'], ['lore', 'songs'], ['ai', 'characters'],
];
const ENTITY_TYPES = ['character', 'faction', 'location', 'power_rule', 'item', 'concept'];
const ENTITY_KEYS = ['mara', 'vell', 'tower', 'queen', 'harbour_guild', 'é', 'é'];
const FACT_KEYS = ['oath_broken', 'queen_is_mara', 'tide_secret'];
const VOLUME_KEYS = ['v1', 'v2', 'winter'];
const MILESTONE_KEYS = ['m1', 'tower_falls', 'oath'];
const PROMISE_KEYS = ['p1', 'who_rang', 'oath'];
const STORY_FIELDS: string[] = changeSet.declaredOpFields('premise.update');

function prose(rng: Rng, min = 0, max = 8): string {
  const count = rng.int(min, max);
  const out: string[] = [];
  for (let i = 0; i < count; i++) out.push(rng.pick(WORDS));
  const joined = out.join(rng.chance(0.15) ? ', ' : rng.chance(0.2) ? rng.pick(GAPS) : ' ');
  return rng.chance(0.05) ? rng.pick(['', ' ', '\t', '　', ' ']) : joined;
}

function maybe(rng: Rng, record: Rec, key: string, p: number, value: () => unknown): void {
  if (rng.chance(p)) record[key] = value();
}

function shuffled(rng: Rng, record: Rec): Rec {
  const keys = Object.keys(record);
  for (let i = keys.length - 1; i > 0; i--) {
    const j = rng.int(0, i);
    [keys[i], keys[j]] = [keys[j] as string, keys[i] as string];
  }
  return Object.fromEntries(keys.map(key => [key, record[key]]));
}

function frontmatter(rng: Rng): Rec {
  return {
    title: prose(rng, 1, 3),
    10: rng.int(0, 9),
    2: prose(rng, 0, 2),
    z: [prose(rng, 0, 2), { b: prose(rng, 0, 2), 3: null, a: [1, 2.5, true] }],
    a: { ΟΔΟΣ: 'ΟΔΟΣ', n: -0.5, big: 12345678, none: null },
    [rng.pick(WORDS)]: prose(rng, 0, 3),
  };
}

function contentOp(rng: Rng): Rec {
  const kind = rng.pick([
    'premise.update', 'bible_document.upsert', 'bible_document.upsert', 'entity.upsert', 'entity.upsert', 'fact.upsert', 'volume.upsert', 'promise.create', 'promise.update',
    'milestone.upsert', 'promise.set_payoff', 'brief.update', 'brief.update', 'bible_document.remove', 'volume.remove', 'brief.remove', 'draft.update', 'draft.remove',
    'draft.rewrite_passage', 'entity.remove', 'fact.remove', 'milestone.remove', 'promise.drop', 'organise.rule', 'action',
  ]);
  const op: Rec = {};
  const text = (min = 0, max = 8) => () => prose(rng, min, max);
  const strings = () => Array.from({ length: rng.int(0, 3) }, () => prose(rng, 1, 4));
  switch (kind) {
    case 'premise.update':
      op['op'] = kind;
      for (const field of STORY_FIELDS) maybe(rng, op, field, 0.3, field === 'themes' ? strings : field === 'protagonistKey' ? () => rng.pick(ENTITY_KEYS) : text());
      break;
    case 'bible_document.upsert':
    case 'bible_document.remove': {
      const [section, slug] = rng.pick(SECTIONS_PAGES);
      Object.assign(op, { op: kind, section, slug });
      if (kind === 'bible_document.upsert') {
        maybe(rng, op, 'body', 0.75, text(0, 14));
        maybe(rng, op, 'frontmatter', 0.35, () => frontmatter(rng));
      }
      break;
    }
    case 'entity.upsert':
      Object.assign(op, { op: kind, entityKey: rng.pick(ENTITY_KEYS), type: rng.pick(ENTITY_TYPES) });
      maybe(rng, op, 'name', 0.5, () => rng.pick(['Mara Vell', 'The Tower', 'Queen of Salt', 'mara']));
      for (const field of ['status', 'motivation', 'notes', 'body']) maybe(rng, op, field, 0.4, text());
      break;
    case 'fact.upsert':
      Object.assign(op, { op: kind, factKey: rng.pick(FACT_KEYS) });
      maybe(rng, op, 'body', 0.5, text(0, 12));
      maybe(rng, op, 'subjects', 0.35, () => Array.from({ length: rng.int(0, 2) }, () => rng.pick(ENTITY_KEYS)));
      maybe(rng, op, 'constraintNote', 0.25, text());
      maybe(rng, op, 'writerNote', 0.15, text());
      maybe(rng, op, 'terms', 0.25, strings);
      maybe(rng, op, 'revealChapter', 0.15, () => (rng.chance(0.3) ? null : rng.int(1, 9)));
      maybe(rng, op, 'unlock', 0.2, () =>
        rng.chance(0.25) ? null : { all: Array.from({ length: rng.int(1, 3) }, () => rng.pick([{ milestone: rng.pick(MILESTONE_KEYS) }, { volume: rng.pick(VOLUME_KEYS) }, { chapter: rng.int(1, 9) }, { ending: true }])) },
      );
      maybe(rng, op, 'allowedClues', 0.15, () => (rng.chance(0.3) ? null : [prose(rng, 1, 3) || 'clue']));
      break;
    case 'volume.upsert':
      Object.assign(op, { op: kind, volumeKey: rng.pick(VOLUME_KEYS) });
      maybe(rng, op, 'ordinal', 0.3, () => rng.int(0, 4));
      maybe(rng, op, 'title', 0.5, text(0, 4));
      maybe(rng, op, 'objective', 0.3, text());
      maybe(rng, op, 'body', 0.2, text());
      maybe(rng, op, 'state', 0.1, () => rng.pick(['not_started', 'active']));
      break;
    case 'promise.create':
      Object.assign(op, { op: kind, kind: rng.pick(['thread', 'mystery']), key: rng.pick(PROMISE_KEYS), label: prose(rng, 1, 8) || 'who rang the bell' });
      maybe(rng, op, 'openedChapter', 0.2, () => rng.int(1, 9));
      break;
    case 'promise.update':
      Object.assign(op, { op: kind, kind: rng.pick(['thread', 'mystery']), key: rng.pick(PROMISE_KEYS) });
      maybe(rng, op, 'label', 0.6, text(0, 8));
      maybe(rng, op, 'lastAdvancedChapter', 0.2, () => rng.int(1, 9));
      maybe(rng, op, 'status', 0.2, () => rng.pick(['open', 'paid_off']));
      break;
    case 'promise.set_payoff':
      Object.assign(op, { op: kind, kind: rng.pick(['thread', 'mystery']), key: rng.pick(PROMISE_KEYS) });
      if (rng.chance(0.3)) op['someday'] = true;
      else {
        maybe(rng, op, 'payoffMilestoneKey', 0.5, () => rng.pick([...MILESTONE_KEYS, null]));
        maybe(rng, op, 'payoffVolumeKey', 0.5, () => rng.pick([...VOLUME_KEYS, null]));
        maybe(rng, op, 'payoffWindow', 0.3, () => (rng.chance(0.3) ? null : rng.int(1, 5)));
      }
      maybe(rng, op, 'dormant', 0.2, () => rng.chance(0.5));
      break;
    case 'milestone.upsert':
      Object.assign(op, { op: kind, milestoneKey: rng.pick(MILESTONE_KEYS) });
      maybe(rng, op, 'label', 0.6, () => prose(rng, 1, 6) || 'the tower falls');
      maybe(rng, op, 'subjectEntityKey', 0.5, () => rng.pick([...ENTITY_KEYS, null]));
      maybe(rng, op, 'kind', 0.3, () => rng.pick(['rank', 'event', 'learned_from', 'custom']));
      break;
    case 'brief.update':
      Object.assign(op, { op: kind, chapter: rng.int(1, 6) });
      maybe(rng, op, 'title', 0.4, text(0, 4));
      maybe(rng, op, 'chapterPurpose', 0.3, text(0, 6));
      maybe(rng, op, 'direction', 0.3, () => (rng.chance(0.25) ? null : prose(rng, 0, 6)));
      maybe(rng, op, 'volumeKey', 0.3, () => rng.pick(VOLUME_KEYS));
      maybe(rng, op, 'pov', 0.35, () => rng.pick([...ENTITY_KEYS, null]));
      maybe(rng, op, 'scenes', 0.3, () => (rng.chance(0.2) ? null : Array.from({ length: rng.int(0, 2) }, () => ({ summary: prose(rng, 1, 4) || 'scene', pov: rng.pick([...ENTITY_KEYS, null]) }))));
      maybe(rng, op, 'knowledgeContract', 0.3, () =>
        rng.chance(0.2) ? null : { pov: [rng.pick(ENTITY_KEYS)], ...(rng.chance(0.6) ? { learns: Array.from({ length: rng.int(0, 2) }, () => ({ entityKey: rng.pick(ENTITY_KEYS), factKey: rng.pick(FACT_KEYS) })) } : {}) },
      );
      maybe(rng, op, 'claimedMilestones', 0.3, () => (rng.chance(0.2) ? null : [rng.pick(MILESTONE_KEYS)]));
      break;
    case 'draft.update':
      Object.assign(op, { op: kind, chapter: rng.int(1, 6), body: prose(rng, 0, 6) });
      maybe(rng, op, 'title', 0.5, text(0, 4));
      break;
    case 'draft.rewrite_passage':
      Object.assign(op, { op: kind, chapter: rng.int(1, 6), passage: 'the tower', replacement: prose(rng, 1, 4) });
      maybe(rng, op, 'label', 0.6, text(0, 5));
      break;
    case 'volume.remove':
      Object.assign(op, { op: kind, volumeKey: rng.pick(VOLUME_KEYS) });
      break;
    case 'brief.remove':
    case 'draft.remove':
      Object.assign(op, { op: kind, chapter: rng.int(1, 6) });
      break;
    case 'entity.remove':
      Object.assign(op, { op: kind, entityKey: rng.pick(ENTITY_KEYS) });
      break;
    case 'fact.remove':
      Object.assign(op, { op: kind, factKey: rng.pick(FACT_KEYS) });
      break;
    case 'milestone.remove':
      Object.assign(op, { op: kind, milestoneKey: rng.pick(MILESTONE_KEYS) });
      break;
    case 'promise.drop':
      Object.assign(op, { op: kind, kind: rng.pick(['thread', 'mystery']), key: rng.pick(PROMISE_KEYS) });
      break;
    case 'organise.rule':
      Object.assign(op, { op: kind, rule: prose(rng, 1, 5) || 'rule', optionId: 'o1' });
      break;
    default:
      Object.assign(
        op,
        rng.pick<Rec>([
          { op: 'action.generate_chapter', chapter: rng.int(1, 6) },
          { op: 'action.audit_bible' },
          { op: 'action.enhance_premise' },
          { op: 'action.judge_draft', chapter: rng.int(1, 6) },
          { op: 'action.revise_draft', chapter: rng.int(1, 6), note: 'tighten' },
          { op: 'action.approve_draft', chapter: rng.int(1, 6) },
          { op: 'action.apply_continuity', chapter: rng.int(1, 6) },
          { op: 'action.validate', scope: 'chapter', chapter: rng.int(1, 6) },
          { op: 'action.validate', scope: 'novel' },
          { op: 'action.finalize', upTo: rng.int(1, 6) },
          { op: 'action.organise_notes' },
          { op: 'action.plan_chapter', chapter: rng.int(1, 6) },
          { op: 'action.advance_volume', volumeKey: rng.pick(VOLUME_KEYS) },
        ]),
      );
  }
  if (rng.chance(0.2)) op['rationale'] = prose(rng, 1, 3);
  if (rng.chance(0.1)) op['ideaId'] = 'stale00000000000000000000';
  return rng.chance(0.4) ? shuffled(rng, op) : op;
}

const idCases: unknown[] = [];

function recordIds(ops: Rec[]): void {
  const { ok, parsed, errors } = validate(ops);
  if (!ok) throw new Error(`invalid scenario ${JSON.stringify(ops)} ${errors.join('; ')}`);
  const stamped = ideaId.stampIdeaIds(parsed) as Rec[];
  idCases.push([
    JSON.stringify(ops),
    parsed.map((op: unknown) => ideaId.ideaIdOf(op)),
    parsed.map((op: Rec) => (changeSet.isActionOp(op['op']) ? null : encode(ideaId.ideaLabel(op)))),
    stamped.map(op => (op['ideaId'] as string | undefined) ?? null),
  ]);
}

const page = (section: string, slug: string, extra: Rec = {}): Rec => ({ op: 'bible_document.upsert', section, slug, ...extra });
const entity = (entityKey: string, type: string, extra: Rec = {}): Rec => ({ op: 'entity.upsert', entityKey, type, ...extra });
const body = 'The tower falls at dawn';
const variants = (make: (text: string) => Rec, texts: string[]): void => {
  for (const text of texts) recordIds([make(text)]);
};

variants(text => entity('mara', 'character', { notes: text }), [
  body, `${body} `, ` ${body}`, body.replace(/ /g, '  '), body.replace(/ /g, '\t'), body.replace(/ /g, ' '), body.replace(/ /g, '　'), body.replace(/ /g, ' '), body.replace(/ /g, '\n'),
  body.replace(/ /g, '\r\n'), `﻿${body}`, `${body}﻿`, body.replace(/ /g, '​'), body.replace(/ /g, '\u0085'), body.replace(/ /g, '᠎'), body.toUpperCase(), body.toLowerCase(),
  'The tower falls at dawn.', 'The tower falls at dusk',
]);
variants(text => entity('mara', 'character', { notes: text }), [
  'café', 'café', 'CAFÉ', 'ＣＡＦＥ́', 'ﬁre', 'fire', 'ＦＩＲＥ', 'ΟΔΟΣ', 'οδος', 'οδοσ', 'οδοσ ', 'ΣΑΣ', 'σας', 'σασ', 'İ', 'i̇', 'I', 'ı', 'Å', 'Å', 'Å', 'ǅ', 'ǆ', 'Ǆ', '½', '1⁄2',
  '1⁄2', '①', '1', 'x²', 'x2', '𝒜', 'A', '𐐀', '𐐨', '‘a’', "'a'", '“a”', '"a"', 'a—b', 'a-b', 'a–b', '', ' ', '😀', '王国', '王　国', '\u0000', 'a\u0000b',
]);
variants(text => page('world', 'harbour', { body: text, frontmatter: { b: text, a: 1 } }), [body, `${body}\n`, `  ${body}`]);
for (const [first, second] of [
  [{ op: 'entity.upsert', entityKey: 'mara', type: 'character', notes: 'x', body: 'y' }, { body: 'y', notes: 'x', type: 'character', entityKey: 'mara', op: 'entity.upsert' }],
  [{ op: 'entity.upsert', entityKey: 'mara', type: 'character', notes: 'x', quote: 'q', rationale: 'r' }, { op: 'entity.upsert', entityKey: 'mara', type: 'character', notes: 'x' }],
  [{ op: 'entity.upsert', entityKey: 'mara', type: 'character', notes: 'x', ideaId: 'abc' }, { op: 'entity.upsert', entityKey: 'mara', type: 'character', notes: 'x', ideaId: 'def' }],
  [{ op: 'volume.upsert', volumeKey: 'v1', title: 't' }, { op: 'volume.upsert', volumeKey: 'v1', title: 't', objective: 'o' }],
  [{ op: 'fact.upsert', factKey: 'f', revealChapter: null }, { op: 'fact.upsert', factKey: 'f' }],
  [{ op: 'fact.upsert', factKey: 'f', unlock: { all: [{ milestone: 'm1' }, { chapter: 3 }] } }, { op: 'fact.upsert', factKey: 'f', unlock: { all: [{ chapter: 3 }, { milestone: 'm1' }] } }],
  [page('world', 'harbour', { frontmatter: { b: 1, a: 2, 10: 'x', 2: 'y' } }), page('world', 'harbour', { frontmatter: { 2: 'y', 10: 'x', a: 2, b: 1 } })],
  [page('world', 'harbour', { frontmatter: { a: { d: 1, c: 2 } } }), page('world', 'harbour', { frontmatter: { a: { c: 2, d: 1 } } })],
  [page('world', 'harbour', { frontmatter: { a: ['x', 'y'] } }), page('world', 'harbour', { frontmatter: { a: ['y', 'x'] } })],
  [page('world', 'harbour', { frontmatter: { 'é': 'x' } }), page('world', 'harbour', { frontmatter: { 'é': 'x' } })],
  [{ op: 'action.plan_chapter', chapter: 3 }, { op: 'action.plan_chapter', chapter: 3, ideaId: 'abc' }],
  [{ op: 'brief.update', chapter: 2, pov: null }, { op: 'brief.update', chapter: 2 }],
  [{ op: 'brief.update', chapter: 2, startedEmpty: true }, { op: 'brief.update', chapter: 2 }],
  [{ op: 'promise.set_payoff', kind: 'thread', key: 'p1', payoffWindow: 2 }, { op: 'promise.set_payoff', kind: 'thread', key: 'p1', payoffWindow: 3 }],
  [{ op: 'draft.rewrite_passage', chapter: 1, passage: 'a', replacement: 'b' }, { op: 'draft.rewrite_passage', chapter: 1, passage: 'a', replacement: 'b', label: 'x' }],
] as [Rec, Rec][]) {
  recordIds([first, second]);
  recordIds([second, first]);
}

const long = (count: number, unit = 'tower ') => unit.repeat(count);
const edge = (n: number, fill: string) => `${'x'.repeat(n)}${fill}`;
for (const notes of [
  long(40), long(41), `${long(39)}ab`, `a${' '.repeat(300)}b`, edge(238, '😀tail'), edge(239, '😀tail'), edge(240, '😀tail'), edge(237, '😀😀'), `${'é'.repeat(239)}x`, `${'é'.repeat(240)}`,
  `${'é'.repeat(241)}`, `  ${'a '.repeat(150)}`, ` ${'b　'.repeat(150)}`, 'multi\nline\r\ntext\ttab', '   ', '', 'ok',
]) {
  recordIds([entity('mara', 'character', { notes })]);
  recordIds([{ op: 'premise.update', theme: notes, premise: '', themes: ['x', ' y '] }]);
}
for (const op of [
  { op: 'premise.update' }, { op: 'premise.update', themes: [] }, { op: 'premise.update', themes: ['a', 'b'] }, { op: 'premise.update', brief: ' ', instructions: 'i', opposition: 'o' },
  { op: 'premise.update', endingQuestion: 'q', ending: 'e' }, { op: 'premise.update', protagonistKey: 'mara', theme: ' t ' },
  page('project', 'timeline', { body }), page('project', 'open-questions', { body }), page('story_state', 'volume-plan', { body }), page('story_state', 'volumes', { body }),
  page('plot', 'escalation-map', { body }), page('project', 'cast', { body }), page('project', 'cast'), page('project', 'cast', { body: '  ' }),
  { op: 'bible_document.remove', section: 'world', slug: 'harbour' }, { op: 'volume.remove', volumeKey: 'v1' }, { op: 'brief.remove', chapter: 4 }, { op: 'draft.remove', chapter: 5 },
  { op: 'draft.update', chapter: 2, title: 'T' }, { op: 'draft.update', chapter: 2, title: 'T', body: 'b' }, { op: 'draft.rewrite_passage', chapter: 2, passage: 'p', replacement: 'r', label: 'L' },
  entity('mara', 'character'), entity('mara', 'character', { name: 'Mara' }), entity('mara', 'location', { name: 'Mara', body: 'b' }), entity('mara', 'item', { status: 's', notes: 'n', body: 'b' }),
  { op: 'entity.remove', entityKey: 'mara' }, { op: 'fact.upsert', factKey: 'f', body: 'secret' }, { op: 'fact.remove', factKey: 'f' },
  { op: 'milestone.upsert', milestoneKey: 'm1' }, { op: 'milestone.upsert', milestoneKey: 'm1', label: 'label' }, { op: 'milestone.remove', milestoneKey: 'm1' },
  { op: 'promise.create', kind: 'thread', key: 'p1', label: 'who rang' }, { op: 'promise.update', kind: 'mystery', key: 'p1' }, { op: 'promise.update', kind: 'mystery', key: 'p1', label: 'l' },
  { op: 'promise.set_payoff', kind: 'thread', key: 'p1', someday: true }, { op: 'promise.drop', kind: 'thread', key: 'p1' },
  { op: 'brief.update', chapter: 3 }, { op: 'brief.update', chapter: 3, title: ' ', chapterPurpose: 'purpose', direction: 'dir' }, { op: 'brief.update', chapter: 3, direction: null },
  { op: 'volume.upsert', volumeKey: 'v1' }, { op: 'volume.upsert', volumeKey: 'v1', objective: 'obj' }, { op: 'organise.rule', rule: 'a rule', optionId: 'o' },
  { op: 'action.audit_bible' }, { op: 'action.apply_continuity', chapter: 2 }, { op: 'action.judge_draft', chapter: 2 }, { op: 'action.revise_draft', chapter: 2, note: 'n' }, { op: 'action.enhance_premise' }, { op: 'action.organise_notes' }, { op: 'action.plan_chapter', chapter: 2 }, { op: 'action.approve_draft', chapter: 2 }, { op: 'action.advance_volume', volumeKey: 'v1' }, { op: 'action.generate_chapter', chapter: 2 }, { op: 'action.finalize' }, { op: 'action.validate', scope: 'novel' },
] as Rec[]) {
  recordIds([op]);
}

const idRng = createRng(0x1dea5);
for (let i = 0; i < 60; i++) {
  const ops: Rec[] = [];
  const target = idRng.int(1, 4);
  for (let attempt = 0; attempt < target * 4 && ops.length < target; attempt++) {
    ops.push(contentOp(idRng));
    if (!validate(ops).ok) ops.pop();
  }
  if (ops.length > 0) recordIds(ops);
}

const filterCases: unknown[] = [];
const encodeDisposition = (d: { side: string; source?: string; reason?: string; rule?: string }): string =>
  d.side === 'direct' ? `d:${d.source}` : d.rule ? `c:${d.reason}:${d.rule}` : `c:${d.reason}`;

interface PolicyOptions {
  vocabulary?: string;
  mode?: string;
  ideas?: string;
  justDiscussing?: boolean;
  hold?: string;
}

function recordFilter(ops: Rec[], message: string, current: [string, string][], options: PolicyOptions, rejectedPick: (ids: string[], all: string[]) => string[]): void {
  const { ok, parsed, errors } = validate(ops);
  if (!ok) throw new Error(`invalid scenario ${JSON.stringify(ops)} ${errors.join('; ')}`);
  const state = { current: new Map(current.map(([ref, fields]) => [ref, JSON.parse(fields)])) };
  const { vocabulary, mode = 'auto', ideas, justDiscussing, hold = 'none' } = options;
  const split = policy.splitChangeSet({ ops: parsed, authorMessage: message, vocabulary, mode, ideas, justDiscussing, hold, state });
  const filterable: string[] = ideaFilter.filterableIdeaIds(split);
  const rejected = rejectedPick(filterable, split.ops.map((op: unknown) => ideaId.ideaIdOf(op)));
  const result = ideaFilter.dropRejectedIdeas(split, new Set(rejected), state.current);
  filterCases.push([
    JSON.stringify(ops), message, vocabulary ?? null, mode, ideas ?? null, justDiscussing ?? null, hold, current, rejected, filterable, result.dropped,
    result.split.ops.map((op: unknown) => split.ops.indexOf(op)),
    result.split.dispositions.map(encodeDisposition),
    result.split.held,
    result.split.sources,
    result.split.direct.length,
    result.split.cards.length,
    result.split === split ? 1 : 0,
  ]);
}

const said = 'The tower falls at dawn and Mara keeps the lantern burning. The harbour guild smuggles salt through the marsh.';
const quote = 'Mara keeps the lantern burning';
const all = (ids: string[]): string[] => ids;
const none = (): string[] => [];
const first = (ids: string[]): string[] => ids.slice(0, 1);
const last = (ids: string[]): string[] => ids.slice(-1);
const milestone = (milestoneKey: string, extra: Rec = {}): Rec => ({ op: 'milestone.upsert', milestoneKey, ...extra });
const fields = (value: Rec): string => JSON.stringify(value);
const SCENARIOS: [Rec[], [string, string][], PolicyOptions, (ids: string[], all: string[]) => string[]][] = [];
const policies: PolicyOptions[] = [{ ideas: 'apply' }, { ideas: 'card' }, {}, { ideas: 'apply', hold: 'turn' }, { ideas: 'apply', hold: 'writer_read' }];
const SHAPES: Rec[][] = [
  [entity('dawn', 'location', { name: 'Dawn' }), milestone('m1', { label: 'tower falls', subjectEntityKey: 'dawn' })],
  [entity('mara', 'character', { name: 'Mara', notes: 'keeps the lantern burning', quote }), milestone('m1', { label: 'tower falls', subjectEntityKey: 'mara' })],
  [entity('vell', 'character', { name: 'Vell' }), { op: 'fact.upsert', factKey: 'f1', body: 'smuggles salt', subjects: ['vell'] }],
  [entity('vell', 'character', { name: 'Vell' }), { op: 'brief.update', chapter: 2, pov: 'vell' }, { op: 'brief.update', chapter: 3, pov: 'mara' }],
  [entity('guild', 'faction', { name: 'Guild' }), page('world', 'factions-and-locations', { body: 'The guild smuggles salt' })],
  [entity('guild', 'faction', { name: 'Guild' }), entity('dawn', 'location', { name: 'Dawn' }), page('world', 'factions-and-locations', { body: 'Guild and dawn' })],
  [entity('mara', 'character', { name: 'Mara' }), page('project', 'cast', { body: 'Mara' }), page('project', 'cast', { body: 'again', quote })],
  [page('project', 'cast', { body: 'Mara' }), entity('mara', 'character', { name: 'Mara', quote })],
  [page('project', 'cast', { body: '   ' }), entity('mara', 'character', { name: 'Mara' })],
  [milestone('m1', { label: 'tower falls' }), { op: 'promise.set_payoff', kind: 'thread', key: 'p1', payoffMilestoneKey: 'm1' }, { op: 'promise.set_payoff', kind: 'thread', key: 'p2', payoffMilestoneKey: 'm9' }],
  [{ op: 'volume.upsert', volumeKey: 'v2', title: 'Winter' }, { op: 'fact.upsert', factKey: 'f1', unlock: { all: [{ volume: 'v2' }, { milestone: 'm1' }] } }, milestone('m1', { label: 'x' })],
  [{ op: 'entity.remove', entityKey: 'vell' }, milestone('m1', { label: 'tower falls', subjectEntityKey: 'vell' })],
  [{ op: 'action.plan_chapter', chapter: 3 }, entity('mara', 'character', { name: 'Mara' }), { op: 'brief.update', chapter: 3, pov: 'mara' }],
  [{ op: 'action.generate_chapter', chapter: 3 }, { op: 'draft.update', chapter: 3, body: 'x' }, { op: 'brief.update', chapter: 3, title: 't' }],
  [entity('a', 'concept'), entity('b', 'concept', { name: 'B' }), { op: 'fact.upsert', factKey: 'f1', subjects: ['a', 'b'] }, milestone('m1', { subjectEntityKey: 'a' })],
  [page('world', 'harbour', { body: 'harbour' }), page('project', 'premise', { body: 'premise' }), { op: 'premise.update', theme: 'salt' }],
  [entity('mara', 'character', { notes: 'keeps the lantern burning', quote }), entity('mara', 'character', { body: 'second' })],
  [entity('guild', 'faction', { name: 'Guild' }), entity('dawn', 'location', { name: 'Dawn' }), page('world', 'factions-and-locations', { body: 'Guild' }), page('world', 'factions-and-locations', { body: 'Dawn' })],
];
for (const shape of SHAPES) {
  for (const options of policies) {
    for (const [pick] of [[all], [first], [last]] as const) SCENARIOS.push([shape, [], options, pick]);
    SCENARIOS.push([shape, [['entity:mara', fields({ name: 'Mara' })], ['entity:vell', fields({ name: 'Vell' })], ['entity:dawn', fields({ name: 'Dawn' })]], options, all]);
  }
}
const CHAINS: Rec[][] = [
  [entity('ee', 'character'), milestone('m1', { subjectEntityKey: 'ee' }), { op: 'promise.set_payoff', kind: 'thread', key: 'p', payoffMilestoneKey: 'm1' }, milestone('m2', { subjectEntityKey: 'ee' })],
  [{ op: 'promise.set_payoff', kind: 'thread', key: 'p', payoffMilestoneKey: 'm1' }, milestone('m1', { subjectEntityKey: 'ee' }), milestone('m2', { subjectEntityKey: 'ee' }), entity('ee', 'character')],
  [entity('ee', 'character'), milestone('m2', { subjectEntityKey: 'ee' }), { op: 'promise.set_payoff', kind: 'thread', key: 'p', payoffMilestoneKey: 'm1' }, milestone('m1', { subjectEntityKey: 'ee' })],
  [entity('guild', 'faction'), page('world', 'factions-and-locations', { body: 'The guild' }), entity('dawn', 'location'), page('world', 'factions-and-locations', { body: 'Dawn' })],
  [entity('guild', 'faction'), entity('dawn', 'location'), page('world', 'factions-and-locations', { body: 'Both' }), milestone('m1', { subjectEntityKey: 'guild' })],
  [entity('guild', 'faction'), milestone('m1', { subjectEntityKey: 'guild' }), entity('dawn', 'location'), page('world', 'factions-and-locations', { body: 'Both' }), milestone('m2', { subjectEntityKey: 'dawn' })],
  [entity('mara', 'character'), page('project', 'cast', { body: 'Mara' }), milestone('m1', { subjectEntityKey: 'mara' }), { op: 'promise.set_payoff', kind: 'thread', key: 'p', payoffMilestoneKey: 'm1' }],
];
for (const chain of CHAINS) {
  for (const options of [{ ideas: 'card' }, {}, { ideas: 'apply' }]) {
    SCENARIOS.push([chain, [], options, first]);
    SCENARIOS.push([chain, [], options, ids => ids.slice(0, 2)]);
    SCENARIOS.push([chain, [], options, last]);
  }
}
for (const [ops, current, options, pick] of SCENARIOS) recordFilter(ops, said, current, options, pick);

const filterRng = createRng(0xf11);
for (let i = 0; i < 50; i++) {
  const ops: Rec[] = [];
  const target = filterRng.int(1, 7);
  for (let attempt = 0; attempt < target * 4 && ops.length < target; attempt++) {
    const candidate = contentOp(filterRng);
    delete candidate['ideaId'];
    if (filterRng.chance(0.35)) candidate['quote'] = filterRng.pick([quote, 'The tower falls at dawn', 'smuggles salt through the marsh', 'unrelated words entirely here']);
    ops.push(candidate);
    if (!validate(ops).ok) ops.pop();
  }
  if (ops.length === 0) continue;
  const parsed = JSON.parse(JSON.stringify(ops));
  changeSet.validateChangeSet(parsed, undefined, OPTIONS);
  const refs: string[] = [...changeSet.changeSetRefs(parsed), ...parsed.flatMap((op: Rec) => policy.opReferences(op))];
  const current: [string, string][] = [];
  for (const ref of new Set(refs)) if (filterRng.chance(0.35)) current.push([ref, fields(filterRng.pick([{}, { name: 'x' }, { body: 'tower' }]))]);
  const mode = filterRng.chance(0.9) ? 'auto' : 'manual';
  const selector = filterRng.int(0, 4);
  recordFilter(ops, said, current, { mode, ideas: filterRng.pick(['apply', 'apply', 'card', undefined]), justDiscussing: filterRng.chance(0.05), hold: filterRng.pick(['none', 'none', 'none', 'turn', 'writer_read']) }, (ids, every) => {
    if (selector === 0) return ids;
    if (selector === 1) return ids.filter(() => filterRng.chance(0.5));
    if (selector === 2) return [...every.filter(() => filterRng.chance(0.4)), 'f'.repeat(24)];
    if (selector === 3) return ids.slice(0, 1);
    return [];
  });
}

interface Ctx {
  active: string | null;
  states: Record<string, { exists: boolean; revision: number | null; contentHash: string | null }>;
}

const HASHES = ['h1', 'h2', null];
const stateOf = (rng: Rng) => ({ exists: rng.chance(0.7), revision: rng.pick([null, 1, 2, 7]), contentHash: rng.pick(HASHES) });
const REFS = ['premise', 'doc:world/harbour', 'volume:v1', 'chapter:2', 'entity:mara', 'fact:f1', 'milestone:m1', 'promise:thread:p1', 'draft:3'];
const contexts: Ctx[] = [
  { active: null, states: {} },
  { active: 'v1', states: {} },
  { active: 'v2', states: { premise: { exists: true, revision: 2, contentHash: 'h1' }, 'entity:mara': { exists: false, revision: null, contentHash: null } } },
  { active: null, states: { premise: { exists: true, revision: 1, contentHash: 'h1' }, 'volume:v1': { exists: true, revision: 1, contentHash: 'h2' } } },
];
const ctxRng = createRng(0xc7);
for (let i = 0; i < 6; i++) contexts.push({ active: ctxRng.pick([null, 'v1', 'v2', 'winter', '']), states: Object.fromEntries(REFS.filter(() => ctxRng.chance(0.6)).map(ref => [ref, stateOf(ctxRng)])) });
const toContext = (ctx: Ctx) => ({ activeVolumeKey: ctx.active, states: ctx.states });

const scopeCases: unknown[] = [];
const anchorCases: unknown[] = [];
const refCases: unknown[] = [];
const rejectionRng = createRng(0x5c09e);
const missing = artifactState.MISSING_ARTIFACT;
const mixedStates = (ctx: Ctx, rng: Rng): Record<string, unknown> =>
  Object.fromEntries(REFS.filter(() => rng.chance(0.4)).map(ref => [ref, rng.chance(0.7) ? (ctx.states[ref] ?? missing) : stateOf(rng)]));
const anchorFor = (rng: Rng, ctx: Ctx): unknown => {
  const roll = rng.next();
  if (roll < 0.05) return null;
  if (roll < 0.35) return { volumeKey: rng.pick([ctx.active, 'v1', 'v2', null, '']) };
  if (roll < 0.4) return { volumeKey: 5 };
  if (roll < 0.45) return {};
  if (roll < 0.5) return { states: {} };
  if (roll < 0.55) return { states: { premise: { exists: true } } };
  if (roll < 0.58) return { states: { premise: { exists: 'yes', revision: 1, contentHash: 'h1' } } };
  if (roll < 0.6) return { states: { premise: { exists: true, revision: '1', contentHash: 'h1' } } };
  if (roll < 0.62) return { states: { premise: { exists: true, revision: 1.5, contentHash: 'h1' } } };
  return { states: mixedStates(ctx, rng) };
};
for (const [index, ctx] of contexts.entries()) {
  for (let i = 0; i < 30; i++) {
    const rng = rejectionRng;
    const scope = rng.pick([null, 'never', 'not_now', 'not_this_version', 'not_this_version', 'not_now']);
    const entry = { ideaId: rng.pick(['abc', 'abc', 'abc', null, '']), rejectionScope: scope, rejectionAnchor: anchorFor(rng, ctx) };
    scopeCases.push([index, entry.ideaId, entry.rejectionScope, JSON.stringify(entry.rejectionAnchor), rejections.rejectionInScope(entry, toContext(ctx))]);
  }
  for (const scope of ['never', 'not_now', 'not_this_version']) {
    for (const refs of [[], ['premise'], ['premise', 'premise', 'entity:mara'], REFS]) {
      anchorCases.push([scope, index, refs, JSON.stringify(rejections.rejectionAnchor(scope, toContext(ctx), refs))]);
    }
  }
}
for (let i = 0; i < 40; i++) {
  const rng = rejectionRng;
  const entries = Array.from({ length: rng.int(0, 4) }, () => {
    const scope = rng.pick([null, 'never', 'not_now', 'not_this_version', 'not_this_version']);
    return { ideaId: 'abc', rejectionScope: scope, rejectionAnchor: scope === 'not_this_version' ? { states: mixedStates(contexts[2] as Ctx, rng) } : anchorFor(rng, contexts[1] as Ctx) };
  });
  const refs = rng.pick([[], ['premise'], ['entity:mara', 'premise'], REFS]);
  const anchored = entries.flatMap(entry => (entry.rejectionScope === 'not_this_version' && entry.rejectionAnchor !== null && typeof entry.rejectionAnchor === 'object' && 'states' in entry.rejectionAnchor ? Object.keys((entry.rejectionAnchor as { states: object }).states) : []));
  refCases.push([JSON.stringify(entries), refs, [...new Set([...anchored, ...refs])]]);
}

interface Volume {
  volumeKey: string;
  ordinal: number;
  state: string;
}
const ledgerCases: unknown[] = [];
const ledgerRng = createRng(0x1ed9);
for (let i = 0; i < 90; i++) {
  const rng = ledgerRng;
  const volumes: Volume[] = Array.from({ length: rng.int(0, 4) }, (_, n) => ({ volumeKey: `v${n}`, ordinal: rng.int(0, 3), state: rng.pick(['not_started', 'active', 'active', 'goal_met']) }));
  const active = volumes.filter(volume => volume.state === 'active').reduce<Volume | undefined>((best, volume) => (best === undefined || volume.ordinal < best.ordinal ? volume : best), undefined);
  const entries = Array.from({ length: rng.int(0, 6) }, () => {
    const scope = rng.pick([null, 'never', 'not_now', 'not_now', 'not_this_version']);
    const anchor = scope === 'not_this_version' ? { states: rng.chance(0.5) ? {} : { 'entity:mara': stateOf(rng) } } : anchorFor(rng, { active: active?.volumeKey ?? null, states: {} });
    return { ideaId: rng.pick(['a', 'b', 'c', 'c', null, '']), rejectionScope: scope, rejectionAnchor: anchor };
  });
  const needsStates = entries.some(entry => entry.rejectionScope === 'not_this_version' && entry.rejectionAnchor !== null && typeof entry.rejectionAnchor === 'object' && 'states' in entry.rejectionAnchor && Object.keys((entry.rejectionAnchor as { states: object }).states).length > 0);
  if (needsStates) continue;
  const ideaIds = rng.pick([[], ['a'], ['a', 'b', 'c'], ['c', 'c', 'zzz']]);
  const db = {
    query: {
      decisionLedgerEntries: { findMany: async () => entries.filter(entry => entry.ideaId !== null && ideaIds.includes(entry.ideaId)) },
      volumes: { findFirst: async () => (active ? { volumeKey: active.volumeKey } : undefined) },
    },
  };
  const rejected = [...(await rejections.loadRejectedIdeas(db, 1n, ideaIds))];
  const kept = await rejections.withoutLapsedRejections(db, 1n, entries);
  ledgerCases.push([JSON.stringify(volumes), JSON.stringify(entries), ideaIds, rejected, entries.flatMap((entry, at) => (kept.includes(entry) ? [at] : []))]);
}

const negationCases: unknown[] = [];
const requestCases: unknown[] = [];
const echoes = (before: string, after: string, exempt: string[] = []): void => {
  const found = negation.findNegationEchoes(before, after, exempt.length > 0 ? { exempt: new Set(exempt) } : undefined) as { terms: string[]; excerpt: string }[];
  negationCases.push([before, after, exempt, found.map(echo => [echo.terms, encode(echo.excerpt)])]);
};
const request = (message: string): void => {
  requestCases.push([message, [...negation.requestedNegations(message)]]);
};

const NEG_FIXED: [string, string][] = [
  ['The queen carries a sword.', 'The queen carries no sword.'],
  ['The queen carries a sword.', 'There is no sword in the scene.'],
  ['The tower has a dragon and a lantern', 'The tower has no dragon and no lantern.'],
  ['dragons everywhere', 'without dragons or knights'],
  ['A dragon. A knight.', 'None of the dragons appear. Nobody sees knights.'],
  ['Magic is everywhere.', 'Magic is not mentioned.'],
  ['Magic is everywhere.', 'The chapter does not mention magic.'],
  ['Magic is everywhere.', "The chapter doesn't mention magic or swords"],
  ['Magic is everywhere.', 'The chapter never mentions magic.'],
  ['Magic is everywhere.', 'She never learns magic.'],
  ['The queen rejoins the caravan.', 'The queen never rejoins the caravan.'],
  ['The queen rejoins the caravan.', 'The queen does not yet rejoin the caravan.'],
  ['She distrusts him.', "She doesn't distrust him anymore."],
  ['She distrusts him.', 'She no longer distrusts him.'],
  ['The lantern burns.', 'The lantern is not burning.'],
  ['The lantern burns.', "The lantern isn't burning."],
  ['The lantern burns.', 'Mara is not burning.'],
  ['The lantern burns near Mara.', 'The old lantern is not lit.'],
  ['The old lantern is lit.', 'Mara and the lantern are not lit.'],
  ['The old lantern is lit.', 'Lantern is not lit.'],
  ['dragon story', 'a story free of dragon'],
  ['dragon story', 'a story instead of dragon tales'],
  ['dragon story', 'a story rather than dragon tales'],
  ['dragon story', 'the absence of dragon here'],
  ['dragon story', 'the absence of'],
  ['Wizards and castles', 'Avoid wizards. Avoiding castles. Omit castles. Omits wizards. Lacks castles. Lacking wizards.'],
  ['Wizards and castles', 'Neither wizards nor castles.'],
  ['dragons knights wizards castles', 'no one two three four five six dragons knights wizards castles'],
  ['dragons knights wizards castles', 'no one two three four five dragons knights wizards castles'],
  ['wizard', "wizard's tower. no wizard's tower"],
  ['wizards', 'No wizards. No wizard.'],
  ['bosses glass class', 'no bosses, no glass, no class'],
  ['stories cities ties lies', 'no stories no cities no ties no lies'],
  ['mara’s sword', 'no mara’s sword'],
  ['Mara’s sword', "no Mara's sword"],
  ['dragon', '- No dragons here'],
  ['dragon', '* no dragons here'],
  ['dragon', '• no dragons here'],
  ['dragon', '-no dragons here'],
  ['dragon', 'Intro.\nNo dragons.\r\nNo dragons!\n\nno dragons?'],
  ['dragon', 'no dragons; no dragons: no dragons'],
  ['dragon', ''],
  ['', 'no dragons'],
  ['dragon', '...'],
  ['no', 'no no no'],
  ['dragon', 'no dragon dragon dragon'],
  ['dragon', 'no dragon. dragon'],
  ['dragon', 'dragon. no dragon'],
  ['DRAGON', 'no Dragon'],
  ['dragon', 'NO DRAGON'],
  ['dragon sword', 'no sword and no dragon and no dragons and no sword'],
  ['龙 dragon 王国', '没有 王国 no 龙 no 王国'],
  ['王国王国', 'no 王国王国'],
  ['王国王国王国', 'no 王国王国王国'],
  ['日本語のテキスト', 'no 日本語のテキスト'],
  ['한국어', 'no 한국어'],
  ['ΟΔΟΣ ΣΑΣ', 'no οδος no σας'],
  ['ΟΔΟΣ ΣΑΣ', 'no ΟΔΟΣ no ΣΑΣ'],
  ['οδος', 'no ΟΔΟΣ'],
  ['İstanbul tower', 'no İstanbul'],
  ['İstanbul tower', 'no i̇stanbul'],
  ['istanbul', 'no İstanbul'],
  ['İİİİ', 'no İİİİ'],
  ['straße harbour', 'no straße and no STRASSE'],
  ['ﬁre place', 'no ﬁre'],
  ['fire place', 'no ﬁre'],
  ['Å Ångström', 'no Ångström'],
  ['café', 'no café'],
  ['café', 'no café'],
  ['dragon', 'no\tdragon here'],
  ['dragon', 'no　dragon'],
  ['dragon', 'no dragon and no dragon'],
  ['dragon', 'no﻿dragon'],
  ['dragon', 'no​dragon'],
  ['dragon', 'no\u0085dragon'],
  ['dragon', 'no᠎dragon'],
  ['dragon', 'no\u000bdragon'],
  ['😀 dragon', 'no 😀 dragon 😀'],
  ['𠀀𠀀𠀀𠀀', 'no 𠀀𠀀𠀀𠀀'],
  ['𐐀ngel', 'no 𐐀ngel'],
  ['dragon', 'there are no dragons in the east'],
  ['dragon', 'nor dragons nor knights'],
  ['dragon', 'These are not dragons. They were not dragons. Those were never dragons.'],
  ['dragon', 'The dragons are not here. The dragons were not here. The dragon is not here. A dragon be not here.'],
  ['dragon', 'the dragon isn’t here and the dragons aren’t here and a dragon wasn’t here and they weren’t here'],
  ['dragon', 'dragons isn’t'],
  ['dragon', 'Dragons isn’t here'],
  ['dragon', 'The dragon, it is not here'],
  ['dragon', 'not not not not dragon'],
  ['dragon', 'never mentions the dragon, never shows dragons'],
  ['dragon', 'not mention dragon, not include dragon, not reference dragon, not feature dragon, not show dragon, not name dragon, not describe dragon, not depict dragon, not appear dragon, not exist dragon'],
  ['dragon', 'does not yet mention the dragon'],
  ['dragon', 'no longer mentions the dragon'],
  ['dragon', 'not shown dragons'],
  ['dragon', 'not named dragons'],
  ['dragon', 'cannot see dragon'],
  ['dragon', "can't see dragon. won't see dragon. don't see dragon"],
  ['dragon', 'n’t dragon'],
  ['dragon', 'dragon not'],
  ['dragon', 'dragon is not'],
  ['dragon', 'is not dragon'],
  ['dragon', 'a b is not dragon'],
  ['dragon sword', 'sword dragon is not here'],
  ['dragon sword', 'Sword dragon is not here'],
  ['dragon sword', 'Sword Dragon is not here'],
  ['dragon sword', 'sword Dragon is not here'],
  ['dragon sword', 'sword dragon aren’t here'],
  ['sword', 'x dragon sword is not here and is not sword'],
  ['sword', 'free of'],
  ['sword', 'instead of sword'],
  ['sword', 'instead of'],
  ['sword', 'rather than sword'],
  ['sword', 'Free of sword'],
  ['sword', 'free  of sword'],
  ['sword', 'free of sword'],
  ['sword', 'absence of sword'],
  ['sword', 'absence of sword anymore'],
  ['sword', 'no sword anymore'],
  ['sword', 'no sword. no sword anymore'],
  ['sword', 'no sword yet'],
  ['sword', 'not yet sword'],
  ['sword', 'never longer sword'],
  ['sword', 'no yet sword'],
  ['sword', 'no longer sword'],
  ['sword', "don't yet sword"],
  ['x'.repeat(200) + ' dragon', `${'word '.repeat(40)}no dragon`],
  ['dragon', `no dragon ${'word '.repeat(33)}`],
  ['dragon', `no dragon ${'x'.repeat(147)}`],
  ['dragon', `no dragon ${'x'.repeat(148)}`],
  ['dragon', `no dragon ${'x'.repeat(149)}`],
  ['dragon', `no dragon ${'x'.repeat(150)}`],
  ['dragon', `no dragon ${'x'.repeat(148)} `],
  ['dragon', `no dragon ${'x'.repeat(146)}   y`],
  ['dragon', `no dragon ${'x'.repeat(145)}😀😀`],
  ['dragon', `no dragon ${'x'.repeat(146)}😀😀`],
  ['dragon', `no dragon ${'x'.repeat(147)}😀😀`],
  ['dragon', `no dragon ${'x'.repeat(148)}😀😀`],
  ['dragon', `no dragon ${'x'.repeat(146)}　　　　zzz`],
  ['dragon', `no dragon${'　'.repeat(160)}x`],
  ['dragon', `  no dragon${' '.repeat(3)}`],
  ['dragon sword', 'no dragon. no sword! no dragon? no sword'],
  ['dragon', 'no 12345 dragon'],
  ['dragon', 'no ab abc abcd dragon'],
  ['abcd', 'no abcd abcde abcds abcdss'],
  ['abcds', 'no abcds'],
  ['abcds', 'no abcd'],
  ['abcdss', 'no abcdss'],
  ['about after', 'no about no after no chapter no scene'],
  ['dragon', 'no none nobody nothing dragon'],
  ['dragon', 'no cannot dragon'],
  ['The tower stands.', 'The tower is not yet built.'],
  ['The tower stands.', "The tower isn't yet built."],
  ['The tower stands.', 'The tower was never yet built.'],
  ['The tower stands.', 'The tower no longer stands.'],
  ['The tower stands.', 'The tower is no longer built.'],
  ['The tower stands.', 'The tower are not built.'],
  ['dragon', 'no mention one two three four five dragon'],
  ['dragon', 'no mentions one two three four five dragon'],
  ['dragon', 'no mention one two three four dragon'],
  ['The ancient tower stands.', "The ancient tower was isn't built."],
  ['The ancient tower stands.', "The ancient tower is isn't built."],
  ['maybe the tower falls', 'no maybe, perhaps not'],
  ['if the tower falls, might it rise', 'the tower will not fall if the tower might rise'],
  ['perhaps the queen could win', 'the queen could never win, not perhaps, not maybe, no possibly'],
  ['I wonder whether the dragon is real', 'whether the dragon is real is not wondered; no wonder, no dragon'],
  ['it is not sure', 'not sure about the dragon: no suppose, no imagine, no probably'],
];
for (const [before, after] of NEG_FIXED) {
  echoes(before, after);
  if ((before.length + after.length) % 3 === 0) echoes(before, after, ['dragon', 'sword', '王国', 'οδος']);
}
for (const message of [
  'say there is no dragon', 'Say there is no dragon in the book', 'please state that there is no magic', 'rule out dragons: no dragons', 'spell out that there is no dragon', 'make it clear there is no dragon',
  'make clear no dragons exist', 'write that there is no dragon', 'note that there are no wizards', 'add a line saying nothing about dragons', 'saying no dragon', 'the stating of no dragon', 'it states no dragon',
  'ruled no dragon', 'instead of dragons say no wizards', 'remove the dragons instead of dragons', 'SAY NO DRAGON', 'say no dragon, no sword', 'say no dragon. no sword. Knights are not here',
  'say there is no 王国', 'say no οδος', 'say no ΟΔΟΣ', 'say İstanbul has no İstanbul', 'say　no dragon', 'say no dragon', 'say﻿no dragon', 'say​no dragon', 'say',
  '', 'no dragon', 'say that dragons never mention magic', 'say Knights are not here', 'say the dragon is not here', "say the dragon isn't here", 'say no one two three four five dragon', 'say avoid dragons',
  'say there are no dragons and swords', 'say no longer dragon', 'say no dragon anymore', 'rules say no dragon', 'ruler no dragon', 'unstated no dragon', 'say no 𠀀𠀀𠀀𠀀',
]) {
  request(message);
}

const NEG_WORDS = [
  'dragon', 'dragons', 'sword', 'swords', 'knight', "knight's", 'Mara', 'Queen', 'tower', 'lantern', 'ΟΔΟΣ', 'οδος', 'İstanbul', 'i̇stanbul', 'straße', '王国', '龙', 'ひかり', '왕국', 'the', 'a', 'of', 'is',
  'in', 'here', 'there', 'chapter', 'scene', 'about', '😀', '𠀀𠀀𠀀𠀀', 'café', 'café', 'glass', 'boss', 'bosses', 'stories', 'yet', 'anymore', 'longer',
];
const NEG_CUES = [
  'no', 'No', 'without', 'none', 'nor', 'neither', 'nobody', 'nothing', 'nowhere', 'avoid', 'avoiding', 'omits', 'lacks', 'lacking', 'not', 'never', "isn't", 'aren’t', "wasn't", "don't", 'cannot',
  'free of', 'instead of', 'rather than', 'absence of', 'is not', 'are never', 'was not', 'not mention', 'never include', 'does not yet', 'no longer', 'not appear', 'nicht', '没有',
];
const NEG_BREAKS = ['. ', '! ', '? ', '; ', ': ', '\n', '\r\n', '\n\n', '...', ' - ', '. - ', '. * '];
const SPACES = [' ', ' ', ' ', ' ', '  ', '\t', ' ', '　', ' ', ' '];
const negRng = createRng(0x4e6a);
const clauseOf = (rng: Rng, cueChance: number): string => {
  const parts: string[] = [];
  const count = rng.int(1, 9);
  for (let i = 0; i < count; i++) {
    if (rng.chance(cueChance / 2)) parts.push(rng.pick(NEG_CUES));
    parts.push(rng.pick(NEG_WORDS));
  }
  return parts.join(rng.chance(0.1) ? rng.pick(SPACES) : ' ');
};
const textOf = (rng: Rng, cueChance: number): string => {
  const count = rng.int(0, 4);
  let out = '';
  for (let i = 0; i < count; i++) out += (i > 0 ? rng.pick(NEG_BREAKS) : '') + clauseOf(rng, cueChance);
  return out;
};
for (let i = 0; i < 260; i++) {
  const rng = negRng;
  const before = textOf(rng, 0.1);
  const after = rng.chance(0.6) ? textOf(rng, 0.8) : `${before}${rng.pick(NEG_BREAKS)}${textOf(rng, 0.9)}`;
  echoes(before, after, rng.chance(0.15) ? [rng.pick(NEG_WORDS).toLowerCase()] : []);
}
for (let i = 0; i < 60; i++) request(`${negRng.pick(['say ', 'state ', 'make it clear ', 'rule ', 'note that ', 'add a line ', '', 'spelling '])}${textOf(negRng, 0.8)}`);

const write = (name: string, value: unknown): void => writeFileSync(join(outDir, name), JSON.stringify(value) + '\n');
write('ids.json', idCases);
write('filter.json', filterCases);
write('rejections.json', { contexts: contexts.map(toContext), scopes: scopeCases, anchors: anchorCases, refs: refCases, ledger: ledgerCases });
write('negation.json', { echoes: negationCases, requests: requestCases });
