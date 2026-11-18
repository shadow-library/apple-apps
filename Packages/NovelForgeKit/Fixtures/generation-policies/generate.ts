// PLATFORM_REPO=<platform checkout> bun --tsconfig-override "$PLATFORM_REPO/apps/novel-forge-server/tsconfig.json" generate.ts
// The graph file has uncommitted edits in the reference checkout (judge message assembly only, outside every function composed here).
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');

const server = join(platformRepo, 'apps/novel-forge-server/src');
const graphPath = join(server, 'modules/ai/graphs/chapter-generation.graph.ts');
const outDir = dirname(fileURLToPath(import.meta.url));
const graph = await import(graphPath);
const expansion = await import(join(server, 'modules/ai/graphs/draft-expansion.ts'));
const mechanical = await import(join(server, 'modules/ai/graphs/mechanical-check.ts'));
const knowledgeView = await import(join(server, 'modules/bible/fact/knowledge-view.ts'));
const metrics = await import(join(server, 'modules/eval/deterministic-metrics.ts'));

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

const source = readFileSync(graphPath, 'utf8');
const transpiler = new Bun.Transpiler({ loader: 'ts' });

function between(from: string, to: string, inclusive = true): string {
  const start = source.indexOf(from);
  if (start === -1) throw new Error(`reference text not found: ${from}`);
  const end = source.indexOf(to, start);
  if (end === -1) throw new Error(`reference text not found: ${to}`);
  return source.slice(start, end + (inclusive ? to.length : 0));
}

function composeReference(name: string, params: string[], body: string): (...args: unknown[]) => unknown {
  const js = transpiler.transformSync(`function ${name}(${params.join(', ')}) {\n${body}\n}`);
  return new Function(`${js}\nreturn ${name};`)();
}

function compileDeclaration(name: string, text: string, deps: Record<string, unknown>): (...args: unknown[]) => unknown {
  const js = transpiler.transformSync(text);
  return new Function(...Object.keys(deps), `${js}\nreturn ${name};`)(...Object.values(deps));
}

const tag = (op: string) => (...args: unknown[]) => ({ op, args });
const chaptersTable = new Proxy({}, { get: (_, column) => String(column) });
const writerFacingFindings = compileDeclaration('writerFacingFindings', between('function writerFacingFindings(', '\n}\n'), {
  KNOWLEDGE_LEAK_PREFIX: knowledgeView.KNOWLEDGE_LEAK_PREFIX,
}) as (state: unknown, disclosure: unknown) => string;
const titlePromptInput = compileDeclaration('titlePromptInput', between('const EXISTING_TITLES_MAX', '\n}\n'), {
  and: tag('and'),
  eq: tag('eq'),
  lt: tag('lt'),
  desc: tag('desc'),
  schema: { chapters: chaptersTable },
}) as (db: unknown, projectId: bigint, chapter: number, summary: string, disclosure: unknown) => Promise<{ existingTitles: string; chapterSummary: string }>;
const resolveRepair = composeReference(
  'resolveRepair',
  ['state', 'result', 'policy', 'logger'],
  between("if (result.action === 'rewrite' && result.body) {", "return { repairMode: 'rewrite' as const, patchApplied: false, writerClassRaised: policy.raised, nodeTrace: ['repairPatch'] };"),
) as (state: unknown, result: unknown, policy: unknown, logger: unknown) => Record<string, unknown>;
const revisionSource = composeReference('revisionSource', ['state'], `return ${/const source = (.+);\n/.exec(source)?.[1]};`) as (state: unknown) => string;
if (!source.includes('judgeNote: judgeNote || null')) throw new Error('judge note no longer falls back to null');
const judgeNote = composeReference('judgeNote', ['findings', 'state'], `${/const (judgeNote = .+;)\n/.exec(source)?.[1]}\nreturn judgeNote || null;`) as (
  findings: unknown,
  state: unknown,
) => string | null;

const judgeSchemaDigest = '8778f3cf328e8858798aaa9654e49a924ca98d9927c03a93f8d36a12281a01f8';
{
  const { ClassSchema } = await import(join(platformRepo, 'apps/novel-forge-server/node_modules/@shadow-library/class-schema'));
  const { JudgeSchema } = await import(join(server, 'modules/ai/schemas/judge.schema.ts'));
  const normalised = JSON.stringify(ClassSchema.generate(JudgeSchema)).replace(/class-schema:(\w+?)(-enum)?-\d+/g, 'class-schema:$1$2');
  const digest = createHash('sha256').update(normalised).digest('hex');
  if (digest !== judgeSchemaDigest) throw new Error(`JudgeSchema changed (${digest}); re-check JudgeReport.swift against it, then pin this digest`);
}

interface Finding {
  severity: 'hard' | 'soft';
  text: string;
}

const MECHANICAL_PREFIX = mechanical.MECHANICAL_PREFIX as string;
const SIMILE = `${MECHANICAL_PREFIX}the comparison frame "like a…" appears 8 times (3.1 per 1,000 words) — keep two at most and vary or cut the rest`;
const FLOOR = `${MECHANICAL_PREFIX}draft has 900 words of prose, below the 1200-word floor`;
const READABILITY = (quote: string) => `readability: "${quote}" — say it plainly`;
const LEAK = (issue: string) => `${knowledgeView.KNOWLEDGE_LEAK_PREFIX}${issue}`;
const hard = (text: string): Finding => ({ severity: 'hard', text });
const soft = (text: string): Finding => ({ severity: 'soft', text });

const sameFindingCases: { previous: Finding[]; current: Finding[]; same: boolean; spec?: boolean }[] = [];
function sameCase(current: Finding[], previous: Finding[], spec = false, expected?: boolean): void {
  const same = graph.sameFinding(current, previous) as boolean;
  if (expected !== undefined && same !== expected) throw new Error(`sameFinding spec case drifted: ${JSON.stringify({ current, previous })}`);
  sameFindingCases.push({ previous, current, same, ...(spec ? { spec } : {}) });
}
sameCase([hard('some finding')], [], true, false);
sameCase([hard('the iron covenant')], [hard('the iron covenant')], true, true);
sameCase([hard('The Iron Covenant')], [hard('the iron covenant')], true, true);
sameCase([hard('iron covenant')], [hard('the iron covenant contradicts chapter 3')], true, false);
sameCase([soft('the iron covenant')], [hard('the iron covenant')], true, false);
sameCase([hard('character A is dead')], [hard('timeline inconsistency')], true, false);
sameCase([], [], true, false);
sameCase([], [hard('x')]);
sameCase([hard('x'), soft('y')], [soft('y')]);
sameCase([hard('  The   Iron\tCovenant\n')], [hard('the iron covenant')]);
sameCase([hard('the iron covenant')], [hard('the iron covenant')]);
sameCase([hard('the iron​covenant')], [hard('the iron covenant')]);
sameCase([hard('﻿the iron covenant')], [hard('the iron covenant')]);
sameCase([hard('İSTANBUL')], [hard('i̇stanbul')]);
sameCase([hard('ΑΣ')], [hard('ας')]);
sameCase([hard('ΑΣ ΑΣ')], [hard('ας ασ')]);
sameCase([hard('STRASSE')], [hard('straße')]);
sameCase([hard('caf\u00e9')], [hard('cafe\u0301')]);
sameCase([hard('cafe\u0301')], [hard('cafe\u0301')]);
sameCase([hard('')], [hard('   ')]);
sameCase([hard('')], [hard('x')]);
{
  const rng = createRng(0x5a11);
  const words = ['iron', 'Covenant', 'Mara', 'cellar', 'ΑΣ', 'İ', 'ß', 'lamp', 'roof', 'the', 'é', 'É'];
  const spaces = [' ', '  ', '\t', '\n', ' ', '  '];
  const phrase = (): string => Array.from({ length: rng.int(1, 4) }, () => rng.pick(words)).join(rng.pick(spaces));
  const vary = (text: string): string => (rng.chance(0.5) ? text.toUpperCase() : rng.chance(0.5) ? ` ${text}\n` : text.replace(/ /g, '  '));
  for (let i = 0; i < 120; i++) {
    const base = Array.from({ length: rng.int(0, 3) }, () => ({ severity: rng.pick(['hard', 'soft'] as const), text: phrase() }));
    const previous = base.map(f => (rng.chance(0.6) ? { severity: rng.chance(0.85) ? f.severity : f.severity === 'hard' ? 'soft' : 'hard', text: vary(f.text) } : { severity: f.severity, text: phrase() }));
    const current = rng.chance(0.5) ? base : [...base, { severity: 'soft' as const, text: phrase() }];
    sameCase(current, previous as Finding[]);
  }
}

interface RouteInput {
  verdict: string | null;
  autoFix: boolean;
  attempt: number;
  maxFixes: number;
  findings: Finding[];
  previousFindings: Finding[];
  endingCompliant?: boolean;
  knowledgeCompliant?: boolean;
  mechanicallyCompliant?: boolean;
  briefCompliant?: boolean;
  readabilityCompliant?: boolean;
}

const routeCases: { state: RouteInput; route: string; spec?: boolean }[] = [];
function routeCase(state: RouteInput, spec?: string): void {
  const route = graph.routeAfterJudge(state) as string;
  if (spec !== undefined && route !== spec) throw new Error(`routeAfterJudge spec case drifted: ${JSON.stringify(state)}`);
  routeCases.push({ state, route, ...(spec !== undefined ? { spec: true } : {}) });
}
const base = { autoFix: true, attempt: 0, maxFixes: 3, findings: [], previousFindings: [] };
routeCase({ ...base, verdict: 'consistent', autoFix: false }, 'accept');
routeCase({ ...base, verdict: 'consistent', attempt: 1 }, 'accept');
routeCase({ ...base, verdict: 'contradiction', autoFix: false, findings: [hard('x')] }, 'awaitReview');
routeCase({ ...base, verdict: 'contradiction', attempt: 3, findings: [hard('x')] }, 'acceptAsIs');
routeCase({ ...base, verdict: 'contradiction', attempt: 5, findings: [hard('x')] }, 'acceptAsIs');
routeCase({ ...base, verdict: 'contradiction', attempt: 1, findings: [hard('the iron covenant')], previousFindings: [hard('The Iron Covenant')] }, 'acceptAsIs');
{
  const simile = soft(SIMILE);
  routeCase(
    { ...base, verdict: 'contradiction', attempt: 1, findings: [hard('Mara is in the cellar, but chapter 4 left her on the roof'), simile], previousFindings: [hard('Mara carries the lamp she lost in chapter 3'), simile] },
    'repairPatch',
  );
  routeCase(
    {
      ...base,
      verdict: 'consistent',
      attempt: 1,
      knowledgeCompliant: false,
      findings: [soft('knowledge leak: over-connection: [motive_debt] Amara names the motive'), simile],
      previousFindings: [soft('knowledge leak: [motive_debt] Amara acts on the debt'), simile],
    },
    'repairPatch',
  );
  routeCase(
    {
      ...base,
      verdict: 'consistent',
      attempt: 1,
      readabilityCompliant: false,
      findings: [soft(READABILITY('The hall held its breath.')), simile],
      previousFindings: [soft(READABILITY('Her hope was a candle.')), simile],
    },
    'repairPatch',
  );
  routeCase({ ...base, verdict: 'consistent', attempt: 1, mechanicallyCompliant: false, findings: [hard(FLOOR)], previousFindings: [hard(FLOOR)] }, 'acceptAsIs');
}
routeCase({ ...base, verdict: 'contradiction', findings: [hard('new finding')] }, 'repairPatch');
routeCase({ ...base, verdict: 'contradiction', attempt: 2, findings: [hard('completely different finding')], previousFindings: [hard('some other finding')] }, 'repairPatch');
{
  const leak = { ...base, verdict: 'consistent', findings: [soft('knowledge leak: "forgery" exposes [ledger_forgery]')], knowledgeCompliant: false };
  routeCase(leak, 'repairPatch');
  routeCase({ ...leak, autoFix: false }, 'awaitReview');
  routeCase({ ...base, verdict: 'consistent', knowledgeCompliant: true }, 'accept');
  const brief = { ...base, verdict: 'consistent', findings: [soft('brief: the bribe is never dramatized')], briefCompliant: false };
  routeCase(brief, 'repairPatch');
  routeCase({ ...brief, autoFix: false }, 'awaitReview');
  routeCase({ ...base, verdict: 'consistent', briefCompliant: true }, 'accept');
  routeCase({ ...base, verdict: 'consistent' }, 'accept');
  const readability = { ...base, verdict: 'consistent', maxFixes: 2, findings: [soft(READABILITY('The kitchen held its breath.'))], readabilityCompliant: false };
  routeCase({ ...readability, attempt: 0 }, 'repairPatch');
  routeCase({ ...readability, attempt: 2 }, 'accept');
  routeCase({ ...readability, attempt: 1, previousFindings: readability.findings }, 'accept');
  routeCase({ ...readability, attempt: 0, autoFix: false }, 'accept');
  const readabilityOnly = soft(READABILITY('The kitchen held its breath.'));
  routeCase(
    { ...base, verdict: 'contradiction', maxFixes: 2, findings: [hard('Pell uses a key the ferryman never gave her'), readabilityOnly], previousFindings: [readabilityOnly], readabilityCompliant: false },
    'repairPatch',
  );
  const both = { ...base, verdict: 'consistent', maxFixes: 2, readabilityCompliant: false, briefCompliant: false };
  routeCase({ ...both, attempt: 2 }, 'acceptAsIs');
  routeCase({ ...both, attempt: 0, autoFix: false }, 'awaitReview');
  const failed = { ...base, verdict: 'evaluation_failed', findings: [hard('judge output unparseable')] };
  routeCase(failed, 'awaitReview');
  routeCase({ ...failed, autoFix: false }, 'awaitReview');
  routeCase({ ...failed, attempt: 5 }, 'awaitReview');
}
{
  const rng = createRng(0x7a0e);
  const pool = [
    hard('Mara is in the cellar, but chapter 4 left her on the roof'),
    hard('Pell uses a key the ferryman never gave her'),
    soft('the iron covenant'),
    soft(SIMILE),
    hard(FLOOR),
    soft(`${MECHANICAL_PREFIX}draft has 2900 words of prose, over the 1800–2600 target band`),
    soft(READABILITY('The hall held its breath.')),
    soft(READABILITY('Her hope was a candle.')),
    soft(LEAK('"forgery" exposes [ledger_forgery] — a forgery, she realized')),
    soft('ending contract: the hook is resolved'),
    soft('brief: the bribe is never dramatized'),
    soft('The   Iron Covenant'),
  ];
  const flag = (): boolean | undefined => (rng.chance(0.4) ? undefined : rng.chance(0.65));
  for (let i = 0; i < 700; i++) {
    const findings = Array.from({ length: rng.int(0, 4) }, () => rng.pick(pool));
    const previousFindings = rng.chance(0.3) ? [] : findings.filter(() => rng.chance(0.5)).concat(rng.chance(0.5) ? [rng.pick(pool)] : []);
    const state: RouteInput = {
      verdict: rng.pick(['consistent', 'consistent', 'contradiction', 'evaluation_failed', null]),
      autoFix: rng.chance(0.7),
      attempt: rng.int(0, 5),
      maxFixes: rng.pick([1, 2, 3, 3, 4]),
      findings,
      previousFindings,
    };
    for (const key of ['endingCompliant', 'knowledgeCompliant', 'mechanicallyCompliant', 'briefCompliant', 'readabilityCompliant'] as const) {
      const value = flag();
      if (value !== undefined) state[key] = value;
    }
    routeCase(state);
  }
}
const afterPatchCases = [true, false].map(patchApplied => ({ patchApplied, route: graph.routeAfterPatch({ patchApplied }) as string, spec: true }));

interface Fact {
  factKey: string;
  text: string;
  constraintNote: string | null;
  writerNote: string | null;
}
interface Leak {
  factKey: string;
  term: string;
  excerpt: string;
}
interface Compliance {
  compliant: boolean;
  issues: string[];
}

const motiveDebt: Fact = { factKey: 'motive_debt', text: 'Marlow owed Elias a ruinous debt.', constraintNote: 'The debt is the motive.', writerNote: 'Elias flinches when money comes up.' };
const ledgerForgery: Fact = { factKey: 'ledger_forgery', text: 'The ledger is forged.', constraintNote: 'Protects the forgery.', writerNote: null };
const forgeryLeak: Leak = { factKey: 'ledger_forgery', term: 'forgery', excerpt: 'a forgery, she realized' };
const knowledgeCases: { compliance: Compliance | null; prescan: Leak[]; forbidden: Fact[] | null; result: unknown; spec?: boolean }[] = [];
function knowledgeCase(compliance: Compliance | null, prescan: Leak[], forbidden: Fact[] | null, spec = false): void {
  const result = forbidden ? graph.mergeKnowledgeCompliance(compliance ?? undefined, prescan, forbidden) : graph.mergeKnowledgeCompliance(compliance ?? undefined, prescan);
  knowledgeCases.push({ compliance, prescan, forbidden, result, ...(spec ? { spec } : {}) });
}
knowledgeCase({ compliant: true, issues: [] }, [], null, true);
knowledgeCase(null, [], null, true);
knowledgeCase({ compliant: true, issues: [] }, [forgeryLeak], null, true);
knowledgeCase({ compliant: false, issues: ['[motive_debt] Amara acts on the debt she cannot know about'] }, [{ factKey: 'ledger_forgery', term: 'forgery', excerpt: 'x' }], null, true);
knowledgeCase(
  { compliant: false, issues: ['[motive_debt] Amara acts on the debt: Marlow owed Elias a ruinous debt.', 'something is off'] },
  [forgeryLeak],
  [motiveDebt, ledgerForgery],
  true,
);
knowledgeCase(
  {
    compliant: false,
    issues: ['over-connection: [motive_debt] Amara links the torn IOU to Marlow and confronts him', 'Over-connection: the narration names the motive'],
  },
  [],
  [{ ...motiveDebt, constraintNote: null }],
  true,
);
knowledgeCase({ compliant: false, issues: [] }, [], null);
knowledgeCase({ compliant: true, issues: ['ignored because the judge called it compliant'] }, [], [motiveDebt]);
knowledgeCase({ compliant: false, issues: ['  OVER-CONNECTION: [ledger_forgery] the clue is explained'] }, [], [motiveDebt, ledgerForgery]);
knowledgeCase({ compliant: false, issues: ['[motive_debt] and [ledger_forgery] both named'] }, [forgeryLeak, forgeryLeak], [motiveDebt, ledgerForgery]);
knowledgeCase({ compliant: false, issues: ['[motive_debt] x', '[motive_debt] x'] }, [], [motiveDebt, { ...motiveDebt, writerNote: '  ' }]);
knowledgeCase(null, [forgeryLeak, { factKey: 'motive_debt', term: 'debt', excerpt: '…the debt…' }], [motiveDebt, ledgerForgery]);
knowledgeCase({ compliant: false, issues: ['[unknown_fact] cites a fact the forbidden list lacks'] }, [], [motiveDebt]);
knowledgeCase({ compliant: false, issues: ['[motive_debt] cites a fact while the list is empty'] }, [], []);

const SECRET = 'Moriarty';
const LEAK_WORD = 'forgery';
function recordingScrubber() {
  const calls: string[] = [];
  return {
    calls,
    scrub: (text: string, field: string) => {
      calls.push(`${field}|${text}`);
      return text.split(SECRET).join(`[withheld:${field}]`);
    },
    scrubLeakLine: (line: string) => {
      calls.push(`leak|${line}`);
      return line.split(LEAK_WORD).join('[leak]');
    },
  };
}

const facingCases: { findings: Finding[]; knowledgeWriterFindings: Finding[]; rendered: string; calls: string[] }[] = [];
function facingCase(findings: Finding[], knowledgeWriterFindings: Finding[]): void {
  const scrubber = recordingScrubber();
  const rendered = writerFacingFindings({ findings, knowledgeWriterFindings }, scrubber);
  facingCases.push({ findings, knowledgeWriterFindings, rendered, calls: scrubber.calls });
}
facingCase([], []);
facingCase([hard(`Mara meets ${SECRET} too early`), soft(SIMILE)], []);
facingCase([soft(LEAK('"forgery" exposes [ledger_forgery] — a forgery, she realized'))], [soft(LEAK('remove or avoid "forgery"'))]);
facingCase([hard('Mara is in the cellar'), soft(LEAK('"forgery" exposes [ledger_forgery]'))], [soft(LEAK('remove or avoid "forgery"')), soft(LEAK('cut anything that states or implies what the POV cast cannot know yet'))]);
facingCase([], [soft(LEAK(`avoid ${LEAK_WORD} and ${SECRET}`))]);
facingCase([soft(`${knowledgeView.KNOWLEDGE_LEAK_PREFIX}`)], []);
facingCase([soft(`${knowledgeView.KNOWLEDGE_LEAK_PREFIX}\u0301x`)], []);
facingCase([hard('Knowledge leak: not a leak line because of the capital K')], []);
facingCase([hard(SECRET)], [soft(`${knowledgeView.KNOWLEDGE_LEAK_PREFIX}${SECRET}`)]);

interface TitleChapter {
  number: number;
  title: string | null;
  isolated: boolean;
  status: string;
}
const titleCases: { chapter: number; summary: string; chapters: TitleChapter[]; result: { existingTitles: string; chapterSummary: string }; calls: string[]; limit: number }[] = [];
async function titleCase(chapter: number, summary: string, chapters: TitleChapter[]): Promise<void> {
  const scrubber = recordingScrubber();
  let limit = -1;
  const db = {
    query: {
      chapters: {
        findMany: async (args: { limit: number; where: unknown; orderBy: unknown }) => {
          const expected = {
            where: tag('and')(tag('eq')('projectId', 1n), tag('lt')('number', chapter), tag('eq')('status', 'done')),
            orderBy: tag('desc')('number'),
          };
          const shape = (value: unknown): string => JSON.stringify(value, (_, item) => (typeof item === 'bigint' ? `${item}n` : item));
          if (shape({ where: args.where, orderBy: args.orderBy }) !== shape(expected)) throw new Error(`titlePromptInput query drifted: ${shape(args)}`);
          limit = args.limit;
          return chapters
            .filter(row => row.status === 'done' && row.number < chapter)
            .sort((a, b) => b.number - a.number)
            .slice(0, args.limit);
        },
      },
    },
  };
  const result = await titlePromptInput(db, 1n, chapter, summary, scrubber);
  titleCases.push({ chapter, summary, chapters, result, calls: scrubber.calls, limit });
}
const row = (number: number, title: string | null, isolated = false, status = 'done'): TitleChapter => ({ number, title, isolated, status });
await titleCase(1, 'Mara reaches the ferry.', []);
await titleCase(3, `Mara meets ${SECRET}.`, [row(1, 'The Ferry'), row(2, `${SECRET} Arrives`)]);
await titleCase(15, 'Summary', Array.from({ length: 14 }, (_, i) => row(i + 1, `Title ${i + 1}`)));
await titleCase(5, 'Summary', [row(1, 'One'), row(2, '  '), row(3, null), row(4, 'Four', true)]);
await titleCase(5, 'Summary', [row(1, 'One', false, 'draft'), row(2, 'Two', false, 'planned'), row(4, 'Four', false, 'done'), row(5, 'Five'), row(6, 'Six')]);
await titleCase(12, '', Array.from({ length: 11 }, (_, i) => row(i + 1, i % 3 === 0 ? 'Isolated' : `Title ${i + 1}`, i % 3 === 0)));
await titleCase(4, 'Summary', [row(3, '  Padded  '), row(2, 'Two\nlines')]);
{
  const rng = createRng(0x71e5);
  for (let i = 0; i < 40; i++) {
    const count = rng.int(0, 16);
    const chapters = Array.from({ length: count }, (_, index) =>
      row(index + 1, rng.chance(0.15) ? rng.pick(['', ' ', null]) : `${rng.chance(0.2) ? SECRET : 'Title'} ${index + 1}`, rng.chance(0.2), rng.chance(0.8) ? 'done' : rng.pick(['draft', 'planned'])),
    );
    await titleCase(rng.int(1, count + 2), rng.chance(0.3) ? `${SECRET} summary` : 'Summary', chapters);
  }
}

const judgeCases: { raw: string; expected: unknown; spec?: boolean }[] = [];
function judgeCase(raw: string): void {
  judgeCases.push({ raw, expected: graph.parseJudgeOutput(raw) });
}
const consistent = { verdict: 'consistent', findings: [] as Finding[] };
const full = {
  verdict: 'contradiction',
  findings: [hard('Mara is in the cellar'), soft('minor wrinkle')],
  endingCompliance: { compliant: false, issues: ['hookType: the hook is resolved'] },
  knowledgeCompliance: { compliant: true, issues: [] },
  briefCompliance: { compliant: false, issues: ['the bribe is never dramatized'] },
  readabilityCompliance: { compliant: false, issues: ['"The hall held its breath." — say it plainly'] },
};
judgeCase(JSON.stringify(consistent));
judgeCase(JSON.stringify(full));
judgeCase(JSON.stringify(full, null, 2));
judgeCase(`  \n${JSON.stringify(consistent)}\n  `);
judgeCase(`\`\`\`json\n${JSON.stringify(full)}\n\`\`\``);
judgeCase(`Here is my assessment:\n${JSON.stringify(consistent)}\nHope that helps.`);
judgeCase(`${JSON.stringify({ thinking: 'the draft looks fine', steps: [1, 2] })}\n${JSON.stringify(consistent)}`);
judgeCase(`${JSON.stringify({ verdict: 'consistent' })}\n${JSON.stringify(full)}`);
judgeCase(`${JSON.stringify({ verdict: 'bogus', findings: [] })} then ${JSON.stringify(consistent)}`);
judgeCase(JSON.stringify([consistent]));
judgeCase(`[${JSON.stringify(full)}]`);
judgeCase(JSON.stringify({ result: consistent }));
judgeCase(JSON.stringify({ verdict: 'consistent', findings: [soft('a { brace } inside "quoted" text')] }));
judgeCase(`prose with a stray } and "quote { then ${JSON.stringify({ verdict: 'consistent', findings: [soft('ok')] })}`);
judgeCase(`{"verdict":"consistent","findings":[{"severity":"soft","text":"escaped \\" quote and \\\\ slash"}]}`);
judgeCase('{"verdict":"consistent","findings":[],"verdict":"contradiction"}');
judgeCase('{"verdict":"contradiction","findings":[{"severity":"hard","text":"a"}],"verdict":"consistent"}');
judgeCase(JSON.stringify({ verdict: 'evaluation_failed', findings: [] }));
judgeCase(JSON.stringify({ verdict: 'contradiction', findings: [] }));
judgeCase(JSON.stringify({ verdict: 'contradiction', findings: [soft('only soft')] }));
judgeCase(JSON.stringify({ verdict: 'contradiction', findings: [soft('soft'), hard('hard')] }));
judgeCase(JSON.stringify({ verdict: 'consistent', findings: [], extra: 1 }));
judgeCase(JSON.stringify({ verdict: 'consistent', findings: [{ severity: 'soft', text: 'x', more: 1 }] }));
judgeCase(JSON.stringify({ verdict: 'consistent', findings: [{ severity: 'info', text: 'x' }] }));
judgeCase(JSON.stringify({ verdict: 'consistent', findings: [{ severity: 'soft', text: 7 }] }));
judgeCase(JSON.stringify({ verdict: 'consistent', findings: [{ severity: 'soft' }] }));
judgeCase(JSON.stringify({ verdict: 'consistent', findings: 'none' }));
judgeCase(JSON.stringify({ verdict: 'consistent' }));
judgeCase(JSON.stringify({ findings: [] }));
judgeCase(JSON.stringify({ verdict: 'Consistent', findings: [] }));
judgeCase(JSON.stringify({ ...consistent, briefCompliance: { compliant: true } }));
judgeCase(JSON.stringify({ ...consistent, briefCompliance: { issues: [] } }));
judgeCase(JSON.stringify({ ...consistent, briefCompliance: null }));
judgeCase(JSON.stringify({ ...consistent, briefCompliance: 'yes' }));
judgeCase(JSON.stringify({ ...consistent, briefCompliance: { compliant: 'true', issues: [] } }));
judgeCase(JSON.stringify({ ...consistent, briefCompliance: { compliant: true, issues: [1] } }));
judgeCase(JSON.stringify({ ...consistent, briefCompliance: { compliant: true, issues: [], note: 'x' } }));
judgeCase(JSON.stringify({ ...consistent, endingCompliance: { compliant: true, issues: [] }, readabilityCompliance: { compliant: true, issues: [] } }));
judgeCase('{}');
judgeCase('');
judgeCase('   ');
judgeCase('null');
judgeCase('[]');
judgeCase('"text"');
judgeCase('42');
judgeCase('no json here at all');
judgeCase('{"verdict":"consistent","findings":[');
judgeCase(`${JSON.stringify(consistent).slice(0, -1)}`);
judgeCase('{"verdict":"consistent","findings":[],}');
judgeCase("{'verdict':'consistent','findings':[]}");
judgeCase(JSON.stringify({ verdict: 'consistent', findings: [soft('café — “quoted” 😀 …')] }));
judgeCase(`\`\`\`\n{"verdict":"consistent","findings":[]}\n\`\`\`\n\`\`\`\n${JSON.stringify(full)}\n\`\`\``);

interface Patch {
  find: string;
  replace: string;
}
const ANCHOR_PROSE = 'Mara climbed the ridge. The wind was cold. She did not look back. The wind was cold again.';
const patchCases: { prose: string; proposal: { action: string; body?: string; patches?: Patch[] }; outcome: Record<string, unknown> }[] = [];
const quietLogger = { debug: () => undefined };
function patchCase(prose: string, proposal: { action: string; body?: string; patches?: Patch[] }): void {
  const state = { prose, attempt: 1, findings: [hard('x')], runId: 'run', chapter: 1 };
  const out = resolveRepair(state, proposal, { raised: false }, quietLogger);
  const kind = out.patchApplied === true ? 'patched' : 'prose' in out ? 'rewriteBody' : 'fallBack';
  const outcome: Record<string, unknown> = { kind, prose: out.prose ?? null, attemptBumped: out.attempt !== undefined, keepsFindings: out.previousFindings !== undefined };
  if (kind === 'fallBack' && proposal.patches?.length) {
    let patched = prose;
    for (const [index, patch] of proposal.patches.entries()) {
      const occurrences = patch.find === '' ? -1 : patched.split(patch.find).length - 1;
      if (occurrences === 1) {
        patched = patched.replace(patch.find, () => patch.replace);
        continue;
      }
      outcome.rejection = { patch: index, occurrences };
      break;
    }
  }
  patchCases.push({ prose, proposal, outcome });
}
patchCase(ANCHOR_PROSE, { action: 'rewrite', body: 'A whole new chapter.' });
patchCase(ANCHOR_PROSE, { action: 'rewrite', body: '' });
patchCase(ANCHOR_PROSE, { action: 'rewrite' });
patchCase(ANCHOR_PROSE, { action: 'rewrite', body: 'ignored', patches: [{ find: 'ridge', replace: 'hill' }] });
patchCase(ANCHOR_PROSE, { action: 'patch' });
patchCase(ANCHOR_PROSE, { action: 'patch', patches: [] });
patchCase(ANCHOR_PROSE, { action: 'patch', body: 'ignored body', patches: [{ find: 'ridge', replace: 'hill' }] });
patchCase(ANCHOR_PROSE, { action: 'patch', patches: [{ find: 'ridge', replace: 'hill' }] });
patchCase(ANCHOR_PROSE, { action: 'patch', patches: [{ find: 'ridge', replace: 'hill' }, { find: 'hill', replace: 'mountain' }] });
patchCase(ANCHOR_PROSE, { action: 'patch', patches: [{ find: 'ridge', replace: 'hill' }, { find: 'ridge', replace: 'mountain' }] });
patchCase(ANCHOR_PROSE, { action: 'patch', patches: [{ find: 'valley', replace: 'hill' }] });
patchCase(ANCHOR_PROSE, { action: 'patch', patches: [{ find: 'The wind was cold', replace: 'It was cold' }] });
patchCase(ANCHOR_PROSE, { action: 'patch', patches: [{ find: 'ridge', replace: 'hill' }, { find: 'The wind was cold', replace: 'It was cold' }] });
patchCase(ANCHOR_PROSE, { action: 'patch', patches: [{ find: 'The wind was cold again.', replace: 'It grew colder.' }, { find: 'The wind', replace: 'A gust' }] });
patchCase(ANCHOR_PROSE, { action: 'patch', patches: [{ find: 'ridge', replace: 'ridge. The wind was cold' }] });
patchCase(ANCHOR_PROSE, { action: 'patch', patches: [{ find: 'Mara', replace: 'Mara' }] });
patchCase(ANCHOR_PROSE, { action: 'patch', patches: [{ find: 'She did not look back. ', replace: '' }] });
patchCase(ANCHOR_PROSE, { action: 'patch', patches: [{ find: 'ridge', replace: '' }] });
patchCase(ANCHOR_PROSE, { action: 'patch', patches: [{ find: ANCHOR_PROSE, replace: 'everything' }] });
patchCase(ANCHOR_PROSE, { action: 'patch', patches: [{ find: 'mara', replace: 'x' }] });
patchCase('aaa', { action: 'patch', patches: [{ find: 'aa', replace: 'b' }] });
patchCase('aaaa', { action: 'patch', patches: [{ find: 'aa', replace: 'b' }] });
patchCase('abab', { action: 'patch', patches: [{ find: 'abab', replace: 'x' }] });
patchCase('Ünïcode café — “quotes” 😀 end', { action: 'patch', patches: [{ find: 'café — “quotes” 😀', replace: 'tea' }] });
patchCase('Ünïcode café 😀 😀 end', { action: 'patch', patches: [{ find: '😀', replace: 'x' }] });
patchCase('line one\r\nline two\nline three', { action: 'patch', patches: [{ find: 'one\nline', replace: 'x' }] });
patchCase('line one\r\nline two\nline three', { action: 'patch', patches: [{ find: 'one\r\nline', replace: 'x' }] });
patchCase('é and é', { action: 'patch', patches: [{ find: 'é', replace: 'x' }] });
patchCase('plain', { action: 'patch', patches: [{ find: '', replace: 'x' }] });
patchCase('plain', { action: 'patch', patches: [{ find: 'plain', replace: 'x' }, { find: '', replace: 'y' }] });
patchCase('', { action: 'patch', patches: [{ find: 'x', replace: 'y' }] });

const dollarCases: { prose: string; patch: Patch; referenceProse: string; literalProse: string }[] = [];
for (const [prose, patch] of [
  ['She paid fifty coins.', { find: 'fifty coins', replace: '$$50 and $& more' }],
  ['She paid fifty coins.', { find: 'fifty', replace: 'a $` of' }],
  ['She paid fifty coins.', { find: 'fifty', replace: "an $' of" }],
  ['She paid fifty coins.', { find: 'fifty', replace: 'costs $5 or $1' }],
  ['She paid fifty coins.', { find: 'fifty', replace: '$$$' }],
] as [string, Patch][]) {
  const referenceProse = (resolveRepair({ prose, attempt: 1, findings: [] }, { action: 'patch', patches: [patch] }, { raised: false }, quietLogger).prose ?? null) as string;
  const at = prose.indexOf(patch.find);
  dollarCases.push({ prose, patch, referenceProse, literalProse: prose.slice(0, at) + patch.replace + prose.slice(at + patch.find.length) });
}

const emptyAnchorCases = ['', 'a', 'ab', 'abc'].map(prose => ({
  prose,
  referenceProse: (resolveRepair({ prose, attempt: 1, findings: [] }, { action: 'patch', patches: [{ find: '', replace: 'x' }] }, { raised: false }, quietLogger).prose ?? null) as string | null,
}));

const sourceCases = [0, 1, 2, 5].flatMap(attempt =>
  ['patch', 'rewrite'].map(repairMode => ({ attempt, repairMode, source: revisionSource({ attempt, repairMode }) as string })),
);

const noteCases: { findings: Finding[]; readabilityNote: string | null; note: string | null }[] = [];
function noteCase(findings: Finding[], readabilityNote: string | null): void {
  noteCases.push({ findings, readabilityNote, note: judgeNote(findings, { readabilityNote }) });
}
noteCase([], null);
noteCase([], '');
noteCase([], '[info] readability: measured 25 words per sentence');
noteCase([hard('Mara is in the cellar')], null);
noteCase([hard('Mara is in the cellar'), soft(SIMILE)], '[info] readability: measured 25 words per sentence');
noteCase([soft('')], null);
noteCase([soft('line one\nline two')], '');
noteCase([], '   ');

const SENTENCE = 'She climbed the ridge and did not look back. ';
const SENTENCE_WORDS = 9;
const PANEL = `\`\`\`system Status\n${'Strength rises by one point after the training. '.repeat(100)}\n\`\`\``;
const bodyOfWords = (words: number): string => SENTENCE.repeat(Math.ceil(words / SENTENCE_WORDS)).trim();
type Response = { words: number; panel?: boolean } | { error: true } | { noBody: true } | { emptyBody: true };
const bodyOf = (response: Response): string | undefined =>
  'words' in response ? `${bodyOfWords(response.words)}${response.panel ? `\n\n${PANEL}` : ''}` : 'emptyBody' in response ? '' : undefined;

const expansionCases: Record<string, unknown>[] = [];
async function expansionCase(start: { words: number; panel?: boolean }, responses: Response[], project?: { wordTargetMin: number; wordTargetMax: number }, maxPasses?: number): Promise<void> {
  const original = `${bodyOfWords(start.words)}${start.panel ? `\n\n${PANEL}` : ''}`;
  const calls: Record<string, unknown>[] = [];
  const modelRouter = {
    structured: async (_prompt: unknown, vars: Record<string, unknown>) => {
      calls.push({ draftWords: vars.draftWords, minWords: vars.minWords, aimWords: vars.aimWords, missingWords: vars.missingWords });
      const response = responses[Math.min(calls.length - 1, responses.length - 1)] as Response;
      if ('error' in response) throw new Error('unparseable');
      const body = bodyOf(response);
      return 'noBody' in response ? { title: 'not an expansion' } : { body };
    },
  };
  const ctx = { projectId: 1n, runId: 'run-1', node: 'draftChapter', promptKey: 'generation', promptVersion: '2.5.0', role: 'generation' };
  const input = { body: original, stableContext: 'S', volatileContext: 'V', chapterBrief: 'B', endingContract: 'C', guidance: 'G' };
  const result = (await expansion.expandShortDraft(modelRouter, input, ctx, project, undefined, maxPasses)) as { body: string; passes: number; initialWords: number; finalWords: number };
  const kept = result.body === original ? -1 : responses.findIndex(response => bodyOf(response) === result.body);
  expansionCases.push({ start, responses, project: project ?? null, maxPasses: maxPasses ?? null, calls, passes: result.passes, initialWords: result.initialWords, finalWords: result.finalWords, kept });
}
const min = metrics.WORD_TARGET_MIN as number;
await expansionCase({ words: min + 50 }, [{ words: 2400 }]);
await expansionCase({ words: 1400 }, [{ words: 2100 }]);
await expansionCase({ words: 1900 }, [{ words: 2900 }], { wordTargetMin: 2000, wordTargetMax: 3500 });
await expansionCase({ words: 1500 }, [{ words: 2900 }], { wordTargetMin: 1200, wordTargetMax: 3500 });
await expansionCase({ words: 1400 }, [{ words: 1500 }, { words: 1600 }, { words: 1700 }]);
await expansionCase({ words: 1400 }, [{ words: 1500 }], undefined, 1);
await expansionCase({ words: 1400 }, [{ words: 900 }]);
await expansionCase({ words: 1400 }, [{ words: (mechanical.WORD_COUNT_HARD_MAX as number) + 300 }]);
await expansionCase({ words: 1400 }, [{ words: 1600 }, { error: true }]);
await expansionCase({ words: 1400, panel: true }, [{ words: 2100, panel: true }]);
await expansionCase({ words: 1400 }, [{ noBody: true }]);
await expansionCase({ words: 1400 }, [{ emptyBody: true }]);
await expansionCase({ words: 1400 }, [{ error: true }]);
await expansionCase({ words: 1800 }, [{ words: 2100 }]);
await expansionCase({ words: 1791 }, [{ words: 1800 }]);
await expansionCase({ words: 1791 }, [{ words: 1809 }]);
await expansionCase({ words: 1400 }, [{ words: 1800 }]);
await expansionCase({ words: 1400 }, [{ words: 1791 }, { words: 1800 }]);
await expansionCase({ words: 1400 }, [{ words: 1400 }]);
await expansionCase({ words: 1400 }, [{ words: 1409 }, { words: 1400 }]);
await expansionCase({ words: 1400 }, [{ words: 3006 }], { wordTargetMin: 1800, wordTargetMax: 2406 });
await expansionCase({ words: 1400 }, [{ words: 3015 }], { wordTargetMin: 1800, wordTargetMax: 2406 });
await expansionCase({ words: 1400 }, [{ words: 1500 }], undefined, 0);
await expansionCase({ words: 0 }, [{ words: 2000 }]);
await expansionCase({ words: 1400 }, [{ words: 1500 }, { words: 1600 }, { words: 1700 }], undefined, 3);
await expansionCase({ words: 1400 }, [{ words: 1500 }, { words: 1600 }], { wordTargetMin: 1801, wordTargetMax: 2600 });
{
  const rng = createRng(0x3ea7);
  for (let i = 0; i < 50; i++) {
    const project = rng.chance(0.4) ? { wordTargetMin: rng.int(900, 2400), wordTargetMax: rng.int(2500, 4000) } : undefined;
    const responses: Response[] = Array.from({ length: rng.int(1, 3) }, () => {
      const roll = rng.next();
      if (roll < 0.1) return { error: true };
      if (roll < 0.15) return { noBody: true };
      return { words: rng.int(300, 3800), ...(rng.chance(0.15) ? { panel: true } : {}) };
    });
    await expansionCase({ words: rng.int(200, 2600), ...(rng.chance(0.15) ? { panel: true } : {}) }, responses, project, rng.chance(0.2) ? rng.int(0, 3) : undefined);
  }
}

function render(value: unknown): string {
  if (Array.isArray(value)) return `[\n${value.map(item => `  ${JSON.stringify(item)}`).join(',\n')}\n]\n`;
  const entries = Object.entries(value as Record<string, unknown[]>);
  return `{\n${entries.map(([key, items]) => ` ${JSON.stringify(key)}: [\n${items.map(item => `  ${JSON.stringify(item)}`).join(',\n')}\n ]`).join(',\n')}\n}\n`;
}
const write = (name: string, value: unknown): void => writeFileSync(join(outDir, name), render(value));

write('same-finding.json', sameFindingCases);
write('routes.json', { afterJudge: routeCases, afterPatch: afterPatchCases });
write('knowledge.json', knowledgeCases);
write('writer-facing.json', facingCases);
write('titles.json', titleCases);
write('judge-reports.json', judgeCases);
write('patches.json', { resolve: patchCases, dollars: dollarCases, emptyAnchors: emptyAnchorCases, sources: sourceCases });
write('judge-notes.json', noteCases);
write('expansion.json', expansionCases);
