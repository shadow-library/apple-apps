import { plugin } from 'bun';
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');

const src = join(platformRepo, 'apps/novel-forge-server/src');
const outDir = dirname(fileURLToPath(import.meta.url));

const contentHash = await import(join(src, 'common/content-hash.ts'));
const briefScenes = await import(join(src, 'common/brief-scenes.ts'));
const unlockCondition = await import(join(src, 'common/unlock-condition.ts'));
const classes = await import(join(src, 'classes/app-error-code.ts'));

interface Predicate {
  (row: Record<string, unknown>): boolean;
}

const column = (table: string, name: string) => ({ table, name });
const schemaStub = new Proxy({}, { get: (_, table: string) => new Proxy({}, { get: (__, name: string) => column(table, name) }) });

plugin({
  name: 'artifact-state-stubs',
  setup(build) {
    build.module('drizzle-orm', () => ({
      exports: {
        eq: (col: { name: string }, value: unknown): Predicate => row => row[col.name] === value,
        inArray: (col: { name: string }, values: unknown[]): Predicate => row => values.includes(row[col.name]),
        and:
          (...predicates: Predicate[]): Predicate =>
          row =>
            predicates.every(predicate => predicate(row)),
      },
      loader: 'object',
    }));
    build.module('@server/database', () => ({ exports: { schema: schemaStub }, loader: 'object' }));
    build.module('@server/classes', () => ({ exports: { AppErrorCode: classes.AppErrorCode }, loader: 'object' }));
    build.module('@server/common', () => ({
      exports: {
        computeContentHash: contentHash.computeContentHash,
        validateBriefScenes: briefScenes.validateBriefScenes,
        validateUnlockCondition: unlockCondition.validateUnlockCondition,
      },
      loader: 'object',
    }));
  },
});

const artifactState = await import(join(src, 'modules/refinement/artifact-state.ts'));
const proposalCurrent = await import(join(src, 'modules/refinement/proposal-current.ts'));
const changeSet = await import(join(src, 'modules/refinement/change-set/index.ts'));
const opSpecs = await import(join(src, 'modules/refinement/change-set/op-specs.ts'));

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

type Row = Record<string, unknown>;
type Tables = Record<string, Row[]>;

const PROJECT = 1n;
const SECTIONS = ['project', 'world', 'power', 'plot', 'story_state', 'ai', 'lore'];
const HOOKS = ['cliffhanger', 'revelation', 'quiet_dread', 'promise', 'turn', 'closure_with_momentum', 'earned_rest'];
const WORDS = ['tower', 'lantern', 'marsh', 'oath', 'queen', 'glass', 'harbour', 'ember', 'salt', 'crown', '42', 'x', ''];
const FRAGMENTS = [
  'café',
  'café',
  '😀',
  '𠮷野家',
  '王国',
  'ﬁre',
  'line\nbreak',
  'crlf\r\nbreak',
  'tab\there',
  'quote "inner"',
  "it's",
  'back\\slash',
  ' sep',
  ' nbsp',
  '  padded  ',
  '<tag>&amp;',
  'ÅΩ',
  '​zero',
];

const sentence = (rng: Rng): string => {
  const parts = Array.from({ length: rng.int(1, 4) }, () => (rng.chance(0.35) ? rng.pick(FRAGMENTS) : rng.pick(WORDS)));
  return parts.join(' ');
};
const maybe = <T>(rng: Rng, p: number, make: () => T): T | null => (rng.chance(p) ? make() : null);
const strings = (rng: Rng, min = 1): string[] => Array.from({ length: rng.int(min, 3) }, () => sentence(rng) || 'w');
const keyPool = ['a', 'b', 'harbour', 'lamp_1', 'ember', 'é', '😀', 'k:colon', 'x/slash', 'x.y', 'mara'];
const key = (rng: Rng): string => rng.pick(keyPool);
const uniqueKeys = (rng: Rng, max: number): string[] => [...new Set(Array.from({ length: rng.int(0, max) }, () => key(rng)))];

function frontmatter(rng: Rng, depth = 0): Record<string, unknown> {
  const names = [...new Set(Array.from({ length: rng.int(0, 4) }, () => rng.pick(['title', 'status', 'tags', 'meta', 'a', 'B', '10', '2', 'é', '😀'])))];
  const entries = names.map(name => {
    const value = rng.pick<unknown>([sentence(rng), rng.int(0, 9), rng.chance(0.5), null, strings(rng), depth < 2 ? frontmatter(rng, depth + 1) : 'leaf']);
    return [name, value] as const;
  });
  const codeUnitOrder = entries.sort(([left], [right]) => (left < right ? -1 : left > right ? 1 : 0));
  return Object.fromEntries(codeUnitOrder);
}

function buildTables(rng: Rng): Tables {
  const tables: Tables = { projects: [], bibleDocuments: [], volumes: [], briefs: [], drafts: [], entities: [], canonFacts: [], milestones: [], plotThreads: [], mysteries: [] };

  if (rng.chance(0.9)) {
    tables['projects']!.push({
      id: PROJECT,
      premise: maybe(rng, 0.7, () => sentence(rng)),
      brief: maybe(rng, 0.5, () => sentence(rng)),
      themes: maybe(rng, 0.5, () => strings(rng)),
      instructions: maybe(rng, 0.4, () => sentence(rng)),
      theme: maybe(rng, 0.5, () => sentence(rng)),
      readerPromise: maybe(rng, 0.4, () => sentence(rng)),
      protagonistKey: maybe(rng, 0.4, () => key(rng)),
      opposition: maybe(rng, 0.4, () => sentence(rng)),
      endingQuestion: maybe(rng, 0.4, () => sentence(rng)),
      ending: maybe(rng, 0.3, () => sentence(rng)),
    });
  }

  const docKeys = new Set<string>();
  for (let index = 0; index < rng.int(0, 3); index++) {
    const section = rng.pick(SECTIONS);
    const slug = rng.pick(['premise', 'cast', 'a/b', 'é', '😀', 'notes/deep/er', 'x']);
    if (docKeys.has(`${section}/${slug}`)) continue;
    docKeys.add(`${section}/${slug}`);
    const fm = maybe(rng, 0.6, () => frontmatter(rng));
    const body = maybe(rng, 0.8, () => sentence(rng));
    tables['bibleDocuments']!.push({ projectId: PROJECT, section, slug, revision: rng.int(1, 9), contentHash: contentHash.computeBibleDocHash(fm, body), frontmatter: fm, body });
  }

  const volumeCount = rng.int(0, 4);
  const goalMet = volumeCount === 0 ? 0 : rng.int(0, volumeCount);
  const volumeKeys = uniqueKeys(rng, 4).slice(0, volumeCount);
  volumeKeys.forEach((volumeKey, index) => {
    const state = index < Math.min(goalMet, volumeKeys.length) ? 'goal_met' : index === Math.min(goalMet, volumeKeys.length) ? 'active' : 'not_started';
    const row = { projectId: PROJECT, volumeKey, ordinal: index * 3 + rng.int(1, 3), title: maybe(rng, 0.8, () => sentence(rng)), objective: maybe(rng, 0.6, () => sentence(rng)), body: maybe(rng, 0.5, () => sentence(rng)), state, revision: rng.int(1, 9) };
    tables['volumes']!.push({ ...row, contentHash: contentHash.volumeContentHash(row) });
  });

  for (const chapter of new Set(Array.from({ length: rng.int(0, 3) }, () => rng.int(1, 6)))) {
    const withKnowledge = rng.chance(0.5);
    const scenes = maybe(rng, 0.4, () =>
      Array.from({ length: rng.int(1, 3) }, () => {
        const scene: Row = { summary: sentence(rng) || 's', pov: maybe(rng, 0.5, () => key(rng)) };
        if (rng.chance(0.4)) scene['goal'] = sentence(rng);
        if (rng.chance(0.3)) scene['obstacle'] = sentence(rng);
        if (rng.chance(0.3)) scene['turn'] = sentence(rng);
        if (rng.chance(0.3)) scene['beats'] = strings(rng);
        if (rng.chance(0.3)) scene['estimatedWords'] = rng.int(50, 900);
        return scene;
      }),
    );
    const claimed = maybe(rng, 0.4, () => uniqueKeys(rng, 3).concat(['m1']));
    const row: Row = {
      projectId: PROJECT,
      chapter,
      revision: rng.int(1, 9),
      volumeKey: maybe(rng, 0.5, () => key(rng)),
      title: maybe(rng, 0.7, () => sentence(rng)),
      body: sentence(rng),
      contextRefs: maybe(rng, 0.4, () => strings(rng)),
      pov: maybe(rng, 0.6, () => key(rng)),
      endingContract: maybe(rng, 0.4, () => {
        const contract: Row = { hookType: rng.pick(HOOKS), emotionalBeat: sentence(rng), openQuestion: sentence(rng), handoffState: sentence(rng) };
        if (rng.chance(0.5)) contract['mustNotResolve'] = strings(rng);
        return contract;
      }),
      knowledgeContract: withKnowledge
        ? (() => {
            const contract: Row = { pov: uniqueKeys(rng, 2).concat(['mara']) };
            if (rng.chance(0.6)) contract['learns'] = [{ entityKey: key(rng), factKey: key(rng) }];
            return contract;
          })()
        : null,
      chapterPurpose: maybe(rng, 0.5, () => sentence(rng)),
      readerValue: maybe(rng, 0.3, () => strings(rng)),
      repetitionRisks: maybe(rng, 0.3, () => strings(rng)),
      guidance: maybe(rng, 0.4, () => sentence(rng)),
      direction: maybe(rng, 0.4, () => sentence(rng)),
      contentMode: maybe(rng, 0.3, () => rng.pick(['standard', 'unrestricted'])),
      scenes,
      claimedMilestones: claimed,
      isEnding: rng.chance(0.2),
    };
    tables['briefs']!.push({ ...row, contentHash: contentHash.briefContentHash(row) });
  }

  for (const chapter of new Set(Array.from({ length: rng.int(0, 3) }, () => rng.int(1, 6)))) {
    tables['drafts']!.push({ projectId: PROJECT, chapter, revision: rng.int(1, 9), title: maybe(rng, 0.7, () => sentence(rng)), body: sentence(rng), summary: maybe(rng, 0.5, () => sentence(rng)) });
  }

  for (const entityKey of uniqueKeys(rng, 3)) {
    tables['entities']!.push({
      projectId: PROJECT,
      entityKey,
      name: sentence(rng) || 'n',
      type: rng.pick(opSpecs.ENTITY_TYPES),
      status: maybe(rng, 0.5, () => sentence(rng)),
      motivation: maybe(rng, 0.5, () => sentence(rng)),
      notes: maybe(rng, 0.5, () => sentence(rng)),
      body: maybe(rng, 0.5, () => sentence(rng)),
    });
  }

  for (const factKey of uniqueKeys(rng, 3)) {
    tables['canonFacts']!.push({
      projectId: PROJECT,
      factKey,
      text: sentence(rng) || 't',
      subjects: maybe(rng, 0.5, () => strings(rng)),
      constraintNote: maybe(rng, 0.4, () => sentence(rng)),
      writerNote: maybe(rng, 0.4, () => sentence(rng)),
      terms: maybe(rng, 0.4, () => strings(rng)),
      revealChapter: maybe(rng, 0.4, () => rng.int(1, 20)),
      unlock: maybe(rng, 0.3, () => ({ all: [{ milestone: key(rng) }] })),
      allowedClues: maybe(rng, 0.3, () => strings(rng)),
    });
  }

  for (const milestoneKey of uniqueKeys(rng, 3)) {
    tables['milestones']!.push({ projectId: PROJECT, milestoneKey, label: sentence(rng) || 'l', subjectEntityKey: maybe(rng, 0.5, () => key(rng)), kind: rng.pick(opSpecs.MILESTONE_KINDS) });
  }

  for (const threadKey of uniqueKeys(rng, 3)) {
    const status = rng.pick(['open', 'closed', 'dropped']);
    tables['plotThreads']!.push({
      projectId: PROJECT,
      threadKey,
      summary: maybe(rng, 0.8, () => sentence(rng) || 's'),
      status,
      closedChapter: status === 'closed' ? rng.int(1, 9) : null,
      lastAdvancedChapter: null,
      payoffWindow: maybe(rng, 0.3, () => rng.int(1, 30)),
      payoffMilestoneKey: maybe(rng, 0.3, () => key(rng)),
      payoffVolumeKey: maybe(rng, 0.3, () => key(rng)),
      intentionallyOpen: rng.chance(0.2),
    });
  }

  for (const mysteryKey of uniqueKeys(rng, 3)) {
    const status = rng.pick(['open', 'resolved', 'dropped']);
    tables['mysteries']!.push({
      projectId: PROJECT,
      mysteryKey,
      question: sentence(rng) || 'q',
      status,
      resolvedChapter: status === 'resolved' ? rng.int(1, 9) : null,
      lastAdvancedChapter: null,
      payoffWindow: maybe(rng, 0.3, () => rng.int(1, 30)),
      payoffMilestoneKey: maybe(rng, 0.3, () => key(rng)),
      payoffVolumeKey: maybe(rng, 0.3, () => key(rng)),
      intentionallyOpen: rng.chance(0.2),
    });
  }

  return tables;
}

function fakeDatabase(tables: Tables): unknown {
  const select = (row: Row, columns?: Record<string, boolean>): Row => (columns ? Object.fromEntries(Object.keys(columns).map(name => [name, row[name]])) : { ...row });
  const query = (name: string) => ({
    findFirst: async (args: { columns?: Record<string, boolean>; where: Predicate }) => {
      const row = (tables[name] ?? []).find(args.where);
      return row ? select(row, args.columns) : undefined;
    },
    findMany: async (args: { columns?: Record<string, boolean>; where: Predicate }) => (tables[name] ?? []).filter(args.where).map(row => select(row, args.columns)),
  });
  return { query: Object.fromEntries(Object.keys(tables).map(name => [name, query(name)])) };
}

function refsFor(rng: Rng, tables: Tables): string[] {
  const existing = [
    ...(tables['projects']!.length > 0 ? ['premise'] : []),
    ...tables['bibleDocuments']!.map(row => `doc:${row['section']}/${row['slug']}`),
    ...tables['volumes']!.map(row => `volume:${row['volumeKey']}`),
    ...tables['briefs']!.map(row => `chapter:${row['chapter']}`),
    ...tables['drafts']!.map(row => `draft:${row['chapter']}`),
    ...tables['entities']!.map(row => `entity:${row['entityKey']}`),
    ...tables['canonFacts']!.map(row => `fact:${row['factKey']}`),
    ...tables['milestones']!.map(row => `milestone:${row['milestoneKey']}`),
    ...tables['plotThreads']!.map(row => `promise:thread:${row['threadKey']}`),
    ...tables['mysteries']!.map(row => `promise:mystery:${row['mysteryKey']}`),
  ];
  const absent = [
    'premise',
    `doc:${rng.pick(SECTIONS)}/${rng.pick(['zzz', 'a/b', 'cast'])}`,
    'doc:world',
    'doc:nosuch/section',
    'doc:',
    'volume:ghost',
    'volume:',
    'chapter:9',
    'chapter:abc',
    'chapter:01',
    'chapter: 2',
    'chapter:1.5',
    'chapter:-1',
    'chapter:',
    'chapter:1e0',
    'draft:8',
    'draft:0',
    'draft:x',
    'entity:ghost',
    'fact:ghost',
    'milestone:ghost',
    'promise:thread:ghost',
    'promise:mystery:ghost',
    'promise:other:a',
    'promise:thread',
    'promise:',
    'nothing',
    '',
    'DOC:world/a',
    'entity:mara',
    'promise:thread:k:colon',
  ];
  const picked = [...Array.from({ length: rng.int(0, existing.length) }, () => rng.pick(existing)), ...Array.from({ length: rng.int(1, 5) }, () => rng.pick(absent))];
  const refs = rng.chance(0.25) ? picked.concat(picked.slice(0, 2)) : picked;
  return refs.length === 0 ? ['premise'] : refs;
}

function opsFor(rng: Rng, refs: string[]): unknown[] {
  const keyOf = (prefix: string): string => {
    const matches = refs.filter(ref => ref.startsWith(prefix));
    return matches.length > 0 && rng.chance(0.7) ? rng.pick(matches).slice(prefix.length) : rng.pick(['ghost', 'a', 'b', 'harbour', 'é', 'mara']);
  };
  const meta = (): Row => {
    const extra: Row = {};
    if (rng.chance(0.3)) extra['rationale'] = sentence(rng) || 'why';
    if (rng.chance(0.2)) extra['quote'] = sentence(rng) || 'q';
    if (rng.chance(0.1)) extra['startedEmpty'] = rng.chance(0.5);
    if (rng.chance(0.2)) extra['ideaId'] = 'idea-1';
    return extra;
  };
  const some = (candidates: [string, () => unknown][]): Row => {
    const chosen: Row = {};
    for (const [name, make] of candidates) if (rng.chance(0.55)) chosen[name] = make();
    return chosen;
  };
  const spaceless = (value: string): string => value.replace(/\s+/g, '_') || 'k';
  const builders: (() => Row)[] = [
    () => ({ op: 'premise.update', ...some([['premise', () => sentence(rng)], ['brief', () => sentence(rng)], ['themes', () => strings(rng)], ['instructions', () => sentence(rng)], ['theme', () => sentence(rng)], ['readerPromise', () => sentence(rng)], ['protagonistKey', () => key(rng)], ['opposition', () => sentence(rng)], ['endingQuestion', () => sentence(rng)], ['ending', () => sentence(rng)]]), ...meta() }),
    () => ({ op: 'bible_document.upsert', section: rng.pick(SECTIONS), slug: rng.pick(['premise', 'cast', 'a/b', 'é']), ...some([['frontmatter', () => frontmatter(rng)], ['body', () => sentence(rng)]]), ...meta() }),
    () => ({ op: 'entity.upsert', entityKey: spaceless(keyOf('entity:')), type: rng.pick(opSpecs.ENTITY_TYPES), ...some([['name', () => sentence(rng)], ['status', () => sentence(rng)], ['motivation', () => sentence(rng)], ['notes', () => sentence(rng)], ['body', () => sentence(rng)]]), ...meta() }),
    () => ({ op: 'fact.upsert', factKey: spaceless(keyOf('fact:')), ...some([['body', () => sentence(rng)], ['subjects', () => strings(rng)], ['constraintNote', () => sentence(rng)], ['writerNote', () => sentence(rng)], ['terms', () => strings(rng)], ['revealChapter', () => rng.int(1, 9)], ['allowedClues', () => strings(rng)]]), ...meta() }),
    () => ({ op: 'volume.upsert', volumeKey: spaceless(keyOf('volume:')), ...some([['ordinal', () => rng.int(1, 9)], ['title', () => sentence(rng)], ['objective', () => sentence(rng)], ['body', () => sentence(rng)], ['state', () => rng.pick(['active', 'not_started', 'goal_met'])]]), ...meta() }),
    () => ({ op: 'milestone.upsert', milestoneKey: spaceless(keyOf('milestone:')), ...some([['label', () => sentence(rng) || 'l'], ['subjectEntityKey', () => (rng.chance(0.3) ? null : key(rng))], ['kind', () => rng.pick(opSpecs.MILESTONE_KINDS)]]), ...meta() }),
    () => {
      const kind = rng.pick(['thread', 'mystery']);
      return { op: 'promise.create', kind, key: spaceless(keyOf(`promise:${kind}:`)), label: sentence(rng) || 'l', ...some([['openedChapter', () => rng.int(1, 9)]]), ...meta() };
    },
    () => {
      const kind = rng.pick(['thread', 'mystery']);
      return { op: 'promise.update', kind, key: spaceless(keyOf(`promise:${kind}:`)), ...some([['label', () => sentence(rng) || 'l'], ['lastAdvancedChapter', () => rng.int(1, 9)], ['status', () => rng.pick(opSpecs.PROMISE_STATUSES)]]), ...meta() };
    },
    () => ({ op: 'brief.update', chapter: rng.int(1, 6), ...some([['title', () => sentence(rng)], ['body', () => sentence(rng)]]) }),
    () => ({ op: 'entity.remove', entityKey: spaceless(keyOf('entity:')) }),
    () => ({ op: 'promise.set_payoff', kind: 'thread', key: spaceless(keyOf('promise:thread:')), someday: true }),
  ];
  const ops: Row[] = [];
  for (let attempt = 0; ops.length < rng.int(1, 5) && attempt < 30; attempt++) {
    const candidate = rng.pick(builders)();
    const trial = JSON.parse(JSON.stringify([...ops, candidate]));
    if ((changeSet.validateChangeSet(trial, undefined, { entityMaterialization: false }) as string[]).length === 0) ops.push(candidate);
  }
  return ops;
}

const worlds: unknown[] = [];
for (let index = 0; index < 110; index++) {
  const rng = createRng(90000 + index);
  const tables = buildTables(rng);
  const refs = refsFor(rng, tables);
  const database = fakeDatabase(tables);
  const states = await artifactState.loadArtifactStates(database, PROJECT, refs);
  const records = await artifactState.loadCurrentRecords(database, PROJECT, refs);
  const ops = opsFor(rng, refs);
  const parsed = ops.length > 0 ? JSON.parse(JSON.stringify(ops)) : [];
  const currents = parsed.length > 0 ? (changeSet.validateChangeSet(parsed, undefined, { entityMaterialization: false }), proposalCurrent.proposalCurrent(parsed, await artifactState.loadCurrentRecords(database, PROJECT, proposalCurrent.currentRefs(parsed)))) : [];
  const statelessVolumeHash = Object.fromEntries(
    tables['volumes']!.map(row => [`volume:${row['volumeKey']}`, contentHash.volumeContentHash({ ...row, state: 'not_started' })]),
  );
  const unique = [...new Set(refs)];
  worlds.push({
    tables: Object.fromEntries(Object.entries(tables).map(([name, rows]) => [name, rows.map(row => Object.fromEntries(Object.entries(row).filter(([field]) => field !== 'projectId' && field !== 'id' && field !== 'revision' && field !== 'contentHash')))])),
    refs,
    states: unique.map(ref => [ref, states[ref].exists, states[ref].contentHash]),
    statelessVolumeHash,
    current: unique.filter(ref => records.has(ref)).map(ref => [ref, records.get(ref)]),
    currentRefs: parsed.length > 0 ? proposalCurrent.currentRefs(parsed) : [],
    changeSet: JSON.stringify(parsed),
    proposalCurrent: currents,
  });
}

writeFileSync(join(outDir, 'worlds.json'), JSON.stringify({ worlds }) + '\n');
console.log(`worlds ${worlds.length}`);
