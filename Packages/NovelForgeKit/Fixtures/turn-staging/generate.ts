import { plugin } from 'bun';
import { mock } from 'bun:test';
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
const sanitize = await import(join(server, 'common/sanitize-content.ts'));
const paragraphs = await import(join(platformRepo, 'packages/sdk/src/prose-paragraphs.ts'));
const organise = await import(join(platformRepo, 'packages/sdk/src/organise.ts'));

const noop = () => undefined;
const columns = (table: string): unknown => new Proxy({}, { get: (_, column) => `${table}.${String(column)}` });
const schema = new Proxy({}, { get: (_, table) => columns(String(table)) });

plugin({
  name: 'turn-staging-fixture-stubs',
  setup(build) {
    build.module('@server/classes', () => ({ exports: { AppErrorCode: classes.AppErrorCode }, loader: 'object' }));
    build.module('@server/common', () => ({
      exports: {
        normalizeLineEndings: sanitize.normalizeLineEndings,
        validateBriefScenes: briefScenes.validateBriefScenes,
        validateUnlockCondition: unlockCondition.validateUnlockCondition,
        deriveBibleDocTitle: docTitle.deriveBibleDocTitle,
        computeContentHash: noop,
      },
      loader: 'object',
    }));
    build.module('@server/database', () => ({ exports: { schema }, loader: 'object' }));
    build.module('@server/database/schemas', () => ({ exports: {}, loader: 'object' }));
    build.module('@shadow-library/sdk', () => ({ exports: { paragraphAt: paragraphs.paragraphAt, TIMELINE_BAND_LABELS: organise.TIMELINE_BAND_LABELS }, loader: 'object' }));
    build.module('drizzle-orm', () => ({ exports: { and: noop, asc: noop, eq: noop, inArray: noop, isNotNull: noop, isNull: noop, sql: noop }, loader: 'object' }));
  },
});

type Rec = Record<string, unknown>;

const artifactStatePath = join(server, 'modules/refinement/artifact-state.ts');
const artifactState = await import(artifactStatePath);
let standing = new Map<string, Rec>();
mock.module(artifactStatePath, () => ({
  ...artifactState,
  loadCurrentRecords: async (_db: unknown, _project: unknown, refs: string[]) => new Map(refs.filter(ref => standing.has(ref)).map(ref => [ref, standing.get(ref)])),
}));

const turn = await import(join(server, 'modules/refinement/turn-proposals.ts'));
const rewrite = await import(join(server, 'modules/refinement/passage-rewrite.ts'));
const changeSet = await import(join(server, 'modules/refinement/change-set/index.ts'));
const ideaId = await import(join(server, 'modules/refinement/idea-id.ts'));
const plannerOnly = await import(join(server, 'modules/refinement/planner-only-guard.ts'));
const anchorModule = await import(join(server, 'modules/generation/passage-anchor.ts'));

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

const PLANNER = plannerOnly.PLANNER_ONLY_WARNING as string;
const valid = (ops: Rec[]): boolean => changeSet.validateChangeSet(ops, undefined, { entityMaterialization: false }).length === 0;

// turnHold
const holds = [[], [PLANNER], [PLANNER, PLANNER], ['echo'], ['echo', PLANNER], [PLANNER, 'echo'], [''], [` ${PLANNER}`], [PLANNER.toUpperCase()]].map(warnings => ({
  warnings,
  expected: turn.turnHold(warnings),
}));

// splitTurnChangeSet
const MESSAGES = [
  'Mira is a thief who works the Saltgate docks.',
  'Mira is a thief who works the Saltgate docks. Maybe Kael is her brother?',
  'The tower falls at dawn and Mara keeps the lantern burning.\r\nThe harbour guild smuggles salt through the marsh.',
  'Ｍｉｒａ steals 😀 lanterns; café owners hate her.',
];
const QUOTES = [
  'Mira is a thief who works the Saltgate docks',
  'Mara keeps the lantern burning',
  'The harbour guild smuggles salt through the marsh',
  'Maybe Kael is her brother',
  'café owners hate her',
  'words the author never wrote',
  '',
];
const ENTITY_KEYS = ['mira', 'kael', 'mara', 'guild'];
const TEXTS = ['Mira is a thief', 'Kael the smith.', 'keeps the lantern burning', 'smuggles salt', 'An older premise.', 'A thief works the Saltgate docks.', '😀 café', ''];

function splitOp(rng: Rng): Rec {
  const text = () => rng.pick(TEXTS);
  return rng.pick<() => Rec>([
    () => ({ op: 'premise.update', premise: text() }),
    () => ({ op: 'entity.upsert', entityKey: rng.pick(ENTITY_KEYS), type: rng.pick(['character', 'faction', 'location']), ...(rng.chance(0.6) ? { name: 'Mira' } : {}), ...(rng.chance(0.5) ? { status: text() } : {}), ...(rng.chance(0.4) ? { body: text() } : {}) }),
    () => ({ op: 'fact.upsert', factKey: rng.pick(['salt-oath', 'heir']), body: text() || 'An oath.', ...(rng.chance(0.4) ? { subjects: [rng.pick(ENTITY_KEYS)] } : {}) }),
    () => ({ op: 'milestone.upsert', milestoneKey: rng.pick(['heist', 'rise']), label: text() || 'The heist', ...(rng.chance(0.4) ? { subjectEntityKey: rng.pick(ENTITY_KEYS) } : {}) }),
    () => ({ op: 'promise.create', kind: 'thread', key: rng.pick(['ledger', 'oath']), label: 'Who took the ledger' }),
    () => ({ op: 'promise.set_payoff', kind: 'thread', key: 'ledger', ...(rng.chance(0.5) ? { someday: true } : { payoffMilestoneKey: rng.pick(['heist', 'rise']) }) }),
    () => ({ op: 'bible_document.upsert', section: rng.pick(['world', 'project']), slug: rng.pick(['factions-and-locations', 'cast', 'harbour']), body: text() || 'Guild' }),
    () => ({ op: 'brief.update', chapter: rng.int(2, 4), title: text() || 'Title', ...(rng.chance(0.4) ? { pov: rng.pick(ENTITY_KEYS) } : {}) }),
    () => ({ op: 'volume.upsert', volumeKey: 'v1', title: text() || 'Winter' }),
    () => ({ op: 'entity.remove', entityKey: rng.pick(ENTITY_KEYS) }),
    () => ({ op: 'action.plan_chapter', chapter: rng.int(2, 4) }),
    () => ({ op: 'action.organise_notes' }),
  ])();
}

function standingRecords(rng: Rng, ops: Rec[]): [string, Rec][] {
  const refs: string[] = changeSet.changeSetRefs(ops);
  const records: [string, Rec][] = [];
  for (const ref of refs) {
    if (!rng.chance(0.45)) continue;
    if (ref === 'premise') records.push([ref, { premise: rng.pick(['', null, 'An older premise.']), brief: null, themes: null, instructions: null }]);
    else if (ref.startsWith('entity:')) records.push([ref, { type: 'character', name: 'Mira', status: rng.pick([null, 'thief']), motivation: null, notes: null, body: rng.pick([null, 'Kael the smith.']) }]);
    else if (ref.startsWith('milestone:')) records.push([ref, { label: rng.pick(['The heist', 'Mira robs the tide-queen’s vault beneath the drowned court']), subjectEntityKey: null, kind: 'event' }]);
    else if (ref.startsWith('promise:')) records.push([ref, { label: 'Who took the ledger', status: 'open', payoffMilestoneKey: 'heist', payoffVolumeKey: null, payoffWindow: null, dormant: false }]);
    else records.push([ref, rng.pick([{}, { body: 'Guild' }, { title: 'Winter' }])]);
  }
  return records;
}

const encodeDisposition = (d: { side: string; source?: string; reason?: string; rule?: string }): string =>
  d.side === 'direct' ? `d:${d.source}` : d.rule ? `c:${d.reason}:${d.rule}` : `c:${d.reason}`;

const splits: unknown[] = [];

async function recordSplit(ops: Rec[], message: string, mode: string, justDiscussing: boolean, warnings: string[], current: [string, Rec][], rejected: string[] | 'fail' | null) {
  if (!valid(ops)) throw new Error(`invalid split scenario ${JSON.stringify(ops)}`);
  const parsed = JSON.parse(JSON.stringify(ops)) as Rec[];
  standing = new Map(current);
  const asked: string[][] = [];
  const rejectedIdeas =
    rejected === null
      ? undefined
      : async (ids: string[]) => {
          asked.push(ids);
          if (rejected === 'fail') throw new Error('connection reset');
          return new Set(ids.filter(id => rejected.includes(id)));
        };
  const split = await turn.splitTurnChangeSet({} as never, 7n, parsed, { authorMessage: message, mode, justDiscussing, warnings, rejectedIdeas });
  splits.push({
    ops,
    message,
    mode,
    justDiscussing,
    warnings,
    current: current.filter(([ref]) => changeSet.changeSetRefs(parsed).includes(ref)),
    rejected,
    expected: {
      asked,
      kept: split.ops.map((op: unknown) => parsed.indexOf(op as Rec)),
      dispositions: split.dispositions.map(encodeDisposition),
      sources: split.sources,
      held: split.held,
      direct: split.direct.map((op: unknown) => parsed.indexOf(op as Rec)),
      droppedIdeas: split.droppedIdeas,
    },
  });
}

// turn-proposals.spec.ts:238-433
const MESSAGE = MESSAGES[0] as string;
const QUOTE = QUOTES[0] as string;
const specOps: Rec[] = [
  { op: 'premise.update', premise: 'A thief works the Saltgate docks.', quote: QUOTE },
  { op: 'entity.upsert', entityKey: 'mira', type: 'character', status: 'thief', quote: QUOTE },
  { op: 'entity.upsert', entityKey: 'kael', type: 'character', name: 'Kael', body: 'Kael the smith.' },
];
const mira: [string, Rec] = ['entity:mira', { type: 'character', name: 'Mira', status: null, motivation: null, notes: null, body: null }];
const premise = (value: string): [string, Rec] => ['premise', { premise: value, brief: null, themes: null, instructions: null }];
const heistOp: Rec = { op: 'milestone.upsert', milestoneKey: 'heist', label: 'The heist' };
const kael = specOps[2] as Rec;
const kaelId = ideaId.ideaIdOf(kael) as string;
await recordSplit(specOps, MESSAGE, 'auto', false, [], [premise(''), mira], null);
await recordSplit(specOps, MESSAGE, 'auto', false, [], [premise('An older premise.'), mira], null);
await recordSplit(specOps, MESSAGE, 'auto', false, ['echo'], [premise(''), mira], null);
await recordSplit(specOps, MESSAGE, 'auto', true, [], [premise(''), mira], null);
await recordSplit([heistOp, ...specOps], MESSAGE, 'auto', false, [PLANNER], [premise(''), mira], null);
await recordSplit([heistOp, kael], MESSAGE, 'auto', false, [PLANNER], [premise(''), mira], [kaelId]);
await recordSplit([kael], MESSAGE, 'auto', false, ['echo'], [premise(''), mira], null);
await recordSplit([kael], MESSAGE, 'manual', false, ['echo'], [premise(''), mira], null);
await recordSplit(specOps, MESSAGE, 'auto', false, [], [premise(''), mira], [kaelId]);
await recordSplit([kael], MESSAGE, 'auto', false, ['echo'], [premise(''), mira], [kaelId]);
await recordSplit(specOps, MESSAGE, 'auto', false, ['echo'], [premise(''), mira], [kaelId]);
await recordSplit([kael, { op: 'fact.upsert', factKey: 'salt-oath', body: 'Every dock captain swore a salt oath.' }], MESSAGE, 'auto', false, ['echo'], [premise(''), mira], [kaelId]);
await recordSplit(
  [{ op: 'promise.set_payoff', kind: 'thread', key: 'ledger', someday: true }, { op: 'milestone.upsert', milestoneKey: 'heist', label: 'Kael betrays the smiths' }],
  MESSAGE, 'auto', false, [],
  [
    ['promise:thread:ledger', { label: 'Who took the ledger', status: 'open', payoffMilestoneKey: 'heist', payoffVolumeKey: null, payoffWindow: null, dormant: false }],
    ['milestone:heist', { label: 'Mira robs the tide-queen’s vault beneath the drowned court', subjectEntityKey: null, kind: 'event' }],
  ],
  null,
);
await recordSplit(specOps, MESSAGE, 'auto', false, [], [premise(''), mira], 'fail');
await recordSplit(specOps, MESSAGE, 'auto', true, [], [premise(''), mira], specOps.map(op => ideaId.ideaIdOf(op) as string));

const splitRng = createRng(0x7ec5);
for (let index = 0; index < 150; index++) {
  const ops: Rec[] = [];
  const target = splitRng.int(1, 5);
  for (let attempt = 0; attempt < target * 4 && ops.length < target; attempt++) {
    const op = splitOp(splitRng);
    if (splitRng.chance(0.55)) op['quote'] = splitRng.pick(QUOTES);
    ops.push(op);
    if (!valid(ops)) ops.pop();
  }
  if (ops.length === 0) continue;
  const parsed = JSON.parse(JSON.stringify(ops)) as Rec[];
  const ids = parsed.map(op => ideaId.ideaIdOf(op) as string);
  const rejected = splitRng.pick<string[] | 'fail' | null>([null, 'fail', ids, ids.slice(0, 1), ids.filter(() => splitRng.chance(0.5)), []]);
  const warnings = splitRng.pick([[], [], [], ['echo'], [PLANNER], [PLANNER, 'echo']]);
  await recordSplit(ops, splitRng.pick(MESSAGES), splitRng.chance(0.85) ? 'auto' : 'manual', splitRng.chance(0.1), warnings, standingRecords(splitRng, parsed), rejected);
}

// stageTurnChangeSet over a scripted port (turn-proposals.spec.ts:26-74), linking always succeeding: the native turn has no separate link step
type Role = 'direct' | 'cards' | 'all';
interface Script {
  stageFails: Role[];
  directWarns: boolean;
  applyFails: 'none' | 'app' | 'internal';
}

const POOL: Rec[] = [
  { op: 'entity.upsert', entityKey: 'mira', type: 'character', name: 'Mira', quote: 'Mira is a thief' },
  { op: 'entity.upsert', entityKey: 'aldo', type: 'character', name: 'Aldo' },
  { op: 'milestone.upsert', milestoneKey: 'heist', label: 'The heist' },
  { op: 'premise.update', premise: 'A thief.' },
  { op: 'action.plan_chapter', chapter: 3 },
];
const stagings: unknown[] = [];
const pooled = (ops: Rec[]): number[] => ops.map(op => POOL.indexOf(op));
const WARNINGS = ['echo', PLANNER];
const coded = (warnings: string[]): number[] => warnings.map(warning => WARNINGS.indexOf(warning));

async function recordStaging(direct: Rec[], cards: Rec[], held: string, sources: string[], warnings: string[], script: Script) {
  const ops = [...direct, ...cards];
  const split = {
    ops,
    direct,
    cards,
    sources,
    held,
    dispositions: ops.map((_, index) => (index < direct.length ? { index, side: 'direct', source: sources[index] ?? 'quoted' } : { index, side: 'card', reason: 'no_quote' })),
  };
  const roleOf = (staged: Rec[]): Role => (staged === split.direct ? 'direct' : staged === split.cards ? 'cards' : 'all');
  const staged: { ops: Rec[]; warnings: string[]; entityMaterialization: boolean; id: bigint }[] = [];
  const applied: { id: bigint; sources: readonly string[] }[] = [];
  const port = {
    stage: async (changeSet: Rec[], stageWarnings: string[], options: { entityMaterialization: boolean }) => {
      if (script.stageFails.includes(roleOf(changeSet))) throw new Error('op not allowed');
      const id = BigInt(staged.length + 1);
      staged.push({ ops: changeSet, warnings: stageWarnings, entityMaterialization: options.entityMaterialization, id });
      const own = script.directWarns && roleOf(changeSet) === 'direct' ? ['undates a fact'] : [];
      return { id, changeSet, status: 'pending', warnings: own.length > 0 ? own : null };
    },
    apply: async (id: bigint, opSources: readonly string[]) => {
      applied.push({ id, sources: opSources });
      if (script.applyFails === 'app') throw classes.AppErrorCode.RFN_003.create();
      if (script.applyFails === 'internal') throw new Error('connection reset by peer at 10.0.0.4');
      const changeSet = staged.find(entry => entry.id === id)?.ops ?? [];
      return { proposal: { id, status: 'applied' }, applied: [], staleMarked: [], opResults: changeSet.map((_, index) => ({ index, status: 'applied' })) };
    },
    linkApplied: async () => undefined,
    discard: async () => undefined,
  };
  let expected: Rec;
  try {
    const result = await turn.stageTurnChangeSet(port, split, warnings);
    const appliedEntry = result.appliedProposal ? staged.find(entry => entry.id === result.appliedProposal.id) : undefined;
    const card = result.cardProposal ? staged.find(entry => entry.id === result.cardProposal.id) : undefined;
    const directStage = direct.length > 0 ? staged.find(entry => entry.ops === split.direct) : undefined;
    expected = {
      threw: false,
      applied: appliedEntry ? { ops: pooled(appliedEntry.ops), sources: applied[0]?.sources ?? [] } : null,
      directMaterialization: directStage ? directStage.entityMaterialization : null,
      card: card ? { ops: pooled(card.ops), warnings: coded(card.warnings), entityMaterialization: card.entityMaterialization } : null,
      applyNote: result.applyNote ?? null,
      held: result.held ?? null,
    };
  } catch (err) {
    expected = { threw: true, message: (err as Error).message === 'op not allowed' ? 'store' : 'internal' };
  }
  stagings.push({ direct: pooled(direct), cards: pooled(cards), held, sources, warnings: coded(warnings), script, expected });
}

const SHAPES: [Rec[], Rec[]][] = [
  [[], []],
  [[], [POOL[1] as Rec]],
  [[POOL[0] as Rec], []],
  [[POOL[0] as Rec], [POOL[1] as Rec]],
  [[POOL[0] as Rec, POOL[2] as Rec], [POOL[1] as Rec, POOL[3] as Rec, POOL[4] as Rec]],
];
for (const [direct, cards] of SHAPES) {
  for (const held of ['none', 'turn', 'writer_read']) {
    const warnings = held === 'none' ? [] : held === 'turn' ? ['echo'] : [PLANNER];
    for (const stageFails of [[], ['direct'], ['cards'], ['all'], ['cards', 'all']] as Role[][]) {
      for (const directWarns of [false, true]) {
        for (const applyFails of ['none', 'app', 'internal'] as const) {
          if (direct.length === 0 && (directWarns || applyFails !== 'none' || stageFails.includes('direct'))) continue;
          await recordStaging(direct, cards, held, direct.map((_, index) => (index === 1 ? 'idea' : 'quoted')), warnings, { stageFails, directWarns, applyFails });
        }
      }
    }
  }
}
await recordStaging([POOL[0] as Rec, POOL[1] as Rec], [], 'none', ['quoted'], [], { stageFails: [], directWarns: false, applyFails: 'none' });

// anchorPassageRewrites (passage-rewrite.ts:139) and droppedRewritesNote (:233)
interface Draft {
  id: bigint;
  chapter: number;
  body: string;
  revision: number;
  saveSeq: number;
  isolated: boolean;
  status: string;
}

const LINES = [
  'The salle smelled of chalk.',
  'Again, the light came in bars.',
  'Corin flexed his right hand.',
  '“Again,” Mara said.',
  '😀 the lamp 😀 burned',
  'café \u{1d11e} clef',
  'Again',
  '  indented',
];
const SEPARATORS = ['\n\n', '\n', ' '];
const REPLACEMENTS = ['rolled his wrist', '  spaced  ', 'line\r\nbreak', '😀', 'Again', 'é'];
const LABELS = [undefined, undefined, 'the wrist injury', ' café 😀 ', ''];

function randomBody(rng: Rng): string {
  const count = rng.int(1, 6);
  const lines: string[] = [];
  for (let index = 0; index < count; index++) lines.push(rng.pick(LINES));
  return lines.reduce((body, line, index) => (index === 0 ? line : body + rng.pick(SEPARATORS) + line), '');
}

function isBoundary(body: string, at: number): boolean {
  if (at <= 0 || at >= body.length) return true;
  const unit = body.charCodeAt(at);
  return !(unit >= 0xdc00 && unit <= 0xdfff && body.charCodeAt(at - 1) >= 0xd800 && body.charCodeAt(at - 1) <= 0xdbff);
}

function randomSpan(rng: Rng, body: string): { start: number; end: number } {
  for (;;) {
    const start = rng.int(0, Math.max(0, body.length - 1));
    const end = Math.min(body.length, start + rng.int(1, 30));
    if (end > start && isBoundary(body, start) && isBoundary(body, end) && body.slice(start, end).trim() !== '') return { start, end };
  }
}

function randomDrafts(rng: Rng): Draft[] {
  const drafts: Draft[] = [];
  for (const chapter of [1, 2, 3, 4]) {
    if (chapter === 2 && rng.chance(0.5)) continue;
    let body = randomBody(rng);
    if (rng.chance(0.3)) body = `${body}\n\n${body}`;
    drafts.push({ id: BigInt(chapter * 10 + rng.int(0, 1)), chapter, body, revision: rng.int(1, 3), saveSeq: rng.int(0, 1), isolated: rng.chance(0.05), status: rng.chance(0.05) ? 'final' : 'draft' });
  }
  return drafts;
}

function passageContext(rng: Rng, drafts: Draft[]): Rec {
  const draft = rng.pick(drafts);
  const { start, end } = randomSpan(rng, draft.body);
  const current = rng.chance(0.75);
  return {
    chapter: rng.chance(0.9) ? draft.chapter : 1,
    draftId: current || rng.chance(0.5) ? String(draft.id) : '99',
    revision: current ? draft.revision : draft.revision + 1,
    saveSeq: current || rng.chance(0.5) ? draft.saveSeq : draft.saveSeq + 1,
    start,
    end,
  };
}

function rewriteOp(rng: Rng, drafts: Draft[], contexts: Rec[], chapter: number): Rec {
  const draft = drafts.find(candidate => candidate.chapter === chapter);
  const body = draft?.body ?? randomBody(rng);
  const span = randomSpan(rng, body);
  let passage = body.slice(span.start, span.end);
  if (rng.chance(0.15)) passage = passage.replace(/\n/g, '\n   ');
  if (rng.chance(0.15)) passage = rng.pick(['Again', 'the', '😀', 'nowhere at all']);
  const op: Rec = { op: 'draft.rewrite_passage', chapter, passage, replacement: rng.chance(0.1) ? passage : rng.pick(REPLACEMENTS) };
  const label = rng.pick(LABELS);
  if (label !== undefined) op['label'] = label;
  const answering = contexts.flatMap((context, index) => (context['chapter'] === chapter ? [index + 1] : []));
  if (rng.chance(0.5) && answering.length > 0) op['contextIndex'] = rng.pick(answering);
  else if (rng.chance(0.3)) op['contextIndex'] = rng.int(0, contexts.length + 1);
  if (rng.chance(0.2)) {
    op['anchor'] = {
      draftId: String(draft?.id ?? chapter),
      revision: 1,
      saveSeq: 0,
      ...span,
      passageHash: anchorModule.passageHash(passage),
      paragraph: 0,
      ...anchorModule.anchorContext(body, span.start, span.end),
    };
  }
  if (rng.chance(0.1)) op['rationale'] = 'Sharper.';
  return op;
}

function otherOp(rng: Rng, chapter: number): Rec {
  return rng.pick<Rec>([
    { op: 'draft.update', chapter, body: 'New.' },
    { op: 'draft.remove', chapter },
    { op: 'brief.update', chapter, title: 'The Bout' },
    { op: 'entity.upsert', entityKey: 'mara', type: 'character', name: 'Mara' },
  ]);
}

const draftJson = (drafts: Draft[]): unknown[] => drafts.map(draft => ({ ...draft, id: String(draft.id) }));
const anchors: unknown[] = [];
const anchorRng = createRng(0xa7c40);
for (let index = 0; index < 75; index++) {
  const drafts = randomDrafts(anchorRng);
  const cursor = anchorRng.pick([0, 0, 1, 2]);
  const contexts = Array.from({ length: anchorRng.int(0, 4) }, () => passageContext(anchorRng, drafts));
  const ops: Rec[] = [];
  const count = anchorRng.int(1, 4);
  for (let attempt = 0; attempt < count * 4 && ops.length < count; attempt++) {
    const op = anchorRng.chance(0.85) ? rewriteOp(anchorRng, drafts, contexts, anchorRng.pick([1, 2, 3, 3, 4, 4])) : otherOp(anchorRng, 3);
    ops.push(op);
    if (!valid(ops)) ops.pop();
  }
  if (anchorRng.chance(0.15) && ops.length > 0) ops.push(JSON.parse(JSON.stringify(ops[0])));
  if (!valid(ops)) continue;
  const db = { query: { projects: { findFirst: async () => ({ storyCurrentChapter: cursor }) }, drafts: { findMany: async () => drafts } } };
  const anchored = await rewrite.anchorPassageRewrites(db as never, 7n, JSON.parse(JSON.stringify(ops)), contexts as never);
  anchors.push({
    drafts: draftJson(drafts),
    cursor,
    contexts,
    ops,
    expected: { ops: anchored.ops, dropped: anchored.dropped, note: rewrite.droppedRewritesNote(anchored.dropped) ?? null },
  });
}

writeFileSync(join(outDir, 'turn-staging.json'), JSON.stringify({ holds, pool: POOL, warnings: WARNINGS, splits, stagings, anchors }) + '\n');
