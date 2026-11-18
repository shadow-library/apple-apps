import { plugin } from 'bun';
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');

const server = join(platformRepo, 'apps/novel-forge-server/src');
const classes = await import(join(server, 'classes/app-error-code.ts'));

plugin({
  name: 'chapter-route-fixture-stubs',
  setup(build) {
    build.module('@server/classes', () => ({ exports: { AppErrorCode: classes.AppErrorCode }, loader: 'object' }));
    build.module('@server/database', () => ({ exports: { schema: {} }, loader: 'object' }));
    build.module('@langchain/core/messages', () => ({ exports: {}, loader: 'object' }));
    build.module('drizzle-orm', () => ({ exports: { eq: () => undefined }, loader: 'object' }));
  },
});

const route = await import(join(server, 'modules/ai/chapter-route.ts'));
const defaults = await import(join(server, 'modules/ai/defaults.ts'));
const hardLine = await import(join(server, 'modules/ai/hard-line.ts'));

type Mode = 'standard' | 'unrestricted';

const planModes: (Mode | null | 'absent')[] = ['standard', 'unrestricted', null, 'absent'];
const isolatedStates: (boolean | undefined)[] = [undefined, false, true];

const contentModes = planModes.flatMap(plan =>
  isolatedStates.map(isolated => {
    const source: { brief?: { contentMode: Mode | null } | null; isolated?: boolean } = {};
    if (plan !== 'absent') source.brief = { contentMode: plan };
    if (isolated !== undefined) source.isolated = isolated;
    return { plan: plan === 'absent' ? 'none' : (plan ?? 'null'), isolated: isolated ?? null, mode: route.chapterContentMode(source) };
  }),
);

const containment = (['standard', 'unrestricted'] as Mode[]).flatMap(mode =>
  [false, true].map(raised => {
    const result = route.chapterContainment(mode, { raised });
    return { mode, raised, contained: 'isolated' in result && result.isolated === true && result.generator === 'unrestricted', keys: Object.keys(result).sort() };
  }),
);

const table = Object.entries(route.CHAPTER_ROUTE_TABLE).map(([role, aiRole]) => ({ role, aiRole, group: defaults.ROLE_GROUP[aiRole as string] }));

const scopes = Object.keys(defaults.ROLE_GROUP).map(role => ({ role, scope: hardLine.outputScope(role) }));

const writerInputs: [string, unknown][] = [
  ['guidance', 'Let the lamplighter arrive before the storm.'],
  ['feedback', 'Shorten the harbour scene.'],
  ['chapterBrief', { goal: 'The ferry leaves late', beats: ['Mara argues with the clerk', 'The bell rings twice'] }],
  ['endingContract', ['She boards without a ticket']],
  ['contextPack', 'Mara keeps the harbour ledger.'],
  ['stableContext', 'The ferry runs on tides.'],
  ['volatileContext', [{ role: 'assistant', content: 'Earlier note.' }, { role: 'user', content: [{ type: 'text', text: 'A pasted line.' }, { type: 'image_url' }] }]],
  ['draftBody', 'The tide came in slowly.'],
  ['prose', 'Gulls wheeled over the quay.'],
  ['findings', [{ note: 'Pacing sags' }, { note: 'Name repeats' }]],
  ['minWords', 1200],
  ['wordTargetAim', 2000],
  ['chapterNumber', 4],
  ['existingTitles', ['The Quay', 'Low Water']],
  ['settledFindings', 'Keep the bell.'],
  ['unlistedKey', 'Anything else is held to the full rule.'],
  ['nested', { inner: { deeper: ['one', { content: 'two' }] } }],
];

type Tagged = null | boolean | number | string | Tagged[] | { o: [string, Tagged][] };

function tag(value: unknown): Tagged {
  if (Array.isArray(value)) return value.map(tag);
  if (value === null || typeof value !== 'object') return value as Tagged;
  return { o: Object.entries(value).map(([key, inner]) => [key, tag(inner)]) };
}

interface Screen {
  text: string;
  scope: string;
  source: string;
}

const screenRows = (screens: Screen[]) => screens.map(screen => [screen.text, screen.scope, screen.source]);
const inputRow = (entries: [string, unknown][]) => [entries.map(([key, value]) => [key, tag(value)]), screenRows(hardLine.inputScreens(Object.fromEntries(entries)))];

const inputs = [...writerInputs.map(entry => inputRow([entry])), inputRow(writerInputs), inputRow([])];

const spec = {
  expectedRoles: { draft: 'generation', title: 'title', judge: 'judge', repair: 'fix', revise: 'revision', review: 'review', summary: 'continuity', continuity: 'continuity', extraction: 'extraction' },
  specModes: [
    [{ brief: { contentMode: 'standard' } }, 'standard'],
    [{ brief: { contentMode: 'unrestricted' } }, 'unrestricted'],
    [{ brief: { contentMode: null } }, 'standard'],
    [{}, 'standard'],
    [{ brief: { contentMode: 'standard' }, isolated: true }, 'unrestricted'],
  ].map(([source, mode]) => ({ source, mode: route.chapterContentMode(source as never), expected: mode })),
  specContainment: [
    ['unrestricted', false],
    ['standard', true],
    ['standard', false],
  ].map(([mode, raised]) => ({ mode, raised, result: route.chapterContainment(mode as Mode, { raised: raised as boolean }) })),
};

const fixture = { roles: Object.keys(route.CHAPTER_ROUTE_TABLE), contentModes, containment, table, scopes, inputs, spec };

writeFileSync(join(dirname(fileURLToPath(import.meta.url)), 'chapter-route.json'), JSON.stringify(fixture) + '\n');
