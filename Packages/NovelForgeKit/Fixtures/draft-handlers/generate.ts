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
  name: 'draft-handlers-fixture-stubs',
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
const anchor = await import(join(server, 'modules/generation/passage-anchor.ts'));

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
  'The salle smelled of chalk.',
  'Again, the light came in bars.',
  'Corin flexed his right hand.',
  '“Again,” Mara said.',
  'He was afraid of her.',
  '😀 the lamp 😀 burned',
  'café \u{1d11e} clef',
  'été combining',
  ' nbsp lead',
  'tail sep',
  '﻿bom',
  'Again',
  '  indented',
  '',
];
const SEPARATORS = ['\n\n', '\n', '\r\n', ' '];
const REPLACEMENTS = ['rolled his wrist', '  spaced  ', 'line\r\nbreak', '😀', '', '  ', 'Again', 'é', '\u{1d11e}\n\n'];
const LABELS = [undefined, undefined, '', '   ', ' the wrist injury ', 'café 😀', ' show the fear '];

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
    const end = Math.min(body.length, start + rng.int(rng.chance(0.05) ? 0 : 1, 14));
    if (isBoundary(body, start) && isBoundary(body, end)) return { start, end };
  }
}

function stamped(rng: Rng, body: string, draftId: string): Record<string, unknown> {
  const { start, end } = randomSpan(rng, body);
  const passage = body.slice(start, end);
  const leading = passage.length - passage.trimStart().length;
  const op: Record<string, unknown> = { op: 'draft.rewrite_passage', chapter: 3, passage, replacement: rng.pick(REPLACEMENTS) };
  const label = rng.pick(LABELS);
  if (label !== undefined) op['label'] = label;
  op['anchor'] = {
    draftId,
    revision: 1,
    saveSeq: 0,
    start,
    end,
    passageHash: anchor.passageHash(passage),
    paragraph: paragraphs.paragraphAt(body, start + leading),
    ...anchor.anchorContext(body, start, end),
  };
  return op;
}

type Mutation = (rng: Rng, body: string, ops: Record<string, unknown>[]) => { body: string; draftId?: string };

const MUTATIONS: Mutation[] = [
  (_, body) => ({ body }),
  (_, body) => ({ body }),
  (_, body) => ({ body: `Dawn.\n\n${body}` }),
  (_, body) => ({ body: `${body}\n\nDusk.` }),
  (_, body) => ({ body: `${body}\n\n${body}` }),
  (rng, body) => {
    const at = randomSpan(rng, body).start;
    return { body: body.slice(0, at) + rng.pick(['x', '😀', ' ', '\n']) + body.slice(at) };
  },
  (_, body) => ({ body, draftId: '30' }),
  (rng, body, ops) => {
    delete rng.pick(ops)['anchor'];
    return { body };
  },
  (rng, body, ops) => {
    const op = rng.pick(ops);
    op['passage'] = `${op['passage'] as string}!`;
    return { body };
  },
  (rng, body, ops) => {
    const stamp = rng.pick(ops)['anchor'] as Record<string, number> | undefined;
    if (stamp) {
      stamp['start'] += 1;
      stamp['end'] += 1;
    }
    return { body };
  },
  (rng, body, ops) => {
    ops.push(structuredClone(rng.pick(ops)));
    return { body };
  },
];

function run(draftBody: string, draftId: string, ops: Record<string, unknown>[]): Record<string, unknown> {
  try {
    return { body: rewrite.rewrittenBody({ id: BigInt(draftId), chapter: 3, body: draftBody }, ops) };
  } catch (error) {
    const failure = error as { code?: string; message?: string };
    if (!failure.code) throw error;
    return { code: failure.code, message: failure.message };
  }
}

const rng = createRng(0x0f14);
const cases: Record<string, unknown>[] = [];
for (let index = 0; index < 260; index++) {
  const staged = randomBody(rng);
  const ops = Array.from({ length: rng.pick([1, 1, 2, 2, 3, 4]) }, () => stamped(rng, staged, '3'));
  const mutated = rng.pick(MUTATIONS)(rng, staged, ops);
  const draftId = mutated.draftId ?? '3';
  cases.push({ body: mutated.body, draftId, chapter: 3, rewrites: ops, expected: run(mutated.body, draftId, ops) });
}

const outcomes = cases.map(entry => (entry['expected'] as { code?: string }).code ?? 'body');
for (const outcome of ['body', 'RFN_020', 'RFN_021']) {
  if (!outcomes.includes(outcome)) throw new Error(`no case ends in ${outcome}`);
}
writeFileSync(join(outDir, 'rewrites.json'), JSON.stringify(cases) + '\n');
