import { mock } from 'bun:test';
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');
const src = join(platformRepo, 'apps/novel-forge-server/src');
const outDir = dirname(fileURLToPath(import.meta.url));

mock.module('@server/common', () => ({ deriveBibleDocTitle: () => '' }));
mock.module('@server/database/schemas', () => ({}));
mock.module('@server/database', () => ({}));

const docs = await import(join(src, 'modules/ai/context/bible-docs.ts'));
const readiness = await import(join(src, 'modules/eval/bible-readiness.ts'));
const topics = await import(join(platformRepo, 'apps/novel-forge-web/src/lib/bible-topics.ts'));

interface Rng {
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
  return { int, chance: p => next() < p, pick: items => items[Math.floor(next() * items.length)] as never };
}

const units = (text: string): number[] => Array.from({ length: text.length }, (_, index) => text.charCodeAt(index));
const repeat = <T>(count: number, make: () => T): T[] => Array.from({ length: count }, make);

const HAND_EXCERPTS: [string, number][] = [
  ['# Title\n\n- The tide [rises](http://x) at **dusk**. Then it falls again, slowly, over the salt flats until morning comes.\n\nSecond paragraph.', 140],
  ['The tide rises at dusk. Then it falls again over the salt flats until morning comes and the keepers wake.', 40],
  ['Short. A much longer sentence follows here without any stop at all', 30],
  ['潮が満ちる、そして引く、また満ちる、終わりなく続く海の話です', 12],
  ['Averyveryveryverylongwordwithoutanyspacesatall', 10],
  ['A b. Ccccccccccccccccccc', 10],
  ['Mara — the keeper, waits; and then the bells ring out over the bay', 30],
  ['> quoted line\n1. item `code` here', 140],
  ['😀😀😀 tide rises over the', 10],
  ['これは長い文章です。そしてもっと長い文章が続きますがどこにも句読点はありません', 30],
  ['これは長い文章です。そしてもっと長い文章が続きますがどこにも句読点はありません', 14],
  ['潮が満ちる，そして引く；また満ちる：終わりなく続く海の話です', 12],
  ['Averyveryv😀rylongwordwithoutspaces', 11],
  ['Averyveryv😀rylongwordwithoutspaces', 12],
  ['He said "Stop." Then more words follow here and on and on', 30],
  ['Ten chars. and then the rest of the line continues', 20],
  ['Ten chars. and then the rest of the line continues', 21],
  ['Ten chars. and then the rest of the line continues', 19],
  ['Tide\u00a0rises\u2028over\ufeffthe\u3000flats and the sea', 15],
  ['# Head\r\n\r\nBody line one\r\nstill one\r\n\r\nTwo', 140],
  ['10) item one\n  * nested **bold** __under__\n>quote', 140],
  ['See [the [map]](http://a/(b)) now', 140],
  ['word, —– - ; then a lot more text continues past here', 8],
  ['、aaaaaaaaaaaaaaaaaaa', 5],
  ['', 140],
  ['# Only\n## Headings', 140],
  ['Wow! Really?! Yes.) And then more text keeps on going and going', 20],
  ['「終わり。」次の章が始まると、物語は続いていくのでした', 10],
  ['a.b.c.d.e.f.g.h.i.j.k.l.m', 10],
  ['One two three four five six', 27],
  ['One two three four five six', 26],
  ['e\u0301e\u0301e\u0301e\u0301e\u0301e\u0301 tail', 7],
  ['x 😀😀😀😀', 7],
];

const FRAGMENTS = [
  'tide', 'the keeper', 'ash', 'Mira', 'salt flats', 'é', 'e\u0301', '😀', '日本語', '物語', 'x', 'a b', "o'k", 'q"t', '(aside)', '[note]',
  '. ', '! ', '? ', '." ', ".' ", '.) ', '.] ', '。', '！', '？', '。」', '）', '，', '、', '；', '：', ', ', '; ', ': ', ' — ', ' – ', ' - ',
  ' ', '  ', '\t', '\u00a0', '\u2009', '\u3000', '\ufeff', '\u2028', '\n', '\r\n', '\n\n', '\n \n', '**', '__', '*', '`', '~~',
  '[link](http://x)', '![img](p.png)', '# ', '## ', '### x\n', '- ', '* ', '+ ', '1. ', '2) ', '> ', '>', '---\n',
];

function prose(rng: Rng): string {
  return repeat(rng.int(0, 24), () => rng.pick(FRAGMENTS)).join('');
}

const randomExcerpts: [string, number][] = (() => {
  const rng = createRng(0xb1b1e);
  return repeat(400, (): [string, number] => [prose(rng), rng.chance(0.2) ? 140 : rng.int(1, 40)]);
})();

const excerptCases = [...HAND_EXCERPTS, ...randomExcerpts];
const plainCases = (() => {
  const rng = createRng(0x9a1a);
  return repeat(150, () => prose(rng));
})();
const clipCases = (() => {
  const rng = createRng(0xc11b);
  return repeat(250, (): [string, number] => [prose(rng), rng.int(1, 40)]);
})();

interface Doc {
  section: string;
  slug: string;
  title: string;
  body: string;
}
interface Entity {
  key: string;
  type: string;
  significance?: string | null;
}
interface Volume {
  key: string;
  objective: string | null;
}
interface RoleCase {
  docs: Doc[];
  entities: Entity[];
  volumes: Volume[];
}

const HAND_ROLES: RoleCase[] = [
  {
    docs: [
      { section: 'world', slug: 'the-guilds', title: 'The Guilds', body: 'Text.' },
      { section: 'lore', slug: 'history-of-cities', title: 'History', body: 'Text.' },
      { section: 'project', slug: 'premise', title: 'Premise', body: '  ' },
      { section: 'project', slug: 'the-pitch', title: 'Pitch', body: 'P.' },
      { section: 'plot', slug: 'stories', title: 'Stories', body: 'S.' },
      { section: 'ai', slug: 'people', title: 'Roster', body: 'R.' },
      { section: 'story_state', slug: 'books', title: 'Books', body: 'B.' },
    ],
    entities: [{ key: 'a', type: 'faction' }, { key: 'b', type: 'character', significance: 'minor' }, { key: 'c', type: 'location' }],
    volumes: [{ key: 'v', objective: 'Win.' }, { key: 'w', objective: ' ' }],
  },
  {
    docs: [
      { section: 'world', slug: 'territory', title: 'Territory', body: 'T.' },
      { section: 'world', slug: 'setting-overview', title: 'Setting overview', body: 'S.' },
      { section: 'lore', slug: 'empty-cast', title: 'Cast', body: '' },
      { section: 'project', slug: 'outlines', title: 'Storylines', body: 'x' },
      { section: 'plot', slug: 'arcs', title: 'Arcs', body: 'x' },
      { section: 'story_state', slug: 'stories', title: 'Story', body: 'x' },
      { section: 'world', slug: 'territories', title: 'Lands', body: 'x' },
    ],
    entities: [],
    volumes: [],
  },
  {
    docs: [],
    entities: [
      { key: 'a', type: 'character', significance: 'minor' },
      { key: 'b', type: 'character' },
      { key: 'c', type: 'faction' },
      { key: 'd', type: 'faction' },
    ],
    volumes: [{ key: 'a', objective: 'A' }, { key: 'b', objective: 'B' }],
  },
  { docs: [], entities: [{ key: 'a', type: 'character', significance: 'minor' }, { key: 'c', type: 'location' }], volumes: [{ key: 'a', objective: null }] },
  {
    docs: [
      { section: 'world', slug: 'Characters-2', title: 'THE CAST', body: 'x' },
      { section: 'lore', slug: 'allies', title: 'Allies and Enemies', body: 'x' },
      { section: 'project', slug: 'cast', title: 'Cast', body: 'x' },
      { section: 'ai', slug: 'escalation-map', title: 'Odd', body: 'x' },
      { section: 'plot', slug: 'escalation-map', title: 'Odd', body: '\u00a0' },
      { section: 'story_state', slug: 'roadmap', title: 'Roadmaps', body: 'x' },
      { section: 'lore', slug: 'cästle-geographies', title: 'İstanbul Societies', body: 'x' },
      { section: 'power', slug: 'classes', title: 'Abilities', body: 'x' },
      { section: 'world', slug: 'factions-and-locations', title: 'x', body: 'x' },
      { section: 'lore', slug: 'factions-and-locations', title: 'x', body: 'x' },
    ],
    entities: [{ key: 'a', type: 'character', significance: 'major' }, { key: 'b', type: 'concept' }, { key: 'c', type: 'location' }],
    volumes: [{ key: 'v', objective: '\u3000' }, { key: 'w', objective: 'Go' }, { key: 'x', objective: null }],
  },
  {
    docs: [
      { section: 'plot', slug: 'heroes', title: 'Heroes', body: 'x' },
      { section: 'project', slug: 'people', title: 'People of the realm', body: 'x' },
      { section: 'lore', slug: 'rule-of-law', title: 'Rules', body: 'x' },
      { section: 'story_state', slug: 'books', title: 'The setting', body: 'x' },
      { section: 'world', slug: 'worlds', title: 'Worlds', body: 'x' },
    ],
    entities: [{ key: 'a', type: 'faction' }],
    volumes: [],
  },
];

const SECTIONS = ['project', 'world', 'power', 'plot', 'story_state', 'ai', 'lore'];
const WORDS = [
  'premise', 'pitch', 'hooks', 'synopsis', 'setting', 'worlds', 'overview', 'eras', 'history', 'societies', 'culture', 'cosmology', 'geographies', 'system', 'limits',
  'rules', 'laws', 'costs', 'ladder', 'ranks', 'tiers', 'levels', 'abilities', 'classes', 'skills', 'magic', 'powers', 'cultivation', 'factions', 'locations', 'places',
  'regions', 'nations', 'kingdoms', 'empires', 'cities', 'territories', 'organizations', 'organisation', 'guilds', 'politics', 'political', 'maps', 'travel', 'cast',
  'characters', 'protagonist', 'antagonists', 'roster', 'people', 'relationships', 'dramatis', 'escalation', 'plots', 'arcs', 'outlines', 'endgame', 'spine', 'stakes',
  'beats', 'structure', 'storylines', 'volumes', 'books', 'seasons', 'roadmap', 'family', 'tower', 'relic', 'war', 'author', 'notes', 'only', 'for', 'the', 'and',
  'İstanbul', 'cästle', 'Ünï', 'é', '日本', 'x', 'CAST', 'Map', 'Abilities',
];
const SEPARATORS = ['-', '_', ' ', '--', '.', ''];
const BODIES = ['x', 'Text.', '', ' ', '\n', '\u3000', 'Body\n'];
const ENTITY_TYPES = ['character', 'faction', 'location', 'power_rule', 'item', 'concept'];
const SIGNIFICANCES = [null, 'major', 'minor'];
const OBJECTIVES = [null, '', ' ', '\u3000', 'Win', 'Reach the coast'];

function phrase(rng: Rng): string {
  return repeat(rng.int(1, 3), () => rng.pick(WORDS)).join(rng.pick(SEPARATORS));
}

const randomRoles: RoleCase[] = (() => {
  const rng = createRng(0x501e5);
  return repeat(150, () => ({
    docs: repeat(rng.int(0, 8), () => ({ section: rng.pick(SECTIONS), slug: phrase(rng).toLowerCase(), title: phrase(rng), body: rng.pick(BODIES) })),
    entities: repeat(rng.int(0, 5), () => ({ key: phrase(rng), type: rng.pick(ENTITY_TYPES), significance: rng.pick(SIGNIFICANCES) })),
    volumes: repeat(rng.int(0, 3), () => ({ key: phrase(rng), objective: rng.pick(OBJECTIVES) })),
  }));
})();

const roleCases = [...HAND_ROLES, ...randomRoles].map(input => {
  const roles = readiness.bibleRoles({
    docs: input.docs,
    entities: input.entities.map(entity => ({ entityKey: entity.key, type: entity.type, significance: entity.significance ?? null })),
    facts: [],
    volumes: input.volumes.map(volume => ({ volumeKey: volume.key, objective: volume.objective })),
  });
  const stages = topics.stagesByDocument(roles);
  return {
    input,
    roles: roles.map((role: { stage: string; label: string; address: string; coveredBy: string[] }) => [role.stage, role.label, role.address, role.coveredBy]),
    topics: input.docs.map(doc => [topics.documentTopic(doc), topics.documentTopic(doc, stages)]),
  };
});

const doc = (body: string) => ({ section: 'world', slug: 'x', frontmatter: null, body });
writeFileSync(
  join(outDir, 'cases.json'),
  JSON.stringify({
    excerpts: excerptCases.map(([body, limit]) => [body, limit, units(docs.bibleDocExcerpt(doc(body), limit))]),
    plainText: plainCases.map(body => [body, units(docs.plainText(body))]),
    clip: clipCases.map(([text, limit]) => [text, limit, units(docs.clipAtBoundary(text, limit))]),
    roles: roleCases,
  }) + '\n',
);
process.exit(0);
