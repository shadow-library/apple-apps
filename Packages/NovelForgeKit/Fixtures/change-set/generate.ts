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

plugin({
  name: 'change-set-fixture-stubs',
  setup(build) {
    build.module('@server/classes', () => ({ exports: { AppErrorCode: classes.AppErrorCode }, loader: 'object' }));
    build.module('@server/common', () => ({
      exports: { validateBriefScenes: briefScenes.validateBriefScenes, validateUnlockCondition: unlockCondition.validateUnlockCondition },
      loader: 'object',
    }));
  },
});

const changeSetDir = join(server, 'modules/refinement/change-set');
const validation = await import(join(changeSetDir, 'change-set-validation.ts'));
const vocabulary = await import(join(changeSetDir, 'op-vocabulary.ts'));
const opSpecs = await import(join(changeSetDir, 'op-specs.ts'));
const refs = await import(join(changeSetDir, 'change-set-refs.ts'));
const manifest = await import(join(server, 'modules/bible/bible-manifest.ts'));

interface Rng {
  next(): number;
  int(min: number, max: number): number;
  chance(p: number): boolean;
  pick<T>(items: readonly T[]): T;
  shuffle<T>(items: readonly T[]): T[];
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
  return {
    next,
    int,
    chance: p => next() < p,
    pick: items => items[Math.floor(next() * items.length)] as never,
    shuffle: items => {
      const out = [...items];
      for (let i = out.length - 1; i > 0; i--) {
        const j = int(0, i);
        [out[i], out[j]] = [out[j] as never, out[i] as never];
      }
      return out;
    },
  };
}

type Rec = Record<string, unknown>;
type Kind = string;

const OPS: string[] = Object.keys(opSpecs.OP_SPECS);
const ACTIONS: string[] = [...opSpecs.ACTION_TYPES];
const CONTENT: string[] = [...opSpecs.CONTENT_OP_TYPES];
const METADATA = ['rationale', 'quote', 'ideaId', 'startedEmpty'];
const PROTOTYPE_NAMES = Object.getOwnPropertyNames(Object.prototype);
const SECTIONS = [...opSpecs.BIBLE_SECTIONS] as string[];
const HOOKS = ['cliffhanger', 'revelation', 'quiet_dread', 'promise', 'turn', 'closure_with_momentum', 'earned_rest'];
const HUB = [...CONTENT.filter(op => op !== 'organise.rule'), ...ACTIONS];

const SCOPES: (string[] | null)[] = [
  null,
  HUB,
  ['premise.update', 'bible_document.upsert'],
  ['entity.upsert', 'entity.remove', 'bible_document.upsert', 'bible_document.remove'],
  ['bible_document.upsert', 'entity.upsert'],
  ['bible_document.upsert', 'bible_document.remove', 'entity.upsert', 'entity.remove'],
  ['bible_document.upsert', 'entity.upsert', 'fact.upsert'],
  [...(opSpecs.CONTENT_OP_TYPES as string[]).filter(op => ['entity.upsert', 'entity.remove', 'fact.upsert', 'fact.remove', 'bible_document.upsert', 'bible_document.remove', 'brief.update'].includes(op))],
  [],
  ['brief.update'],
  ['volume.upsert'],
  ['fact.upsert', 'fact.remove', 'brief.update'],
  ['action.validate', 'action.finalize', 'draft.update'],
];

const WORDS = ['Mira', 'tide', 'ash', 'the bell', 'keeper', 'draft', 'Ünï', 'é', 'é', '日本語', '😀', 'x', 'a b', "o'k", 'q"t', 'back\\slash', 'line\nbreak', 'ﬁ', 'K'];
const BLANKS = ['', ' ', '\t', '\n', '﻿', ' ', '　', ' \n ', ' ', ' '];
const NOT_TRIMMED = ['\u0085', '​', '᠎'];
const KEYS = ['v1', 'vol_3', 'mk', 'lamp_rank_4', 'é', 'é', 'K', 'mira', 'the_tower', '😀', 'Ünï'];
const SPACED_KEYS = [' ', ' k', 'k ', 'a b', '\t', 'k\n', ' ', '﻿', ' ', '　', 'a b', ''];
const SLUGS = [...manifest.BIBLE_MANIFEST.map((chapter: { slug: string }) => chapter.slug), 'supers-and-rifts', 'reader-promise', 'anything', 'timeline'];

const text = (rng: Rng): string => rng.pick(WORDS) + (rng.chance(0.3) ? ' ' + rng.pick(WORDS) : '');
const key = (rng: Rng): string => rng.pick(KEYS);
const list = (rng: Rng, make: (rng: Rng) => unknown, min = 1, max = 3): unknown[] => Array.from({ length: rng.int(min, max) }, () => make(rng));

function anchor(rng: Rng): Rec {
  const start = rng.int(0, 40);
  return {
    draftId: String(rng.int(1, 9)),
    revision: rng.int(0, 4),
    saveSeq: rng.int(0, 4),
    start,
    end: start + rng.int(1, 30),
    passageHash: 'h' + rng.int(1, 99),
    paragraph: rng.int(1, 5),
    contextBefore: text(rng),
    contextAfter: text(rng),
  };
}

function unlock(rng: Rng): Rec {
  const term = (): Rec => {
    const roll = rng.int(0, 3);
    if (roll === 0) return { milestone: key(rng) };
    if (roll === 1) return { volume: key(rng) };
    if (roll === 2) return { chapter: rng.int(1, 30) };
    return { ending: true };
  };
  return { all: list(rng, term) };
}

function knowledgeContract(rng: Rng): Rec {
  const contract: Rec = { pov: list(rng, key) };
  if (rng.chance(0.6)) contract['learns'] = list(rng, () => ({ entityKey: key(rng), factKey: key(rng) }), 0, 2);
  return contract;
}

function endingContract(rng: Rng): Rec {
  const contract: Rec = { hookType: rng.pick(HOOKS), emotionalBeat: text(rng), openQuestion: text(rng), handoffState: text(rng) };
  if (rng.chance(0.5)) contract['mustNotResolve'] = list(rng, text, 0, 2);
  return contract;
}

function scenes(rng: Rng): Rec[] {
  return list(rng, () => {
    const scene: Rec = { summary: text(rng) };
    if (rng.chance(0.5)) scene['pov'] = rng.chance(0.2) ? null : key(rng);
    if (rng.chance(0.3)) scene['goal'] = text(rng);
    if (rng.chance(0.3)) scene['beats'] = list(rng, text, 0, 2);
    if (rng.chance(0.3)) scene['estimatedWords'] = rng.int(1, 3000);
    return scene;
  }) as Rec[];
}

function fieldValue(op: string, field: string, kind: Kind, rng: Rng): unknown {
  switch (field) {
    case 'section':
      return rng.pick(SECTIONS);
    case 'slug':
      return rng.pick(SLUGS);
    case 'type':
      return rng.pick(opSpecs.ENTITY_TYPES);
    case 'writeMode':
      return rng.pick(opSpecs.BRIEF_WRITE_MODES);
    case 'contentMode':
      return rng.chance(0.2) ? null : rng.pick(opSpecs.CONTENT_MODES);
    case 'scope':
      return rng.pick(opSpecs.VALIDATION_SCOPES);
    case 'kind':
      return op.startsWith('promise.') ? rng.pick(opSpecs.PROMISE_KINDS) : rng.pick(opSpecs.MILESTONE_KINDS);
    case 'status':
      return op === 'promise.update' ? rng.pick(opSpecs.PROMISE_STATUSES) : text(rng);
    case 'milestoneKey':
    case 'key':
    case 'volumeKey':
    case 'entityKey':
    case 'factKey':
      return key(rng);
    case 'subjectEntityKey':
    case 'payoffMilestoneKey':
    case 'payoffVolumeKey':
      return rng.chance(0.25) ? null : key(rng);
    case 'claimedMilestones':
      return rng.chance(0.2) ? null : list(rng, key);
    case 'allowedClues':
      return rng.chance(0.2) ? null : list(rng, text);
    case 'revealChapter':
      return rng.chance(0.2) ? null : rng.int(1, 60);
    case 'payoffWindow':
      return rng.chance(0.25) ? null : rng.int(1, 60);
    case 'contextIndex':
      return rng.int(1, 6);
    case 'anchor':
      return anchor(rng);
    case 'unlock':
      return rng.chance(0.15) ? null : unlock(rng);
    case 'knowledgeContract':
      return rng.chance(0.15) ? null : knowledgeContract(rng);
    case 'endingContract':
      return endingContract(rng);
    case 'scenes':
      return rng.chance(0.15) ? null : scenes(rng);
    case 'frontmatter':
      return { status: text(rng), tags: ['a'] };
    case 'chapter':
    case 'upTo':
    case 'openedChapter':
    case 'lastAdvancedChapter':
    case 'revision':
    case 'saveSeq':
      return rng.int(1, 40);
    case 'ordinal':
      return rng.int(0, 9);
    default:
  }
  if (kind === 'string') return text(rng);
  if (kind === 'string|null') return rng.chance(0.2) ? null : text(rng);
  if (kind === 'boolean') return rng.chance(0.5);
  if (kind === 'number') return rng.int(1, 30);
  if (kind === 'string[]') return list(rng, text, 0, 3);
  if (kind === 'string[]|null') return rng.chance(0.2) ? null : list(rng, text, 0, 3);
  if (kind === 'object') return { k: text(rng) };
  return null;
}

function fieldsOf(op: string): { required: [string, Kind][]; optional: [string, Kind][] } {
  const spec = opSpecs.OP_SPECS[op];
  return { required: Object.entries(spec.required) as [string, Kind][], optional: Object.entries(spec.optional) as [string, Kind][] };
}

function fixup(op: string, record: Rec, rng: Rng): Rec {
  if (op === 'draft.update' && record['title'] === undefined && record['body'] === undefined && record['summary'] === undefined) record['body'] = text(rng);
  if (op === 'promise.set_payoff' && record['someday'] === true) for (const field of ['payoffMilestoneKey', 'payoffVolumeKey', 'payoffWindow']) delete record[field];
  if (op === 'draft.rewrite_passage' && typeof record['passage'] === 'string' && record['passage'].trim() === '') record['passage'] = 'x';
  return record;
}

function validOp(op: string, rng: Rng, mode: 'minimal' | 'full' | 'random', only?: string, without?: string): Rec {
  const { required, optional } = fieldsOf(op);
  const record: Rec = { op };
  for (const [field, kind] of required) record[field] = fieldValue(op, field, kind, rng);
  for (const [field, kind] of optional) {
    if (without === field) continue;
    const present = only !== undefined ? only === field : mode === 'full' || (mode === 'random' && rng.chance(0.35));
    if (present) record[field] = fieldValue(op, field, kind, rng);
  }
  return fixup(op, record, rng);
}

const TYPES: [string, unknown][] = [
  ['null', null],
  ['bool', true],
  ['int', 7],
  ['float', 1.5],
  ['string', 'x'],
  ['array', ['a', 1]],
  ['object', { a: 1 }],
];
const EXTRA_WRONG: unknown[] = [[], {}, [null], [{}], [[]], '', ' ', false, 0, -1];

const seen = new Set<string>();
interface Case {
  text: string;
  scope: number;
  flag: number;
  errors: string[] | null;
  repaired: string | 0;
}
const cases: Case[] = [];

function add(value: unknown, scope = 0, flag = 0, raw?: string): void {
  const source = raw ?? JSON.stringify(value);
  const id = `${scope}|${flag}|${source}`;
  if (seen.has(id)) return;
  seen.add(id);
  const parsed = JSON.parse(source);
  const before = JSON.stringify(parsed);
  let errors: string[] | null;
  try {
    errors = flag === 2 ? validation.validatePluginChangeSet(parsed) : validation.validateChangeSet(parsed, SCOPES[scope] ?? undefined, flag === 1 ? { entityMaterialization: false } : undefined);
  } catch {
    errors = null;
  }
  const after = JSON.stringify(parsed);
  cases.push({ text: source, scope, flag, errors, repaired: errors !== null && after !== before ? after : 0 });
}

const one = (record: unknown, scope = 0, flag = 0): void => add([record], scope, flag);

// valid: every op, minimal / full / each optional alone / each optional absent
OPS.forEach((op, index) => {
  const rng = createRng(100 + index);
  one(validOp(op, rng, 'minimal'));
  one(validOp(op, rng, 'full'));
  one(validOp(op, rng, 'full'), 1);
  for (const [field] of fieldsOf(op).optional) {
    one(validOp(op, rng, 'minimal', field));
    one(validOp(op, rng, 'full', undefined, field));
  }
  for (let repeat = 0; repeat < 2; repeat++) one(validOp(op, rng, 'random'), rng.int(0, 1) * 1);
});

// every field with every JSON type, missing required fields, blanks, numbers, enums, unknown fields
OPS.forEach((op, index) => {
  const rng = createRng(500 + index);
  const { required, optional } = fieldsOf(op);
  for (const [field, kind] of [...required, ...optional]) {
    if (METADATA.includes(field) && index > 3 && op !== 'brief.update') continue;
    const base = (): Rec => validOp(op, rng, 'minimal');
    for (const [, wrong] of rng.shuffle(TYPES).slice(0, 3)) one({ ...base(), [field]: wrong });
    one({ ...base(), [field]: null });
        if (kind.startsWith('string')) for (const blank of ['', ' ', '\t', '  ']) one({ ...base(), [field]: kind.includes('[]') ? [blank] : blank });
    if (kind.startsWith('number')) for (const odd of rng.shuffle([0, -1, 1.5, 1e21]).slice(0, 2)) one({ ...base(), [field]: odd });
    if (kind.includes('[]')) one({ ...base(), [field]: [1, 'a'] });
  }
  for (const [field] of required) {
    const record = validOp(op, rng, 'full');
    delete record[field];
    one(record);
  }
  for (const extra of ['extra', 'title', 'state', PROTOTYPE_NAMES[rng.int(0, 11)] as string]) one({ ...validOp(op, rng, 'minimal'), [extra]: 1 });
  one({ ...validOp(op, rng, 'minimal'), extra: 1, other: 2, third: 3 });
  one({ ...validOp(op, rng, 'full'), ...Object.fromEntries(METADATA.map(field => [field, 3])) });
  for (const field of METADATA) one({ ...validOp(op, rng, 'minimal'), [field]: field === 'startedEmpty' ? true : 'm' });
});

// enums and rule checks
const ENUM_BAD = ['nope', '', 'Standard', ' standard', 'standard ', 'STANDARD', 'é', 'character ', 'Thread', 'paid-off', 'happy_end'];
const enumCases: [string, string, string[]][] = [
  ['bible_document.upsert', 'section', SECTIONS],
  ['bible_document.remove', 'section', SECTIONS],
  ['entity.upsert', 'type', opSpecs.ENTITY_TYPES],
  ['brief.update', 'writeMode', opSpecs.BRIEF_WRITE_MODES],
  ['brief.update', 'contentMode', opSpecs.CONTENT_MODES],
  ['milestone.upsert', 'kind', opSpecs.MILESTONE_KINDS],
  ['promise.create', 'kind', opSpecs.PROMISE_KINDS],
  ['promise.update', 'kind', opSpecs.PROMISE_KINDS],
  ['promise.set_payoff', 'kind', opSpecs.PROMISE_KINDS],
  ['promise.drop', 'kind', opSpecs.PROMISE_KINDS],
  ['promise.update', 'status', opSpecs.PROMISE_STATUSES],
  ['action.validate', 'scope', opSpecs.VALIDATION_SCOPES],
];
enumCases.forEach(([op, field, good], index) => {
  const rng = createRng(900 + index);
  for (const bad of ENUM_BAD) one({ ...validOp(op, rng, 'minimal'), [field]: bad });
  for (const ok of good) one({ ...validOp(op, rng, 'minimal'), [field]: ok });
});

const mutateBrief = (change: Rec, seed: number): void => one({ ...validOp('brief.update', createRng(seed), 'minimal'), ...change });
for (const hookType of [...HOOKS, 'happy_end', '', null, 3, 'Cliffhanger']) mutateBrief({ endingContract: { hookType, emotionalBeat: 'a', openQuestion: 'b', handoffState: 'c' } }, 1);
for (const contract of [
  {},
  [],
  'x',
  null,
  { hookType: 'turn' },
  { hookType: 'turn', emotionalBeat: '', openQuestion: 3, handoffState: null },
  { hookType: 'turn', emotionalBeat: 'a', openQuestion: 'b', handoffState: 'c', mustNotResolve: 'x' },
  { hookType: 'turn', emotionalBeat: 'a', openQuestion: 'b', handoffState: 'c', mustNotResolve: null },
  { hookType: 'turn', emotionalBeat: 'a', openQuestion: 'b', handoffState: 'c', mustNotResolve: [1] },
  { hookType: 'turn', emotionalBeat: 'a', openQuestion: 'b', handoffState: 'c', extra: 1 },
  { hookType: 'bad', emotionalBeat: 'a', openQuestion: 'b', handoffState: 'c', extra: 1, mustNotResolve: {} },
])
  mutateBrief({ endingContract: contract }, 2);
for (const contract of [
  'heir',
  [],
  3,
  {},
  { pov: [] },
  { pov: [''] },
  { pov: 'a' },
  { pov: ['a', 1] },
  { pov: ['a'], learns: null },
  { pov: ['a'], learns: {} },
  { pov: ['a'], learns: 'x' },
  { pov: ['a'], learns: [] },
  { pov: ['a'], learns: [1] },
  { pov: ['a'], learns: [[]] },
  { pov: ['a'], learns: [null] },
  { pov: ['a'], learns: [{}] },
  { pov: ['a'], learns: [{ entityKey: '', factKey: 'f' }] },
  { pov: ['a'], learns: [{ entityKey: 'e', factKey: 3 }] },
  { pov: ['a'], learns: [{ entityKey: 'e', factKey: 'f', x: 1, y: 2 }] },
  { pov: ['a'], learns: [{ entityKey: 'e', factKey: 'f' }, { entityKey: 'e' }, 5] },
  { pov: ['a'], reveals: [], other: 1 },
  { learns: [{ entityKey: 'e', factKey: 'f', z: 1 }], zed: 1 },
  { pov: ['a', 'b'], learns: [{ entityKey: 'e', factKey: 'f' }] },
])
  mutateBrief({ knowledgeContract: contract }, 3);
for (const value of [[], [{}], [{ summary: 'a' }], [{ summary: ' ' }], [{ summary: 'a', mood: 1 }], 'x', {}, [3], [null], [[]], [{ summary: 'a', pov: '' }], [{ summary: 'a', beats: 'x', goal: 3, estimatedWords: 0 }], null])
  mutateBrief({ scenes: value }, 4);
for (const value of [[], [''], [' '], ['a', ''], ['a', 3], [null], 'x', null, {}, ['a b'], ['\t']]) {
  mutateBrief({ claimedMilestones: value }, 5);
  one({ ...validOp('fact.upsert', createRng(6), 'minimal'), allowedClues: value });
}
for (const value of [{}, { all: [] }, { all: [{ chapter: 0 }] }, { all: [{ milestone: 'a', chapter: 1 }] }, { any: [] }, [], 'x', 3, { all: [{ ending: false }] }, { all: [3, { volume: ' ' }] }, null])
  one({ ...validOp('fact.upsert', createRng(7), 'minimal'), unlock: value });
for (const value of [0, 1, -1, 1.5, 1e21, null, '3', 'soon', true, [], {}, 2.0, 100]) one({ ...validOp('fact.upsert', createRng(8), 'minimal'), revealChapter: value });
for (const value of [0, 1, -1, 1.5, 30, null, 'x']) one({ op: 'action.generate_chapter', chapter: value });
for (const field of ['title', 'body', 'summary']) {
  one({ op: 'draft.update', chapter: 2, [field]: '' });
  one({ op: 'draft.update', chapter: 2, [field]: null });
}
one({ op: 'draft.update', chapter: 2 });
for (const op of ['milestone.upsert', 'milestone.remove']) for (const spaced of [...SPACED_KEYS, 'ok', 'a_b', 'é', 'K', '😀']) one({ op, milestoneKey: spaced });
for (const op of ['promise.create', 'promise.update', 'promise.set_payoff', 'promise.drop'])
  for (const spaced of [...SPACED_KEYS, 'ok']) one({ ...validOp(op, createRng(9), 'minimal'), key: spaced });
for (const label of ['', ' ', '\t\n', 'ok', '​', '\u0085', '᠎', ' ']) {
  one({ op: 'milestone.upsert', milestoneKey: 'k', label });
  one({ op: 'promise.create', kind: 'thread', key: 'k', label });
}
for (const combo of [
  { someday: true },
  { someday: true, payoffMilestoneKey: null },
  { someday: true, payoffVolumeKey: 'v' },
  { someday: true, payoffWindow: 3 },
  { someday: true, payoffWindow: null, payoffVolumeKey: null, payoffMilestoneKey: null },
  { someday: false, payoffWindow: 3 },
  { someday: 'true', payoffWindow: 3 },
  { dormant: true },
  { payoffWindow: 0 },
  { payoffWindow: 1.5 },
])
  one({ op: 'promise.set_payoff', kind: 'thread', key: 'k', ...combo });
const baseRewrite = (): Rec => ({ op: 'draft.rewrite_passage', chapter: 3, passage: 'Corin flexed.', replacement: 'Corin rolled.' });
const goodAnchor = anchor(createRng(11));
for (const change of [
  { passage: '' },
  { passage: ' \n' },
  { passage: '​' },
  { contextIndex: 0 },
  { contextIndex: -2 },
  { contextIndex: 1.5 },
  { contextIndex: 0.5 },
  { contextIndex: 3 },
  { anchor: goodAnchor },
  { anchor: null },
  { anchor: [] },
  { anchor: 'x' },
  { anchor: {} },
  { anchor: { ...goodAnchor, end: goodAnchor.start } },
  { anchor: { ...goodAnchor, end: 0, start: 5 } },
  { anchor: { ...goodAnchor, extra: 1 } },
  { anchor: { ...goodAnchor, start: -1 } },
  { anchor: { ...goodAnchor, start: 1.5 } },
  { anchor: { ...goodAnchor, paragraph: '2' } },
  { anchor: { ...goodAnchor, draftId: 3 } },
  { anchor: { ...goodAnchor, revision: null } },
  { anchor: { ...goodAnchor, contextAfter: undefined } },
  { anchor: { ...goodAnchor, passageHash: undefined, saveSeq: undefined } },
  { passage: ' ', contextIndex: 0, anchor: {} },
  { label: 3, contextIndex: 'x' },
])
  one({ ...baseRewrite(), ...change });

// unknown ops, non-arrays, non-object elements
const WEIRD_OPS: unknown[] = [
  '',
  'x',
  'Premise.update',
  'premise.update ',
  ' premise.update',
  'action.',
  'bible_document',
  'bible_documentX',
  'bible_document.',
  'arc.upsert',
  'arc.remove',
  'chapter.delete',
  'action.plan_volumes',
  'action.plan_arcs',
  'action.outline_arc',
  'action.approve_volume_plan',
  'action.approve_arcs',
  'action.generate_chapters',
  'brief.create',
  'fact.update',
  null,
  3,
  1.5,
  1e21,
  true,
  false,
  [],
  ['premise.update'],
  [1, [2, null]],
  {},
  { a: 1 },
  [[['a']], null],
  ...PROTOTYPE_NAMES,
  'volume.upsert\u0000',
];
for (const op of WEIRD_OPS) for (const scope of [0, 1, 8, 9]) add([{ op }], scope);
for (const op of ['bible_documentX', 'bible_document.', 'bible_document']) add([{ op, section: 'doc:world/x', slug: 'y' }]);
add([{ volume: 'v' }]);
add([{ op: undefined, a: 1 }]);
add([{}]);
add([{}], 8);
for (const value of [null, undefined, 3, 'x', true, {}, { op: 'volume.remove', volumeKey: 'v' }, [], [[]], [null], [3], ['x'], [[{ op: 'volume.remove', volumeKey: 'v' }]], [true, { op: 'volume.remove', volumeKey: 'v' }, null], [{ op: 'volume.remove', volumeKey: 'v' }, 4]])
  for (const scope of [0, 1, 8]) add(value ?? null, scope, 0, value === undefined ? 'null' : undefined);
for (const flag of [0, 1, 2]) add([], 0, flag), add({}, 0, flag), add(null, 0, flag), add([null], 0, flag);

// bible document references and the repair
const SECTION_FORMS = [
  'project', 'doc:project', 'project/premise', 'doc:project/premise', 'world/factions', 'doc:world/x/y', 'poetry/haiku', 'project/', '/premise', 'doc:', 'doc:doc:project', 'Project/premise',
  'project//a', 'story_state/a/b', 'ai/prompt', 'lore', 'doc:lore/a', 'plot/ending-vision', ' project', 'world/',
];
const SLUG_FORMS: unknown[] = ['premise', 'doc:premise', 'project/premise', 'world/factions', '', 'doc:project/premise', 'plot/ending-vision', 'x/y', 'project/', 'doc:world/factions', 'ending-vision', 'doc:'];
for (const op of ['bible_document.upsert', 'bible_document.remove']) {
  const body = op === 'bible_document.upsert' ? { body: 'x' } : {};
  const pick = createRng(op.length);
  for (const section of SECTION_FORMS) {
    for (const slug of pick.shuffle(SLUG_FORMS).slice(0, 3)) one({ op, section, slug, ...body }, 0, 1);
    one({ op, section, ...body }, 0, 1);
    one({ op, section, slug: null, ...body }, 0, 1);
    one({ op, section, slug: 5, ...body }, 0, 1);
    one({ op, section, slug: section, ...body }, 0, 1);
    one({ op, slug: section, ...body }, 0, 1);
  }
  for (const nonString of [null, 5, true, [], {}, ['world/a']]) {
    one({ op, section: nonString, slug: 'doc:world/a', ...body }, 0, 1);
    one({ op, section: 'world', slug: nonString, ...body }, 0, 1);
  }
}
add([{ slug: 'a', op: 'bible_document.remove', section: 'world/a' }], 0, 1);
add([{ section: 'world/a', op: 'bible_document.remove' }], 0, 1);
add([{ '1': 'x', op: 'bible_document.remove', slug: 'a/b', section: 'a/b' }], 0, 1);
add([{ op: 'bible_document.remove', section: 'world/a' }, { op: 'bible_document.remove', section: 'poetry/x', slug: 'q' }, { op: 'volume.remove', volumeKey: 'v' }], 0, 1);
add([{ op: 'bible_document.upsert', section: 'power/system-and-limits', slug: '', body: 'prose' }]);
add([{ op: 'bible_document.upsert', section: 'doc:power/system-and-limits', slug: 'doc:power/system-and-limits', body: 'prose' }]);
add([{ op: 'bible_document.upsert', section: 'doc:power/system-and-limits', slug: 'doc:power/system-and-limits', body: 'prose' }, { op: 'entity.upsert', entityKey: 'e', type: 'concept' }]);

// entity materialization
const power = { op: 'bible_document.upsert', section: 'power', slug: 'system-and-limits', body: 'prose' };
for (const chapter of manifest.BIBLE_MANIFEST as { section: string; slug: string }[]) {
  const doc = { op: 'bible_document.upsert', section: chapter.section, slug: chapter.slug, body: 'A body.' };
  add([doc]);
  add([doc], 0, 1);
  for (const type of [opSpecs.ENTITY_TYPES[chapter.slug.length % 6], 'character']) add([doc, { op: 'entity.upsert', entityKey: 'e', type }]);
  add([{ ...doc, body: '  ' }]);
  add([{ ...doc, body: undefined, frontmatter: { a: 1 } }]);
}
for (const body of ['', ' ', 'x', '​', ' ', 7, null]) add([{ ...power, body }]);
add([power, power]);
add([power, { op: 'entity.upsert', entityKey: 'e', type: 'character' }]);
add([power, { op: 'entity.upsert', entityKey: 'e', type: 'power_rule' }], 3);
add([power, { op: 'entity.upsert', entityKey: 'e', type: 'power_rule' }], 8);
add([power, { op: 'entity.remove', entityKey: 'e' }]);
add([power, { op: 'volume.remove', volumeKey: 'v' }, { ...power, slug: 'cast' }]);
add([{ ...power, section: 'project', slug: 'cast' }, { ...power, section: 'world', slug: 'places' }, { ...power, section: 'plot', slug: 'x' }]);
add([{ ...power, unexpected: 1 }]);
add([power], 2);
add([power], 3);
add([power], 4);
add([power], 11);

// random mixed change sets
function mutate(record: Rec, rng: Rng): Rec {
  const op = record['op'] as string;
  const out = { ...record };
  const fields = Object.keys(out).filter(field => field !== 'op');
  const roll = rng.int(0, 9);
  if (roll === 0 && fields.length > 0) delete out[rng.pick(fields)];
  else if (roll <= 2 && fields.length > 0) out[rng.pick(fields)] = rng.pick(TYPES)[1];
  else if (roll === 3) out[rng.pick(['extra', 'title', 'state', 'toString', 'rationale'])] = rng.pick([1, 'x', null]);
  else if (roll === 4) out['op'] = rng.pick(OPS);
  else if (roll === 5 && fields.length > 0) out[rng.pick(fields)] = rng.pick(BLANKS);
  else if (roll === 6 && fields.length > 0) out[rng.pick(fields)] = rng.pick([0, -1, 1.5, 1e21]);
  else if (roll === 7) out['rationale'] = rng.pick([3, null, 'why']);
  else if (roll === 8 && op.startsWith('brief')) out['volumeKey'] = rng.pick(['v1', null, 3]);
  return out;
}

OPS.forEach((op, index) => {
  const rng = createRng(15000 + index);
  for (let repeat = 0; repeat < 3; repeat++) {
    let record = validOp(op, rng, 'full');
    for (let step = rng.int(2, 4); step > 0; step--) record = mutate(record, rng);
    one(record);
  }
});
one({ op: 'milestone.upsert', milestoneKey: 'a b', label: ' ', kind: 'level', state: 'x' });
one({ op: 'promise.set_payoff', kind: 'x', key: 'a b', someday: true, payoffWindow: 1.5, extra: 1 });
one({ op: 'promise.create', kind: 'x', key: ' ', label: ' ' });
one({ op: 'promise.update', kind: 'x', key: ' ', label: 3, status: 'dropped' });
one({ op: 'fact.upsert', factKey: 3, revealChapter: 0, allowedClues: [' '], unlock: { all: [] }, extra: 1 });
one({ op: 'draft.rewrite_passage', chapter: 'x', passage: ' ', contextIndex: 0, anchor: {}, extra: 1 });
one({ op: 'brief.update', chapter: 0, writeMode: 'x', endingContract: {}, knowledgeContract: {}, contentMode: 'x', scenes: [{}], claimedMilestones: [' '], extra: 1 });
one({ op: 'bible_document.upsert', section: 'x', slug: 3, frontmatter: [], extra: 1 });
one({ op: 'entity.upsert', entityKey: 3, type: 'x', extra: 1 });
one({ op: 'action.validate', scope: 'x', chapter: 1.5, extra: 1 });
one({ op: 'action.generate_chapter', chapter: 0, extra: 1 });
one({ op: 'draft.update', chapter: 0, extra: 1 });

const randomSet = (rng: Rng): Rec[] =>
  Array.from({ length: rng.int(1, 4) }, () => {
    const record = validOp(rng.pick(OPS), rng, 'random');
    return rng.chance(0.4) ? mutate(record, rng) : record;
  });

for (let index = 0; index < 150; index++) {
  const rng = createRng(20000 + index);
  const set: unknown[] = randomSet(rng);
  if (rng.chance(0.05)) set.push(rng.pick([null, 3, 'x', []]));
  add(set, rng.chance(0.5) ? 0 : rng.int(1, SCOPES.length - 1), rng.chance(0.2) ? 1 : 0);
}

// plugin change sets
const PLUGIN_STRUCTURE = ['volumeKey', 'contentMode', 'claimedMilestones', 'isEnding'];
for (let index = 0; index < 110; index++) {
  const rng = createRng(30000 + index);
  const set: unknown[] = Array.from({ length: rng.int(1, 3) }, () => {
    const op = rng.pick(['entity.upsert', 'entity.remove', 'fact.upsert', 'fact.remove', 'bible_document.upsert', 'bible_document.remove', 'brief.update', 'brief.update', 'milestone.upsert', 'volume.upsert']);
    const record = validOp(op, rng, 'random');
    if (op === 'brief.update' && rng.chance(0.6)) for (const field of rng.shuffle(PLUGIN_STRUCTURE).slice(0, rng.int(1, 3))) record[field] = fieldValue(op, field, 'string', rng);
    return rng.chance(0.2) ? mutate(record, rng) : record;
  });
  add(set, 0, 2);
}
for (const value of [null, {}, [], [null], [{ op: 'brief.update', chapter: 3, volumeKey: null }], [{ op: 'brief.update', chapter: 3, isEnding: false }], [{ op: 'brief.update', chapter: 3, contentMode: null, claimedMilestones: null }]])
  add(value, 0, 2);
for (const field of PLUGIN_STRUCTURE) add([{ op: 'brief.update', chapter: 3, [field]: 'x' }], 0, 2);
add([{ op: 'volume.upsert', volumeKey: 'v', isEnding: true }, { op: 'brief.update', chapter: 1, isEnding: true }], 0, 2);

const validCount = cases.filter(item => item.errors?.length === 0).length;
console.log(`validation cases ${cases.length}, valid ${validCount}, throwing ${cases.filter(item => item.errors === null).length}, repaired ${cases.filter(item => item.repaired !== 0).length}`);

// parseOptionalChangeSet
const optionalCases: [string | null, number, number, string][] = [];
const optionalInputs: (string | null)[] = [null, 'null', '[]', '{}', '0', '""', 'false', '[null]', '[{"op":"nope"}]', '[{"op":"volume.remove","volumeKey":"v"}]', '[{"op":"volume.remove","volumeKey":"v"},{"op":"brief.remove","chapter":2}]'];
for (const input of [...optionalInputs, ...cases.slice(0, 6).map(item => item.text)]) {
  for (const scope of [0, 9]) {
    const parsed = input === null ? undefined : JSON.parse(input);
    let result: string;
    try {
      result = validation.parseOptionalChangeSet(parsed, SCOPES[scope] ?? undefined).length === 0 ? 'empty' : 'ok';
    } catch (error) {
      result = (error as { errorCode?: string }).errorCode === 'RFN_004' || (error as { code?: string }).code === 'RFN_004' ? 'rejected' : 'throws';
    }
    optionalCases.push([input, scope, 0, result]);
  }
}
const rejection = classes.AppErrorCode.RFN_004.create();

// vocabulary
const vocabDict: string[] = [];
const vocabIndex = new Map<string, number>();
const intern = (line: string): number => {
  let index = vocabIndex.get(line);
  if (index === undefined) {
    index = vocabDict.length;
    vocabDict.push(line);
    vocabIndex.set(line, index);
  }
  return index;
};
const optionForms: (Rec | undefined)[] = [undefined, {}, { quotes: false }, { quotes: true }];
const vocabCases: [string[], number, number[]][] = [];
const actionCases: [string[], number[]][] = [];
const addVocab = (ops: string[], option: number): void => {
  const out = vocabulary.renderOpVocabulary(ops, optionForms[option]) as string;
  vocabCases.push([ops, option, out.split('\n').map(intern)]);
};
const addActions = (actions: string[]): void => {
  actionCases.push([actions, (vocabulary.renderActionVocabulary(actions) as string).split('\n').map(intern)]);
};
for (const op of OPS) for (let option = 0; option < 4; option++) addVocab([op], option);
for (const scope of SCOPES) if (scope !== null) for (let option = 0; option < 4; option++) addVocab(scope, option);
addVocab(HUB, 3);
addVocab(OPS, 3);
addVocab(OPS, 0);
addVocab([...OPS].reverse(), 3);
addVocab(['brief.update', 'brief.update'], 3);
addVocab(['fact.upsert', 'brief.update'], 2);
addVocab(['brief.update', 'fact.upsert', 'volume.upsert'], 0);
for (let index = 0; index < 60; index++) {
  const rng = createRng(40000 + index);
  const subset = rng.shuffle(OPS).slice(0, rng.int(0, 14));
  addVocab(rng.chance(0.5) ? OPS.filter(op => subset.includes(op)) : subset, rng.int(0, 3));
}
for (const action of ACTIONS) addActions([action]);
addActions([]);
addActions(ACTIONS);
addActions([...ACTIONS].reverse());
addActions([ACTIONS[0] as string, ACTIONS[0] as string]);
for (let index = 0; index < 20; index++) {
  const rng = createRng(50000 + index);
  addActions(rng.shuffle(ACTIONS).slice(0, rng.int(1, 8)));
}
console.log(`vocabulary cases ${vocabCases.length}, action cases ${actionCases.length}, dictionary ${vocabDict.length}`);

// specs
const specs = {
  ops: OPS,
  actions: ACTIONS,
  content: CONTENT,
  pluginAllowed: [...validation.PLUGIN_ALLOWED_OPS],
  prototypeNames: PROTOTYPE_NAMES,
  rejection: { code: rejection.code, message: rejection.message },
  lists: {
    sections: SECTIONS,
    entityTypes: opSpecs.ENTITY_TYPES,
    writeModes: opSpecs.BRIEF_WRITE_MODES,
    contentModes: opSpecs.CONTENT_MODES,
    milestoneKinds: opSpecs.MILESTONE_KINDS,
    promiseKinds: opSpecs.PROMISE_KINDS,
    promiseStatuses: opSpecs.PROMISE_STATUSES,
    scopes: opSpecs.VALIDATION_SCOPES,
  },
  perOp: OPS.map(op => {
    const spec = opSpecs.OP_SPECS[op];
    return {
      op,
      required: Object.entries(spec.required),
      optional: Object.entries(spec.optional),
      description: spec.description ?? null,
      declared: opSpecs.declaredOpFields(op),
      isAction: opSpecs.isActionOp(op),
      hidden: optionForms.map(options => opSpecs.modelHiddenFields(op, options ?? {})),
    };
  }),
};

// refs and decision keys
const refCases: [string, string[], string[]][] = [];
for (let index = 0; index < 100; index++) {
  const rng = createRng(60000 + index);
  const pool = rng.chance(0.3) ? ACTIONS : OPS;
  const set: Rec[] = [];
  const target = rng.int(1, 5);
  for (let attempt = 0; set.length < target && attempt < 40; attempt++) {
    const record = validOp(rng.pick(pool), rng, 'random');
    if (rng.chance(0.3) && set.length > 0) {
      const previous = rng.pick(set);
      set.push({ ...previous, ...(rng.chance(0.5) ? { rationale: 'again' } : {}) });
    } else set.push(record);
    if ((validation.validateChangeSet(JSON.parse(JSON.stringify(set)), undefined, { entityMaterialization: false }) as string[]).length > 0) set.pop();
  }
  if (set.length === 0) continue;
  const parsed = JSON.parse(JSON.stringify(set));
  validation.validateChangeSet(parsed, undefined, { entityMaterialization: false });
  refCases.push([JSON.stringify(parsed), refs.changeSetRefs(parsed), refs.actionDecisionKeys(parsed)]);
}
console.log(`ref cases ${refCases.length}`);

const write = (name: string, value: unknown): void => writeFileSync(join(outDir, name), JSON.stringify(value) + '\n');
write('validation.json', { scopes: SCOPES, cases: cases.map(item => [item.text, item.scope, item.flag, item.errors, item.repaired]) });
write('optional.json', { cases: optionalCases });
write('vocabulary.json', { dictionary: vocabDict, options: optionForms.map(form => form ?? null), ops: vocabCases, actions: actionCases });
write('specs.json', specs);
write('refs.json', { cases: refCases });
