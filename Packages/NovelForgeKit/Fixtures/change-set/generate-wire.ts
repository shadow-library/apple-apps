import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');

const server = join(platformRepo, 'apps/novel-forge-server/src');
const outDir = dirname(fileURLToPath(import.meta.url));
const changeSetDir = join(server, 'modules/refinement/change-set');
const opSpecs = await import(join(changeSetDir, 'op-specs.ts'));
const wire = await import(join(changeSetDir, 'op-wire-schema.ts'));

const OPS: string[] = Object.keys(opSpecs.OP_SPECS);
const ACTIONS: string[] = [...opSpecs.ACTION_TYPES];
const CONTENT: string[] = [...opSpecs.CONTENT_OP_TYPES];

const organiseSource = readFileSync(join(server, 'modules/notes/organise-plan.ts'), 'utf8');
const organiseLine = /export const ORGANISE_CHANGE_OPS: readonly OpType\[\] = (\[[^\]]*\]);/.exec(organiseSource);
if (!organiseLine?.[1]) throw new Error('ORGANISE_CHANGE_OPS not found');
const ORGANISE: string[] = JSON.parse(organiseLine[1].replaceAll("'", '"'));
for (const op of ORGANISE) if (!(op in opSpecs.OP_SPECS)) throw new Error(`ORGANISE_CHANGE_OPS names an unknown op: ${op}`);

let state = 20260617;
const next = (): number => {
  state = (state + 0x6d2b79f5) | 0;
  let t = Math.imul(state ^ (state >>> 15), 1 | state);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
};
const int = (min: number, max: number): number => min + Math.floor(next() * (max - min + 1));

const optionForms = [undefined, {}, { quotes: false }, { quotes: true }];
const sets: string[][] = [[], ...OPS.map(op => [op]), OPS, ACTIONS, CONTENT, ORGANISE, [...OPS].reverse(), ['entity.upsert', 'entity.upsert']];
for (let index = 0; index < 40; index++) {
  const pool = [...OPS];
  const picked: string[] = [];
  for (let count = int(2, 8); count > 0; count--) picked.push(pool.splice(int(0, pool.length - 1), 1)[0] as string);
  sets.push(picked);
}

const formsFor = (ops: string[]): number[] => (ops === ORGANISE ? [0, 1, 2, 3] : [0, 3]);
const cases = sets.flatMap(ops => formsFor(ops).map(form => [ops, form, JSON.stringify(wire.changeSetItemSchema(ops, optionForms[form]))] as const));
console.log(`wire cases ${cases.length}`);

writeFileSync(join(outDir, 'wire-schema.json'), JSON.stringify({ organise: ORGANISE, cases }) + '\n');
