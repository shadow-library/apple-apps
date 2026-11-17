import { plugin } from 'bun';
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');

const server = join(platformRepo, 'apps/novel-forge-server/src');
const outDir = dirname(fileURLToPath(import.meta.url));
const briefScenes = await import(join(server, 'common/brief-scenes.ts'));
const briefBody = await import(join(server, 'common/brief-body.ts'));

plugin({
  name: 'bible-plan-handlers-fixture-stubs',
  setup(build) {
    build.module('@server/common', () => ({
      exports: {
        composePlanBody: briefBody.composePlanBody,
        normalizeBriefScenes: briefScenes.normalizeBriefScenes,
        normalizeStringList: briefScenes.normalizeStringList,
      },
      loader: 'object',
    }));
  },
});

const { mergeBriefUpdate } = await import(join(server, 'modules/refinement/brief-merge.ts'));

type Row = Record<string, unknown>;

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

const rng = createRng(0x13f13);

const WHITESPACE = [' ', '\t', ' ', '﻿', ' ', '　', '\n', ''];
const WORDS = ['Mara', 'the ledger', 'café', 'été', '😀 lamp', '\u{1d11e} clef', 'Ren waits', 'Ada hides the slip', ''];
const KEYS = ['mara', 'ren', 'ada', 'ledger_house', 'rank_3', 'rank_4', 'café'];
const HOOK_TYPES = ['cliffhanger', 'revelation', 'quiet_dread', 'promise', 'turn', 'closure_with_momentum', 'earned_rest'];
const BODIES = [
  'Mara tests the lamp.',
  'Mara tests the lamp.\nScene 1 (~900 words). Stale line from staging.',
  'Written by hand.\r\n\r\nScene 1 is mine.',
  `Mara climbs.\n${briefBody.CONTINUES_LINE}`,
  `${briefBody.STARTS_LINE}\nScene 1. Old.\nKept note.\nScene 2. Older.\n${briefBody.HANDOFF_PREFIX}the gate`,
  '',
  '  😀 ',
];

const padded = (text: string): string => `${rng.pick(WHITESPACE)}${text}${rng.pick(WHITESPACE)}`;
const text = (): string => (rng.chance(0.3) ? padded(rng.pick(WORDS)) : rng.pick(WORDS));
const nonBlank = (): string => `${rng.pick(WHITESPACE)}${rng.pick(WORDS.filter(word => word !== ''))}${rng.pick(WHITESPACE)}`;
const list = (item: () => string, min = 0): string[] => Array.from({ length: rng.int(min, 3) }, item);

function scene(): Row {
  const record: Row = { summary: nonBlank() };
  if (rng.chance(0.7)) record['pov'] = rng.chance(0.3) ? null : padded(rng.pick(KEYS));
  for (const field of ['goal', 'obstacle', 'turn']) if (rng.chance(0.4)) record[field] = text();
  if (rng.chance(0.4)) record['beats'] = list(text);
  if (rng.chance(0.4)) record['estimatedWords'] = rng.int(1, 2000);
  return record;
}

function endingContract(): Row {
  const contract: Row = { hookType: rng.pick(HOOK_TYPES), emotionalBeat: nonBlank(), openQuestion: nonBlank(), handoffState: nonBlank() };
  if (rng.chance(0.5)) contract['mustNotResolve'] = list(text);
  return contract;
}

function knowledgeContract(): Row {
  const contract: Row = { pov: list(() => rng.pick(KEYS), 1) };
  if (rng.chance(0.7)) contract['learns'] = list(() => rng.pick(KEYS)).map(entityKey => ({ entityKey, factKey: rng.pick(KEYS) }));
  return contract;
}

/** A brief.update the change-set validator accepts: blank claims and invalid scenes are refused before any merge. */
function op(chapter: number, creating: boolean): Row {
  const record: Row = { op: 'brief.update', chapter };
  const maybe = (field: string, value: () => unknown, nullable = false): void => {
    if (!rng.chance(0.5)) return;
    record[field] = nullable && rng.chance(0.25) ? null : value();
  };
  maybe('title', text);
  if (creating || rng.chance(0.5)) record['body'] = rng.pick(BODIES);
  maybe('writeMode', () => rng.pick(['standard', 'external']));
  maybe('volumeKey', () => rng.pick(['v1', 'volume_2', 'vol_😀']));
  maybe('contextRefs', () => list(() => `doc:world/${rng.pick(KEYS)}`));
  maybe('pov', () => (rng.chance(0.3) ? rng.pick(WHITESPACE) : padded(rng.pick(KEYS))), true);
  maybe('chapterPurpose', text);
  maybe('readerValue', () => list(text));
  maybe('repetitionRisks', () => list(text), true);
  maybe('densityRisk', () => (rng.chance(0.3) ? rng.pick(WHITESPACE) : padded(rng.pick(WORDS))), true);
  maybe('endingContract', endingContract);
  maybe('knowledgeContract', knowledgeContract, true);
  maybe('direction', () => (rng.chance(0.3) ? rng.pick(WHITESPACE) : padded(rng.pick(WORDS))), true);
  maybe('contentMode', () => rng.pick(['standard', 'unrestricted']), true);
  maybe('scenes', () => list(scene), true);
  maybe('claimedMilestones', () => list(() => padded(rng.pick(KEYS))), true);
  maybe('isEnding', () => rng.chance(0.5));
  return record;
}

function sceneShape(value: Row): Row {
  const shaped: Row = { summary: value['summary'], pov: value['pov'] ?? null };
  for (const field of ['goal', 'obstacle', 'turn', 'beats', 'estimatedWords']) if (value[field] !== undefined && value[field] !== null) shaped[field] = value[field];
  return shaped;
}

/**
 * The merged brief in the shape a native plan holds, as its captured inverse prints it: an empty knowledge contract and an empty claim list are `null` (a
 * native plan stores neither apart from none), `learns` is always listed and every optional field is explicit.
 */
function shape(chapter: number, merged: Row, handEdited: boolean): Row {
  const knowledge = merged['knowledgeContract'] as { pov?: string[]; learns?: Row[] } | null;
  const pov = knowledge?.pov ?? [];
  const learns = (knowledge?.learns ?? []).map(learn => ({ entityKey: learn['entityKey'], factKey: learn['factKey'] }));
  const ending = merged['endingContract'] as Row | null;
  const claims = merged['claimedMilestones'] as string[] | null;
  const scenes = merged['scenes'] as Row[] | null;
  return {
    op: 'brief.update',
    chapter,
    title: merged['title'] ?? null,
    body: merged['body'],
    volumeKey: merged['volumeKey'] ?? null,
    writeMode: merged['writeMode'],
    handEdited,
    contextRefs: merged['contextRefs'] ?? null,
    pov: merged['pov'] ?? null,
    chapterPurpose: merged['chapterPurpose'] ?? null,
    readerValue: merged['readerValue'] ?? null,
    repetitionRisks: merged['repetitionRisks'] ?? null,
    densityRisk: merged['densityRisk'] ?? null,
    endingContract: ending
      ? {
          hookType: ending['hookType'],
          emotionalBeat: ending['emotionalBeat'],
          openQuestion: ending['openQuestion'],
          handoffState: ending['handoffState'],
          ...(ending['mustNotResolve'] !== undefined ? { mustNotResolve: ending['mustNotResolve'] } : {}),
        }
      : null,
    knowledgeContract: pov.length === 0 && learns.length === 0 ? null : { pov, learns },
    direction: merged['direction'] ?? null,
    contentMode: merged['contentMode'] ?? null,
    scenes: scenes ? scenes.map(sceneShape) : null,
    claimedMilestones: claims && claims.length > 0 ? claims : null,
    isEnding: merged['isEnding'],
  };
}

const defaults = (): Row => ({
  volumeKey: rng.pick([null, 'v1', 'vol_😀']),
  contentMode: rng.pick([null, 'standard', 'unrestricted']),
});

const cases: Row[] = [];
for (let index = 0; index < 160; index++) {
  const chapter = rng.int(1, 40);
  const existing = rng.chance(0.65) ? mergeBriefUpdate(undefined, op(chapter, true) as never, defaults() as never) : undefined;
  const update = op(chapter, existing === undefined);
  const given = defaults();
  const merged = mergeBriefUpdate(existing as never, update as never, given as never);
  cases.push({
    existing: existing ? shape(chapter, existing as Row, false) : null,
    op: update,
    defaults: given,
    expected: shape(chapter, merged as Row, true),
  });
}

writeFileSync(join(outDir, 'merge.json'), JSON.stringify(cases) + '\n');
