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
const sanitize = await import(join(server, 'common/sanitize-content.ts'));
const paragraphs = await import(join(platformRepo, 'packages/sdk/src/prose-paragraphs.ts'));

const noop = () => undefined;
const columns = (table: string): unknown => new Proxy({}, { get: (_, column) => `${table}.${String(column)}` });
const schema = new Proxy({}, { get: (_, table) => columns(String(table)) });

plugin({
  name: 'proposal-staging-fixture-stubs',
  setup(build) {
    build.module('@server/classes', () => ({ exports: { AppErrorCode: classes.AppErrorCode }, loader: 'object' }));
    build.module('@server/common', () => ({
      exports: {
        normalizeLineEndings: sanitize.normalizeLineEndings,
        validateBriefScenes: briefScenes.validateBriefScenes,
        validateUnlockCondition: unlockCondition.validateUnlockCondition,
        computeContentHash: noop,
      },
      loader: 'object',
    }));
    build.module('@server/database', () => ({ exports: { schema }, loader: 'object' }));
    build.module('@shadow-library/sdk', () => ({ exports: { paragraphAt: paragraphs.paragraphAt }, loader: 'object' }));
    build.module('drizzle-orm', () => ({ exports: { and: noop, eq: noop, inArray: noop, sql: noop }, loader: 'object' }));
  },
});

const rewrite = await import(join(server, 'modules/refinement/passage-rewrite.ts'));
const warnings = await import(join(server, 'modules/refinement/proposal-warnings.ts'));
const changeSet = await import(join(server, 'modules/refinement/change-set/index.ts'));
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

type Op = Record<string, unknown>;

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
  'He was afraid of her.',
  '😀 the lamp 😀 burned',
  'café \u{1d11e} clef',
  'été combining',
  ' nbsp lead',
  'tail sep',
  '﻿bom',
  'Again',
  '  indented',
];
const SEPARATORS = ['\n\n', '\n', ' '];
const REPLACEMENTS = ['rolled his wrist', '  spaced  ', 'line\r\nbreak', '😀', '  ', 'Again', 'é', '\u{1d11e}\n\n', 'x'];
const LABELS = [undefined, undefined, 'the wrist injury', ' café 😀 '];

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
    const end = Math.min(body.length, start + rng.int(1, 40));
    if (end > start && isBoundary(body, start) && isBoundary(body, end) && body.slice(start, end).trim() !== '') return { start, end };
  }
}

function randomPassage(rng: Rng, body: string): string {
  const { start, end } = randomSpan(rng, body);
  const passage = body.slice(start, end);
  switch (rng.int(0, 11)) {
    case 0:
      return passage.replace(/\n/g, '\n   ');
    case 1:
      return passage.replace(/\n/g, '\r\n');
    case 2:
      return `${passage}!`;
    case 3:
      return rng.pick(['Again', 'the', '😀', 'nowhere at all']);
    case 4:
      return rng.chance(0.25) ? 'x'.repeat(6001) : passage;
    default:
      return passage;
  }
}

function stampedAnchor(rng: Rng, body: string, draftId: string): Record<string, unknown> {
  const { start, end } = randomSpan(rng, body);
  const passage = body.slice(start, end);
  const leading = passage.length - passage.trimStart().length;
  return {
    draftId,
    revision: rng.int(1, 3),
    saveSeq: rng.int(0, 2),
    start,
    end,
    passageHash: anchorModule.passageHash(passage),
    paragraph: paragraphs.paragraphAt(body, start + leading),
    ...anchorModule.anchorContext(body, start, end),
  };
}

function rewriteOp(rng: Rng, drafts: Draft[], chapter: number): Op {
  const draft = drafts.find(candidate => candidate.chapter === chapter);
  const body = draft?.body ?? randomBody(rng);
  const op: Op = { op: 'draft.rewrite_passage', chapter, passage: randomPassage(rng, body), replacement: rng.pick(REPLACEMENTS) };
  if (rng.chance(0.15)) op['replacement'] = op['passage'];
  const label = rng.pick(LABELS);
  if (label !== undefined) op['label'] = label;
  if (rng.chance(0.2)) op['contextIndex'] = rng.int(1, 3);
  if (rng.chance(0.4)) {
    const anchorBody = rng.chance(0.7) ? body : `Dawn.\n\n${body}`;
    const anchor = stampedAnchor(rng, anchorBody, rng.chance(0.85) ? String(draft?.id ?? chapter) : '99');
    if (rng.chance(0.5)) op['passage'] = anchorBody.slice(anchor['start'] as number, anchor['end'] as number);
    op['anchor'] = anchor;
  }
  if (rng.chance(0.1)) op['rationale'] = 'Sharper.';
  return op;
}

function otherOp(rng: Rng, chapter: number): Op {
  return rng.pick<Op>([
    { op: 'draft.update', chapter, body: 'New.' },
    { op: 'draft.remove', chapter },
    { op: 'brief.update', chapter, title: 'The Bout' },
    { op: 'entity.upsert', entityKey: 'mara', type: 'character', name: 'Mara' },
    { op: 'action.approve_draft', chapter },
  ]);
}

function randomDrafts(rng: Rng): Draft[] {
  const drafts: Draft[] = [];
  for (const chapter of [1, 2, 3, 4]) {
    if (chapter === 2 && rng.chance(0.5)) continue;
    let body = randomBody(rng);
    if (rng.chance(0.15)) body = `${body}\n\n${body}`;
    drafts.push({
      id: BigInt(chapter * 10 + rng.int(0, 1)),
      chapter,
      body,
      revision: rng.int(1, 4),
      saveSeq: rng.int(0, 3),
      isolated: rng.chance(0.05),
      status: rng.chance(0.05) ? 'final' : 'draft',
    });
  }
  return drafts;
}

function fakeDb(drafts: Draft[], cursor: number): unknown {
  return {
    query: {
      projects: { findFirst: async () => ({ storyCurrentChapter: cursor }) },
      drafts: { findMany: async () => drafts },
    },
  };
}

const draftJson = (drafts: Draft[]): unknown[] => drafts.map(draft => ({ ...draft, id: String(draft.id) }));

function valid(ops: Op[]): boolean {
  return changeSet.validateChangeSet(ops, undefined, { entityMaterialization: false }).length === 0;
}

const rng = createRng(0x0f15);

const anchors: unknown[] = [];
const fixedDrafts: Draft[] = [
  { id: 10n, chapter: 1, body: 'The tide turns.', revision: 2, saveSeq: 0, isolated: false, status: 'final' },
  { id: 30n, chapter: 3, body: 'Again, the light.\n\n“Again,” Mara said.\nShe left.', revision: 1, saveSeq: 1, isolated: false, status: 'draft' },
  { id: 40n, chapter: 4, body: 'Walled prose.', revision: 1, saveSeq: 0, isolated: true, status: 'draft' },
];
const fixedOps: Op[][] = [
  [{ op: 'draft.rewrite_passage', chapter: 1, passage: 'tide', replacement: 'sea' }],
  [{ op: 'draft.rewrite_passage', chapter: 2, passage: 'tide', replacement: 'sea' }],
  [{ op: 'draft.rewrite_passage', chapter: 4, passage: 'Walled', replacement: 'Open' }],
  [{ op: 'draft.rewrite_passage', chapter: 3, passage: 'x'.repeat(6001), replacement: 'y' }],
  [{ op: 'draft.rewrite_passage', chapter: 3, passage: 'Again', replacement: 'Once more' }],
  [{ op: 'draft.rewrite_passage', chapter: 3, passage: 'gone', replacement: 'here' }],
  [{ op: 'draft.rewrite_passage', chapter: 3, passage: 'She left.', replacement: ' She left. ' }],
  [{ op: 'draft.rewrite_passage', chapter: 3, passage: 'Mara said.\n   She left.', replacement: 'Mara left.' }],
  [{ op: 'draft.rewrite_passage', chapter: 3, passage: 'She left.', replacement: 'Gone.' }, { op: 'draft.update', chapter: 3, title: 'T' }],
];
for (const ops of fixedOps) {
  let expected: unknown;
  try {
    expected = { ops: await rewrite.stampPassageAnchors(fakeDb(fixedDrafts, 0), 7n, ops) };
  } catch (error) {
    expected = { code: (error as { code: string }).code };
  }
  anchors.push({ drafts: draftJson(fixedDrafts), cursor: 0, ops, expected });
}
while (anchors.length < 220) {
  const drafts = randomDrafts(rng);
  const cursor = rng.pick([0, 0, 0, 0, 1, 2]);
  const ops: Op[] = [];
  const count = rng.pick([1, 1, 1, 2, 3]);
  for (let index = 0; index < count; index++) ops.push(rewriteOp(rng, drafts, rng.pick([1, 2, 3, 3, 3, 4, 4])));
  if (rng.chance(0.25)) ops.splice(rng.int(0, ops.length), 0, otherOp(rng, rng.pick([1, 3, 5])));
  if (!valid(ops)) continue;
  let expected: unknown;
  try {
    expected = { ops: await rewrite.stampPassageAnchors(fakeDb(drafts, cursor), 7n, ops) };
  } catch (error) {
    const failure = error as { code?: string };
    if (!failure.code) throw error;
    expected = { code: failure.code };
  }
  anchors.push({ drafts: draftJson(drafts), cursor, ops, expected });
}

const apart: unknown[] = [];
while (apart.length < 100) {
  const drafts = randomDrafts(rng).map(draft => ({ ...draft, status: 'draft', isolated: false }));
  const stage = async (count: number): Promise<Op[] | null> => {
    const ops: Op[] = [];
    for (let index = 0; index < count; index++) ops.push(rng.chance(0.85) ? rewriteOp(rng, drafts, rng.pick([3, 3, 4])) : otherOp(rng, 3));
    if (!valid(ops)) return null;
    try {
      return await rewrite.stampPassageAnchors(fakeDb(drafts, 0), 7n, ops);
    } catch {
      return null;
    }
  };
  const older = await stage(rng.int(1, 2));
  const newer = await stage(rng.int(1, 2));
  if (!older || !newer) continue;
  const standing = drafts.map(draft => {
    const roll = rng.int(0, 5);
    if (roll === 0) return { ...draft, body: `Dawn.\n\n${draft.body}` };
    if (roll === 1) return { ...draft, id: draft.id + 100n };
    if (roll === 2) return { ...draft, body: draft.body.replace(/a/, 'aa') };
    return draft;
  });
  const newerRefs = changeSet.changeSetRefs(newer) as string[];
  const shared = (changeSet.changeSetRefs(older) as string[]).filter(ref => newerRefs.includes(ref));
  const map = new Map(standing.map(draft => [draft.chapter, draft]));
  apart.push({ drafts: draftJson(standing), older, newer, shared, expected: rewrite.rewritesApart(older, newer, shared, map) });
}

const TEXTS = [
  'Mara carries a dagger. The tower has a bell.',
  'Mara carries no dagger. The tower has a bell.',
  'The harbour is quiet, without the lantern.',
  'The harbour is quiet.',
  'There is no dragon in café 😀 country.',
  'A dragon guards café 😀 country.',
  'Corin wears the crown\r\nand the ring.',
  'Corin wears neither the crown nor the ring.',
  '',
  'é combining nothing here',
];
const pickText = (r: Rng): string | null => (r.chance(0.15) ? null : r.pick(TEXTS));

function textOp(r: Rng): { op: Op; ref: string; fields: string[] } {
  switch (r.int(0, 3)) {
    case 0: {
      const op: Op = { op: 'brief.update', chapter: 4 };
      if (r.chance(0.6)) op['title'] = r.pick(TEXTS) || 'Plan';
      if (r.chance(0.8)) op['body'] = r.pick(TEXTS) || 'Plan';
      return { op, ref: 'chapter:4', fields: ['title', 'body'] };
    }
    case 1: {
      const op: Op = { op: 'draft.update', chapter: 3 };
      if (r.chance(0.5)) op['title'] = r.pick(TEXTS) || 'Title';
      op['body'] = r.pick(TEXTS) || 'Body';
      if (r.chance(0.5)) op['summary'] = r.pick(TEXTS) || 'Summary';
      return { op, ref: 'draft:3', fields: ['title', 'body', 'summary'] };
    }
    case 2: {
      const op: Op = { op: 'bible_document.upsert', section: 'world', slug: r.pick(['geography', 'café']), body: r.pick(TEXTS) || 'Body' };
      return { op, ref: `doc:world/${op['slug'] as string}`, fields: ['body'] };
    }
    default: {
      const op: Op = { op: 'entity.upsert', entityKey: 'mara', type: 'character', name: 'Mara' };
      for (const field of ['status', 'motivation', 'notes', 'body']) if (r.chance(0.5)) op[field] = r.pick(TEXTS) || 'Text';
      return { op, ref: 'entity:mara', fields: ['status', 'motivation', 'notes', 'body'] };
    }
  }
}

const echoes: unknown[] = [];
while (echoes.length < 160) {
  const picked = Array.from({ length: rng.int(1, 3) }, () => textOp(rng));
  const ops = picked.map(entry => entry.op);
  if (rng.chance(0.2)) ops.push({ op: 'fact.upsert', factKey: 'heir', revealChapter: null });
  if (!valid(ops)) continue;
  const baselines: Record<string, Record<string, string | null>> = {};
  for (const entry of picked) {
    if (rng.chance(0.2)) continue;
    baselines[entry.ref] = Object.fromEntries(entry.fields.map(field => [field, pickText(rng)]));
  }
  echoes.push({ ops, baselines, expected: warnings.negationEchoWarnings(ops, new Map(Object.entries(baselines))) });
}

const clears: unknown[] = [];
const FACT_KEYS = ['heir', 'tide', 'café', '😀'];
while (clears.length < 60) {
  const ops: Op[] = Array.from({ length: rng.int(1, 4) }, () => {
    const factKey = rng.pick(FACT_KEYS);
    return rng.pick<Op>([{ op: 'fact.upsert', factKey, revealChapter: null }, { op: 'fact.upsert', factKey, revealChapter: 3 }, { op: 'fact.upsert', factKey, body: 'x' }, { op: 'fact.remove', factKey }]);
  });
  if (!valid(ops)) continue;
  const dated = Object.fromEntries(FACT_KEYS.filter(() => rng.chance(0.6)).map(key => [key, rng.int(1, 12)]));
  clears.push({ ops, dated, expected: warnings.revealClearWarnings(ops, new Map(Object.entries(dated))) });
}

const outcomes = anchors.map(entry => ('code' in (entry as { expected: object }).expected ? 'refused' : 'anchored'));
for (const outcome of ['refused', 'anchored']) if (!outcomes.includes(outcome)) throw new Error(`no anchor case is ${outcome}`);
for (const verdict of [true, false]) if (!apart.some(entry => (entry as { expected: boolean }).expected === verdict)) throw new Error(`no apart case is ${verdict}`);
if (!echoes.some(entry => ((entry as { expected: string[] }).expected).length > 0)) throw new Error('no echo case warns');
if (!clears.some(entry => ((entry as { expected: string[] }).expected).length > 0)) throw new Error('no clear case warns');

writeFileSync(join(outDir, 'staging.json'), JSON.stringify({ anchors, apart, echoes, clears }) + '\n');
