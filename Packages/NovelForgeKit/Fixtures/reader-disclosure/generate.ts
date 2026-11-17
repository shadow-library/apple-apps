import { plugin } from 'bun';
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');

const server = join(platformRepo, 'apps/novel-forge-server/src');
const outDir = dirname(fileURLToPath(import.meta.url));
const classes = await import(join(server, 'classes/app-error-code.ts'));

type Row = Record<string, unknown>;
type Condition = { op: string; args: unknown[] } | undefined;
type Column = { column: string };

const tables = new Map<string, unknown>();

function table(name: string): unknown {
  if (!tables.has(name)) tables.set(name, new Proxy({ name } as Row, { get: (target, column: string) => (column === 'name' ? target.name : { column }) }));
  return tables.get(name);
}

plugin({
  name: 'reader-disclosure-fixture-stubs',
  setup(build) {
    const op = (name: string) => (...args: unknown[]) => ({ op: name, args });
    const ops = ['and', 'or', 'eq', 'ne', 'lt', 'lte', 'gt', 'like', 'inArray', 'notInArray', 'isNull', 'isNotNull', 'asc', 'desc', 'sql'];
    build.module('drizzle-orm', () => ({ exports: Object.fromEntries(ops.map(name => [name, op(name)])), loader: 'object' }));
    build.module('@server/database', () => ({ exports: { schema: new Proxy({}, { get: (_, name: string) => table(name) }) }, loader: 'object' }));
    build.module('@server/classes', () => ({ exports: { AppErrorCode: classes.AppErrorCode, RevealRuleError: class extends Error {} }, loader: 'object' }));
    build.module('@server/constants', () => ({ exports: { APP_NAME: 'fixture' }, loader: 'object' }));
    build.module('@shadow-library/common', () => ({
      exports: { Logger: { getLogger: () => ({ warn() {}, info() {}, error() {}, debug() {} }) }, AppError: class extends Error {} },
      loader: 'object',
    }));
    build.onResolve({ filter: /\/chapter-shift$/ }, () => ({ path: 'chapter-shift', namespace: 'stub' }));
    build.onLoad({ filter: /.*/, namespace: 'stub' }, () => ({ contents: 'export const shiftChapterNumber = () => 0;', loader: 'js' }));
  },
});

const provisional = await import(join(server, 'common/provisional-knowledge.ts'));
const planState = await import(join(server, 'common/plan-state.ts'));

// An in-memory database that answers the drizzle reads and writes of planRevealsRefusal, discloseChapterReveals and reachClaimedMilestones.
function holds(condition: Condition, row: Row): boolean {
  if (!condition) return true;
  const [first, second] = condition.args as [Column, unknown];
  const value = row[first?.column as string];
  const present = (candidate: unknown): boolean => candidate !== null && candidate !== undefined;
  switch (condition.op) {
    case 'and':
      return condition.args.every(part => holds(part as Condition, row));
    case 'eq':
      return present(value) && present(second) && value === second;
    case 'ne':
      return present(value) && present(second) && value !== second;
    case 'lte':
      return present(value) && present(second) && (value as number) <= (second as number);
    case 'inArray':
      return present(value) && (second as unknown[]).includes(value);
    case 'isNull':
      return !present(value);
    case 'isNotNull':
      return present(value);
    default:
      throw new Error(`unsupported condition ${condition.op}`);
  }
}

function ordered(rows: Row[], orderBy: unknown): Row[] {
  if (!orderBy) return rows;
  const spec = orderBy as { op: string; args: [Column] };
  const column = spec.args[0].column;
  const direction = spec.op === 'desc' ? -1 : 1;
  return [...rows].sort((left, right) => direction * ((left[column] as number) - (right[column] as number)));
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
  return {
    query,
    update: (target: Row) => ({
      set: (values: Row) => ({
        where: (where: Condition) => ({
          then: (resolve: (value: unknown) => unknown, reject: (error: unknown) => unknown) =>
            Promise.resolve()
              .then(() => {
                for (const row of rows(target.name as string).filter(candidate => holds(where, candidate))) {
                  Object.assign(row, Object.fromEntries(Object.entries(values).filter(([column]) => column !== 'updatedAt')));
                }
              })
              .then(resolve, reject),
        }),
      }),
    }),
  };
}

interface Rng {
  int(min: number, max: number): number;
  chance(p: number): boolean;
  pick<T>(items: readonly T[]): T;
  subset<T>(items: readonly T[], p: number): T[];
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
    subset: (items, p) => items.filter(() => next() < p),
  };
}

// Keys are NFC, as every stored key is.
const MILESTONES = ['m_rank', 'm_tower', 'm_sea', 'm_é'];
const FACTS = ['f_ledger', 'f_heir', 'f_twin', 'f_é', 'f_salt', 'f_bell'];
const VOLUMES = ['one', 'two', 'three'];
const ENTITIES = ['mara', 'elias'];
const SOURCES = ['brief', 'manual', 'import', 'seed', 'generated'];
const CHAPTERS = 8;

type Term = { milestone?: string; volume?: string; chapter?: number; ending?: true };

function term(rng: Rng): Term {
  switch (rng.int(0, 3)) {
    case 0:
      return { milestone: rng.pick([...MILESTONES, 'm_ghost']) };
    case 1:
      return { volume: rng.pick([...VOLUMES, 'v_ghost']) };
    case 2:
      return { chapter: rng.int(1, CHAPTERS + 1) };
    default:
      return { ending: true };
  }
}

const rng = createRng(0x0e01);

// Each world tries to finalize chapters 1 to `finals` in order, as finalize requires, and stops at the first chapter whose plan's reveals do not hold (`finalized`);
// a secret with `createdAfter` n is created once n chapters are final.
const cases = await Promise.all(
  Array.from({ length: 300 }, async () => {
    const volumes = rng.subset(VOLUMES, 0.7).map(volume => ({ volume, ordinal: rng.int(0, 4) }));
    const milestones = rng.subset(MILESTONES, 0.8);
    const finals = rng.chance(0.15) ? 0 : rng.int(1, CHAPTERS);
    const facts = rng.subset(FACTS, 0.8).map(fact => ({
      fact,
      revealChapter: rng.chance(0.8) ? (rng.chance(0.5) ? rng.int(0, 3) : rng.int(0, CHAPTERS + 1)) : null,
      unlock: rng.chance(0.25) ? Array.from({ length: rng.int(1, 2) }, () => term(rng)) : null,
      source: rng.pick(SOURCES),
      createdAfter: rng.chance(0.7) ? 0 : rng.int(0, finals),
    }));
    const plans = [];
    // The reference refuses a second ending plan (plan-state.ts:40, PLN_002), so a world holds at most one.
    let endingTaken = false;
    for (let chapter = 1; chapter <= CHAPTERS; chapter++) {
      if (!rng.chance(0.8)) continue;
      const claims = rng.subset([...MILESTONES, 'm_ghost'], 0.15);
      const pov = rng.chance(0.6) ? [rng.pick(ENTITIES)] : rng.pick([[], [''], []]);
      const learns = Array.from({ length: rng.int(0, 3) }, () => ({ entity: rng.pick([...ENTITIES, 'e_ghost']), fact: rng.pick([...FACTS, 'f_ghost']) }));
      const volume = rng.chance(0.8) ? rng.pick([...VOLUMES, 'v_ghost']) : null;
      const ending = rng.chance(0.12) && !endingTaken;
      endingTaken ||= ending;
      plans.push({ chapter, volume, ending, claims, pov, learns });
    }

    const canonFacts: Row[] = [];
    const chapters: Row[] = [];
    const db = fakeDb({
      projects: [{ id: 1n, storyCurrentChapter: 0 }],
      chapters,
      briefs: plans.map((plan, index) => ({
        id: BigInt(index + 1),
        projectId: 1n,
        chapter: plan.chapter,
        volumeKey: plan.volume,
        isEnding: plan.ending,
        claimedMilestones: plan.claims,
        knowledgeContract: { pov: plan.pov, learns: plan.learns.map(learn => ({ entityKey: learn.entity, factKey: learn.fact })) },
        staleReason: null,
      })),
      milestones: milestones.map((milestoneKey, index) => ({ id: BigInt(index + 1), projectId: 1n, milestoneKey, state: 'open', plannedChapter: null, reachedChapter: null })),
      volumes: volumes.map(volume => ({ projectId: 1n, volumeKey: volume.volume, ordinal: volume.ordinal })),
      canonFacts,
    });
    let finalized = 0;
    for (let done = 0; done <= finals; done++) {
      for (const [index, fact] of facts.entries()) {
        if (fact.createdAfter !== done) continue;
        canonFacts.push({
          id: BigInt(index + 1),
          projectId: 1n,
          factKey: fact.fact,
          revealChapter: fact.revealChapter,
          unlock: fact.unlock && { all: fact.unlock },
          source: fact.source,
          plannedChapter: null,
          disclosedInChapter: null,
        });
      }
      if (done === finals) break;
      // ai/graphs/chapter-finalization.graph.ts:137 refuses a chapter whose plan's reveals do not hold, as approval does
      if (await planState.planRevealsRefusal(db, 1n, done + 1)) break;
      // ai/graphs/chapter-finalization.graph.ts:175-177: knowledge is committed (and the chapter's reveals disclosed) before its claims are reached
      await provisional.discloseChapterReveals(db, 1n, done + 1);
      await planState.reachClaimedMilestones(db, 1n, done + 1, 1);
      chapters.push({ projectId: 1n, number: done + 1, status: 'done' });
      finalized = done + 1;
    }

    const disclosed = Object.fromEntries(canonFacts.filter(row => row.disclosedInChapter !== null).map(row => [row.factKey, row.disclosedInChapter]));
    return { volumes, milestones, facts, plans, finals, finalized, expected: disclosed };
  }),
);

writeFileSync(join(outDir, 'disclosure.json'), `${JSON.stringify({ cases })}\n`);
