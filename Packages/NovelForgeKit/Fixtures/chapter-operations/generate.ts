import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');
const src = join(platformRepo, 'apps/novel-forge-server/src');
const outDir = dirname(fileURLToPath(import.meta.url));

const briefBody = await import(join(src, 'common/brief-body.ts'));

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
  const int = (min: number, max: number): number => min + Math.floor(next() * (max - min + 1));
  return { next, int, chance: p => next() < p, pick: items => items[Math.floor(next() * items.length)] as never };
}

function repeat<T>(count: number, make: (index: number) => T): T[] {
  return Array.from({ length: count }, (_, index) => make(index));
}

const WORDS = ['Mira runs', 'the tide', 'ash.', 'keeper!', 'why?', 'end…', 'said "no"', "it's 'so'", 'he said ”', 'she said ’', '(aside)', 'Ünï', 'é', '日本語', '😀', 'x'];
const SPACES = ['', ' ', '  ', '\t', '\n', ' ', '　', ' ', '﻿', '\u0085', '​'];
const LINES = [
  'Scene 1. Old.',
  'Scene 12 (~300 words). Older.',
  'Scene 3a not a scene',
  'Scene 4_ not a scene',
  'Scene 5é counts',
  'Scene x',
  'Scene',
  'scene 2 lower',
  ' Scene 2 indented',
  '',
  '   ',
  '\t',
  ' ',
  'The objective.',
  'An event.',
  briefBody.CONTINUES_LINE,
  briefBody.STARTS_LINE,
  `${briefBody.HANDOFF_PREFIX}the door opens`,
  'Handoff beat:no space',
];

function text(rng: Rng): string {
  return rng.pick(SPACES) + rng.pick(WORDS) + (rng.chance(0.4) ? rng.pick(SPACES) + rng.pick(WORDS) : '') + rng.pick(SPACES);
}

function scene(rng: Rng): Record<string, unknown> {
  const out: Record<string, unknown> = { summary: text(rng), pov: rng.chance(0.5) ? rng.pick(['mara', 'tobin', 'é']) : null };
  for (const key of ['goal', 'obstacle', 'turn']) if (rng.chance(0.5)) out[key] = rng.chance(0.15) ? '' : text(rng);
  if (rng.chance(0.5)) out.beats = repeat(rng.int(0, 3), () => (rng.chance(0.2) ? rng.pick(SPACES) : text(rng)));
  if (rng.chance(0.5)) out.estimatedWords = rng.pick([0, 1, 250, 1200, 99999]);
  return out;
}

const compose = repeat(400, index => {
  const rng = createRng(4000 + index);
  const body = rng.chance(0.1) ? '' : repeat(rng.int(1, 8), () => rng.pick(LINES)).join('\n');
  const scenes = repeat(rng.pick([0, 0, 1, 2, 3, 5]), () => scene(rng));
  return [body, scenes, briefBody.composePlanBody(body, scenes)];
});

writeFileSync(join(outDir, 'compose.json'), JSON.stringify(compose) + '\n');
process.exit(0);
