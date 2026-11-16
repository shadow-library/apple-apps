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
  name: 'chapter-fixture-stubs',
  setup(build) {
    const op = (name: string) => (...args: unknown[]) => ({ op: name, args });
    const ops = ['and', 'or', 'eq', 'ne', 'lt', 'lte', 'gt', 'like', 'inArray', 'notInArray', 'isNull', 'isNotNull', 'asc', 'desc'];
    build.module('drizzle-orm', () => ({
      exports: { ...Object.fromEntries(ops.map(name => [name, op(name)])), sql: (strings: TemplateStringsArray, ...values: unknown[]) => ({ op: 'sql', args: [[...strings], values] }) },
      loader: 'object',
    }));
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

const staleness = await import(join(server, 'common/draft-staleness.ts'));
const provisional = await import(join(server, 'common/provisional-knowledge.ts'));
const planState = await import(join(server, 'common/plan-state.ts'));

// An in-memory database that answers the drizzle reads and writes these modules make, by evaluating their conditions on plain rows.
const camel = (snake: string): string => snake.replace(/_(\w)/g, (_, letter: string) => letter.toUpperCase());

function compare(left: unknown, right: unknown): number {
  return (left as number) < (right as number) ? -1 : (left as number) > (right as number) ? 1 : 0;
}

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
    case 'ne':
      return present(value()) && present(second) && value() !== second;
    case 'lt':
      return present(value()) && present(second) && compare(value(), second) < 0;
    case 'lte':
      return present(value()) && present(second) && compare(value(), second) <= 0;
    case 'gt':
      return present(value()) && present(second) && compare(value(), second) > 0;
    case 'like': {
      const pattern = second as string;
      if (!pattern.endsWith('%') || pattern.slice(0, -1).includes('%')) throw new Error(`unsupported like ${pattern}`);
      return typeof value() === 'string' && (value() as string).startsWith(pattern.slice(0, -1));
    }
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
  const spec = (Array.isArray(orderBy) ? orderBy[0] : orderBy) as { op?: string; args?: [Column]; column?: string };
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
  const changing = (run: () => Row[]) => {
    let changed: Row[] | undefined;
    const once = (): Row[] => (changed ??= run());
    return { ...thenable(once), returning: (columns: Record<string, Column>) => thenable(() => project(once(), columns)) };
  };
  return {
    query,
    insert: (target: Row) => ({
      values: (incoming: Row[]) => ({
        onConflictDoUpdate: ({ target: keys, set, setWhere }: { target: Column[]; set: Row; setWhere?: Condition }) =>
          thenable(() => {
            for (const row of [incoming].flat()) {
              const existing = rows(target.name as string).find(candidate => keys.every(key => candidate[key.column] === row[key.column]));
              if (!existing) {
                rows(target.name as string).push({ source: 'manual', status: 'committed', note: null, draftRevision: null, ...row });
                continue;
              }
              if (!holds(setWhere, existing, row)) continue;
              for (const [column, value] of Object.entries(set)) {
                const expression = value as { op?: string; args?: [string[], unknown[]] };
                const excluded = expression?.op === 'sql' ? /^excluded\.(\w+)$/.exec((expression.args as [string[]])[0][0] ?? '') : null;
                if (expression?.op === 'sql' && !excluded) throw new Error('unsupported set expression');
                existing[column] = excluded ? row[camel(excluded[1] as string)] : value;
              }
            }
          }),
      }),
    }),
    delete: (target: Row) => ({
      where: (where: Condition) =>
        changing(() => {
          const all = rows(target.name as string);
          const removed = all.filter(row => holds(where, row));
          data[target.name as string] = all.filter(row => !removed.includes(row));
          return removed;
        }),
    }),
    update: (target: Row) => ({
      set: (values: Row) => ({
        where: (where: Condition) =>
          changing(() => {
            const changed = rows(target.name as string).filter(row => holds(where, row));
            for (const row of changed) Object.assign(row, Object.fromEntries(Object.entries(values).filter(([column]) => column !== 'updatedAt')));
            return changed;
          }),
      }),
    }),
  };
}

function createRng(seed: number) {
  let state = seed | 0;
  const next = (): number => {
    state = (state + 0x6d2b79f5) | 0;
    let t = Math.imul(state ^ (state >>> 15), 1 | state);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  const int = (min: number, max: number): number => min + Math.floor(next() * (max - min + 1));
  return {
    int,
    chance: (p: number): boolean => next() < p,
    pick: <T>(items: readonly T[]): T => items[Math.floor(next() * items.length)] as T,
    subset: <T>(items: readonly T[], p: number): T[] => items.filter(() => next() < p),
  };
}

const rng = createRng(0x0d21);

// Keys are NFC, as every stored key is; the reference compares them as they are.
const ENTITIES = ['mara', 'tobin', 'é_elias'];
const FACTS = ['heir', 'tide', 'bell', 'f_é'];
const MILESTONES = ['rise', 'fall', 'm_é'];
const CHAPTERS = 6;

// resetApprovalForPlanChange (draft-staleness.ts:30) on an approved chapter 2 and a draft of chapter 3: whether the approval resets and the later draft is marked.
interface Terms {
  pov: string[];
  learns: [string, string][];
  claims: string[] | null;
}

function terms(): Terms {
  const pov = rng.pick([['mara'], ['mara'], ['tobin', ''], [''], []]);
  const learns = Array.from({ length: rng.int(0, 3) }, (): [string, string] => [rng.pick(ENTITIES), rng.pick(FACTS)]);
  const claims = rng.chance(0.2) ? null : Array.from({ length: rng.int(0, 3) }, () => rng.pick(MILESTONES));
  return { pov, learns, claims };
}

function varied(base: Terms): Terms {
  switch (rng.int(0, 5)) {
    case 0:
      return base;
    case 1:
      return { ...base, learns: [...base.learns].reverse(), claims: base.claims && [...base.claims].reverse() };
    case 2:
      return { ...base, learns: [...base.learns, ...base.learns.slice(0, 1)], claims: base.claims && [...base.claims, ...base.claims.slice(0, 1)] };
    case 3:
      return { ...base, claims: rng.chance(0.5) ? [rng.pick(MILESTONES)] : [] };
    case 4:
      return { ...base, learns: [[rng.pick(ENTITIES), rng.pick(FACTS)]] };
    default:
      return terms();
  }
}

const planTerms = (value: Terms) => ({
  knowledgeContract: { pov: value.pov, learns: value.learns.map(([entityKey, factKey]) => ({ entityKey, factKey })) },
  claimedMilestones: value.claims,
});

const termCases: unknown[] = [];
for (let index = 0; index < 400; index++) {
  const before = rng.chance(0.1) ? null : terms();
  const after = before && rng.chance(0.8) ? varied(before) : terms();
  const data: Record<string, Row[]> = {
    drafts: [
      { projectId: 1n, chapter: 2, status: 'draft', reviewStatus: 'approved', staleReason: null },
      { projectId: 1n, chapter: 3, status: 'draft', reviewStatus: 'needs_review', staleReason: null },
    ],
    characterKnowledge: [],
    characterEvents: [],
  };
  await staleness.resetApprovalForPlanChange(fakeDb(data), 1n, 2, before ? planTerms(before) : undefined, planTerms(after));
  const [approved, later] = data.drafts as [Row, Row];
  termCases.push({ before, after, reset: approved.reviewStatus !== 'approved', marked: later.staleReason !== null });
}

// The ledger after random approvals, draft changes, in-order finalizes and manual reveals, through the reference's own writers; retractions come last, as
// a retraction followed by a later approval is where the derived ledger deliberately differs.
interface Fact {
  fact: string;
  revealChapter: number | null;
  unlock: { chapter: number }[] | null;
  source: string;
}

const ledgerCases: unknown[] = [];
for (let index = 0; index < 120; index++) {
  const facts: Fact[] = rng.subset(FACTS, 0.8).map(fact => ({
    fact,
    revealChapter: rng.chance(0.15) ? null : rng.pick([1, 1, 1, 2, 3, 5]),
    unlock: rng.chance(0.25) ? [{ chapter: rng.pick([1, 2, 4]) }] : null,
    source: rng.pick(['manual', 'manual', 'brief', 'seed']),
  }));
  const entities = rng.subset(ENTITIES, 0.8);
  const plans = Array.from({ length: CHAPTERS }, (_, offset) => ({
    chapter: offset + 1,
    pov: rng.chance(0.9) ? ['mara'] : [''],
    learns: Array.from({ length: rng.int(0, 3) }, (): [string, string] => [rng.pick([...ENTITIES, 'ghost']), rng.pick([...FACTS, 'ghost'])]),
  }));
  const data: Record<string, Row[]> = {
    projects: [{ id: 1n, storyCurrentChapter: 0 }],
    chapters: [],
    briefs: plans.map((plan, offset) => ({
      id: BigInt(offset + 1),
      projectId: 1n,
      chapter: plan.chapter,
      volumeKey: null,
      isEnding: false,
      claimedMilestones: [],
      knowledgeContract: { pov: plan.pov, learns: plan.learns.map(([entityKey, factKey]) => ({ entityKey, factKey })) },
      staleReason: null,
    })),
    milestones: [],
    volumes: [],
    canonFacts: facts.map((fact, offset) => ({
      id: BigInt(offset + 1),
      projectId: 1n,
      factKey: fact.fact,
      revealChapter: fact.revealChapter,
      unlock: fact.unlock && { all: fact.unlock },
      source: fact.source,
      plannedChapter: null,
    })),
    entities: entities.map((entityKey, offset) => ({ id: BigInt(offset + 101), projectId: 1n, entityKey, name: entityKey })),
    characterKnowledge: [],
    characterEvents: [],
    drafts: plans.map(plan => ({ projectId: 1n, chapter: plan.chapter, revision: 1, status: 'draft', reviewStatus: 'needs_review', staleReason: null })),
  };
  const db = fakeDb(data);
  const draft = (chapter: number): Row => (data.drafts as Row[]).find(row => row.chapter === chapter) as Row;
  const factId = (key: string) => (data.canonFacts as Row[]).find(row => row.factKey === key)?.id;
  const entityId = (key: string) => (data.entities as Row[]).find(row => row.entityKey === key)?.id;
  const revealed = new Map<string, [string, string]>();
  const events: unknown[] = [];
  for (let step = rng.int(6, 20); step > 0; step--) {
    const roll = rng.int(0, 12);
    const chapter = rng.int(1, CHAPTERS);
    const row = draft(chapter);
    if (roll <= 4) {
      if (row.status === 'final' || row.reviewStatus === 'approved' || row.staleReason !== null) continue;
      if (await planState.planRevealsRefusal(db, 1n, chapter)) continue;
      row.revision = (row.revision as number) + 1;
      row.reviewStatus = 'approved';
      await provisional.ledgerBriefReveals(db, 1n, chapter, row.revision);
      events.push(['approve', chapter]);
    } else if (roll <= 6) {
      if (row.status === 'final') continue;
      Object.assign(row, { revision: (row.revision as number) + 1, reviewStatus: 'needs_review', staleReason: null });
      await staleness.markDescendantDraftsStale(db, 1n, chapter, `ancestor chapter ${chapter} was revised`);
      await provisional.revokeProvisionalReveals(db, 1n, chapter);
      events.push(['revise', chapter]);
    } else if (roll <= 10) {
      const next = (data.drafts as Row[]).filter(candidate => candidate.status !== 'final').map(candidate => candidate.chapter as number).sort((a, b) => a - b)[0];
      if (next === undefined || draft(next).reviewStatus !== 'approved') continue;
      await provisional.commitChapterKnowledge(db, 1n, next, draft(next).revision);
      Object.assign(draft(next), { status: 'final', reviewStatus: 'final' });
      (data.projects as Row[])[0]!.storyCurrentChapter = next;
      (data.chapters as Row[]).push({ projectId: 1n, number: next, status: 'done' });
      events.push(['finalize', next]);
    } else {
      const [fact, entity] = [rng.pick(facts.map(candidate => candidate.fact)), rng.pick(entities)];
      if (fact === undefined || entity === undefined || !rng.chance(0.4)) continue;
      await db
        .insert(table('characterKnowledge') as Row)
        .values([{ projectId: 1n, factId: factId(fact), entityId: entityId(entity), learnedInChapter: chapter, source: 'manual', note: null }])
        .onConflictDoUpdate({
          target: [{ column: 'factId' }, { column: 'entityId' }],
          set: { learnedInChapter: chapter, source: 'manual', note: null, status: 'committed', draftRevision: null },
        });
      revealed.set(`${fact}\u0000${entity}`, [fact, entity]);
      events.push(['reveal', fact, entity, chapter]);
    }
  }
  const manual = (data.characterKnowledge as Row[]).filter(row => row.source === 'manual');
  const keyOf = (row: Row): [string, string] => [
    (data.canonFacts as Row[]).find(fact => fact.id === row.factId)?.factKey as string,
    (data.entities as Row[]).find(entity => entity.id === row.entityId)?.entityKey as string,
  ];
  const retracted = [...revealed.values()].filter(() => rng.chance(0.3));
  for (const [fact, entity] of retracted) {
    data.characterKnowledge = (data.characterKnowledge as Row[]).filter(row => !(row.factId === factId(fact) && row.entityId === entityId(entity)));
    events.push(['retract', fact, entity]);
  }
  ledgerCases.push({
    facts,
    entities,
    plans,
    events,
    finals: (data.drafts as Row[]).filter(row => row.status === 'final').map(row => row.chapter),
    approved: (data.drafts as Row[]).filter(row => row.status !== 'final' && row.reviewStatus === 'approved').map(row => row.chapter),
    manual: manual.map(row => [...keyOf(row), row.learnedInChapter]),
    retracted,
    expected: (data.characterKnowledge as Row[]).map(row => [...keyOf(row), row.learnedInChapter, row.source, row.status]),
  });
}

writeFileSync(join(outDir, 'staleness.json'), `${JSON.stringify({ termCases, ledgerCases })}\n`);
