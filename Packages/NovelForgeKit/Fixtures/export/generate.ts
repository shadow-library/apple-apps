import { plugin } from 'bun';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// Run as: PLATFORM_REPO=<checkout> bun --tsconfig-override "$PLATFORM_REPO/apps/novel-forge-server/tsconfig.json" generate.ts (the reference service uses legacy decorators)
const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');

const server = join(platformRepo, 'apps/novel-forge-server/src');
const outDir = dirname(fileURLToPath(import.meta.url));
const classes = await import(join(server, 'classes/app-error-code.ts'));

const schema = { chapters: { table: 'chapters', number: 'number', title: 'title', content: 'content', projectId: 'projectId' }, drafts: { table: 'drafts', chapter: 'chapter', title: 'title', body: 'body', projectId: 'projectId', status: 'status' }, projects: { id: 'id' }, entities: {}, entityImages: {}, chapterImages: {} };

plugin({
  name: 'export-fixture-stubs',
  setup(build) {
    build.module('@shadow-library/app', () => ({ exports: { Injectable: () => () => undefined }, loader: 'object' }));
    build.module('@shadow-library/common', () => ({ exports: { Logger: { getLogger: () => ({ info() {}, warn() {} }) } }, loader: 'object' }));
    build.module('@shadow-library/modules', () => ({ exports: { DatabaseService: class {}, StorageService: class {} }, loader: 'object' }));
    build.module('@server/classes', () => ({ exports: { AppErrorCode: classes.AppErrorCode }, loader: 'object' }));
    build.module('@server/constants', () => ({ exports: { APP_NAME: 'novel-forge-server' }, loader: 'object' }));
    build.module('@server/database', () => ({ exports: { schema }, loader: 'object' }));
    build.module('drizzle-orm', () => ({ exports: { and: (...parts: unknown[]) => parts, asc: (column: unknown) => column, eq: (column: unknown, value: unknown) => ({ column, value }), inArray: () => undefined }, loader: 'object' }));
  },
});

const { NovelPackageService } = await import(join(server, 'modules/export/novel-package.service.ts'));
const { unzipSync } = await import(join(platformRepo, 'apps/novel-forge-server/node_modules/fflate/esm/browser.js'));

const generationSource = readFileSync(join(server, 'modules/generation/generation.service.ts'), 'utf8');
const methodStart = generationSource.indexOf('  async getManuscript(');
const methodEnd = generationSource.indexOf('  async listJobs(');
if (methodStart < 0 || methodEnd < methodStart) throw new Error('getManuscript not found in generation.service.ts');
const transpiled = new Bun.Transpiler({ loader: 'ts' }).transformSync(`const Holder = class {\n${generationSource.slice(methodStart, methodEnd)}\n}; return Holder;`);
const Holder = new Function('and', 'asc', 'eq', 'schema', transpiled)((...parts: unknown[]) => parts, (column: unknown) => column, (column: unknown, value: unknown) => ({ column, value }), schema);

interface FinalChapter { number: number; title: string | null; content: string; amendment?: { title: string | null; content: string } }
interface DraftChapter { chapter: number; title: string | null; body: string; status: 'draft' | 'final' }
interface Novel { name: string; title: string | null; brief: string | null; premise: string | null; themes: unknown }
interface Case { name: string; novel: Novel; finals: FinalChapter[]; drafts: DraftChapter[] }

const NOVEL_ID = '6f1c2a3e-8b4d-4e5f-9a60-1b2c3d4e5f60';

function passage(index: number): string {
  const lines = [`The lamp on the quay burned low in the ${index}th hour.`, `Wren counted ${index * 3} steps to the harbour wall and back.`, `"Nothing keeps," she said, "that is not tended."`];
  return lines.slice(0, 1 + (index % 3)).join('\n\n');
}

const manyFinals: FinalChapter[] = Array.from({ length: 120 }, (_, i) => ({ number: i + 1, title: i % 7 === 0 ? null : `Chapter title ${i + 1}`, content: passage(i + 1) }));
manyFinals.push({ number: 10000, title: 'Tenth thousand', content: 'A chapter number past the pad width.' });
manyFinals.push({ number: 12345, title: null, content: 'Five digits.' });

const cases: Case[] = [
  { name: 'no chapters at all', novel: { name: 'Empty', title: null, brief: null, premise: null, themes: null }, finals: [], drafts: [] },
  {
    name: 'drafts stand in when nothing is final',
    novel: { name: 'Draft only', title: 'Draft Only', brief: 'A brief.', premise: null, themes: null },
    finals: [],
    drafts: [
      { chapter: 2, title: 'Second', body: 'Second body.', status: 'draft' },
      { chapter: 1, title: null, body: 'First body.', status: 'draft' },
      { chapter: 3, title: 'Blank', body: '   \n', status: 'draft' },
    ],
  },
  {
    name: 'amended chapters carry the amended text',
    novel: { name: 'Amended', title: 'Amended', brief: null, premise: 'A premise.', themes: ['sea'] },
    finals: [
      { number: 1, title: 'Canon title', content: 'Canon body.', amendment: { title: 'Amended title', content: 'Amended body.\n\nWith two paragraphs.' } },
      { number: 2, title: 'Kept', content: 'Untouched body.' },
    ],
    drafts: [{ chapter: 1, title: 'Draft one', body: 'Ignored draft.', status: 'draft' }],
  },
  {
    name: 'unicode titles and names',
    novel: { name: 'ignored', title: '  Crème Brûlée: Ünïcode — 日本語 Kelvin İstanbul  ', brief: '  Quoted "brief" with \\ slash / and\ttab\nnewline   separator  ', premise: 'unused', themes: ['mer', '', 'ünï', 'tag "quoted"'] },
    finals: [
      { number: 1, title: 'Ünïcödé ✦ 日本語 🌊', content: 'Café ☕ — naïve façade.\n日本語のテキスト。\n🌊🌊' },
      { number: 2, title: '  padded "title" \\ / \t ', content: 'Body with CRLF\r\nline and trailing space \n' },
      { number: 3, title: '', content: 'Empty title string.' },
      { number: 4, title: '   ', content: 'Blank title string.' },
    ],
    drafts: [],
  },
  {
    name: 'slug falls back and fields trim',
    novel: { name: '!!!', title: '   ', brief: '   ', premise: '  Premise wins.  ', themes: [] },
    finals: [
      { number: 5, title: null, content: 'Five.' },
      { number: 3, title: 'Three', content: 'Three.' },
      { number: 4, title: 'Skipped', content: ' \n\t ' },
    ],
    drafts: [],
  },
  { name: 'many chapters', novel: { name: 'Long Haul', title: 'The Long Haul', brief: 'Many chapters.', premise: null, themes: ['one', 'two'] }, finals: manyFinals, drafts: [] },
];

function effective(chapter: FinalChapter) {
  return { title: chapter.amendment ? chapter.amendment.title : chapter.title, content: chapter.amendment?.content ?? chapter.content };
}

function fakeDb(entry: Case) {
  const chapters = entry.finals.map(c => ({ number: c.number, ...effective(c) })).sort((a, b) => a.number - b.number);
  const drafts = [
    ...entry.finals.map(c => ({ chapter: c.number, title: effective(c).title, body: effective(c).content, status: 'final' })),
    ...entry.drafts.filter(d => !entry.finals.some(c => c.number === d.chapter)),
  ].sort((a, b) => a.chapter - b.chapter);
  const project = { id: NOVEL_ID, name: entry.novel.name, title: entry.novel.title, brief: entry.novel.brief, premise: entry.novel.premise, themes: entry.novel.themes, coverImagePath: null };
  return {
    query: {
      projects: { findFirst: async () => project },
      entities: { findMany: async () => [] },
      drafts: { findMany: async () => drafts.filter(d => d.status === 'final').map(d => ({ chapter: d.chapter, title: d.title, body: d.body })) },
    },
    select: () => ({
      from: (table: { table: string }) => ({
        where: () => ({
          orderBy: async () =>
            table.table === 'chapters' ? chapters : table.table === 'drafts' ? drafts.map(d => ({ number: d.chapter, title: d.title, content: d.body })) : [],
        }),
      }),
    }),
  };
}

async function run(entry: Case) {
  const db = fakeDb(entry);
  const manuscript = (await new Holder().getManuscript.call({ db }, NOVEL_ID)).markdown;
  const service = new NovelPackageService({ getPostgresClient: () => db }, {});
  try {
    const built = await service.build(NOVEL_ID);
    const files = unzipSync(built.bytes) as Record<string, Uint8Array>;
    const decoder = new TextDecoder();
    const names = Object.keys(files);
    const manifest = decoder.decode(files['manifest.json']);
    return {
      manuscript,
      package: { id: built.id, filename: built.filename, chapterCount: built.chapterCount, manifest, files: names.map(name => ({ name, text: decoder.decode(files[name]) })) },
    };
  } catch (error) {
    return { manuscript, package: { error: (error as { code?: string }).code ?? String(error) } };
  }
}

const results = [];
for (const entry of cases) {
  results.push({ name: entry.name, novel: { id: NOVEL_ID, ...entry.novel }, finals: entry.finals, drafts: entry.drafts, expected: await run(entry) });
}

writeFileSync(join(outDir, 'export.json'), JSON.stringify({ cases: results }, null, 1) + '\n');
