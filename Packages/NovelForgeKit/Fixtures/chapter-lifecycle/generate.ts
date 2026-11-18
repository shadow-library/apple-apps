// PLATFORM_REPO=<platform checkout> bun --tsconfig-override "$PLATFORM_REPO/apps/novel-forge-server/tsconfig.json" generate.ts
// The graph file has uncommitted edits in the reference checkout (judge message assembly, lines 651-659), outside the judge block composed here (669-697).
// Each case is a terminal judge pass: the judge node's findings (composed from the graph source), the route routeAfterJudge takes on them with repair off or
// spent, the pass as graphJudgeOutcome stores it, and the pass as the native pipeline stores it (findings categorised by source, the judge's own always
// continuity, and an issue line for a non-compliant ending or brief block that names none). A pass holds the draft when the route is awaitReview or acceptAsIs
// (chapter-generation.graph.ts:890-902). `lossy` marks a pass whose reference storage cannot tell the route: such a block, or a judge finding whose own text
// starts with a category prefix (review-findings.ts:206-224 categorises by prefix).
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');

const server = join(platformRepo, 'apps/novel-forge-server/src');
const graphPath = join(server, 'modules/ai/graphs/chapter-generation.graph.ts');
const outDir = dirname(fileURLToPath(import.meta.url));
const graph = await import(graphPath);
const reviewFindings = await import(join(server, 'modules/review/review-findings.ts'));
const { READABILITY_PREFIX } = await import(join(server, 'modules/ai/graphs/readability-check.ts'));
const { MECHANICAL_PREFIX } = await import(join(server, 'modules/ai/graphs/mechanical-check.ts'));
const { KNOWLEDGE_LEAK_PREFIX } = await import(join(server, 'modules/bible/fact/knowledge-view.ts'));

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

function between(from: string, to: string): string {
  const start = source.indexOf(from);
  if (start === -1) throw new Error(`reference text not found: ${from}`);
  const end = source.indexOf(to, start);
  if (end === -1) throw new Error(`reference text not found: ${to}`);
  return source.slice(start, end + to.length);
}

const judgeBlock = between('const evaluationFailed = !judgeResult;', 'findings.push(...state.mechanicalFindings);');
const judgeParams = ['judgeResult', 'renderedContract', 'forbidden', 'state', 'logger', 'mergeKnowledgeCompliance', 'scanKnowledgeLeaks', 'READABILITY_PREFIX'];
const judgeJs = transpiler.transformSync(
  `function judgePass(${judgeParams.join(', ')}) {\n${judgeBlock}\nreturn { verdict, findings, endingCompliant, knowledgeCompliant: knowledge.knowledgeCompliant, briefCompliant, readabilityCompliant };\n}`,
);
const judgePass = new Function(`${judgeJs}\nreturn judgePass;`)() as (...args: unknown[]) => {
  verdict: string;
  findings: { severity: string; text: string }[];
  endingCompliant: boolean;
  knowledgeCompliant: boolean;
  briefCompliant: boolean;
  readabilityCompliant: boolean;
};

const quiet = { warn() {}, debug() {}, info() {}, error() {} };
const forbidden = [{ factKey: 'ledger_forgery', text: 'The ledger is forged.', constraintNote: 'Protects the forgery.', writerNote: null }];
const leak = { factKey: 'ledger_forgery', term: 'forgery', excerpt: 'a forgery, she realized' };
const continuity = ['Mara was in the harbour a page ago.', 'The tide was out at dawn.', 'Oren never met the keeper.'];
const prefixes = ['ending contract: ', 'brief: ', KNOWLEDGE_LEAK_PREFIX, READABILITY_PREFIX, MECHANICAL_PREFIX];

type Compliance = { compliant: boolean; issues: string[] };
type Finding = { severity: string; text: string };

function compliance(rng: Rng, label: string, silent = false): Compliance | undefined {
  if (rng.chance(0.1)) return undefined;
  const compliant = rng.chance(0.8);
  if (!compliant && silent && rng.chance(0.3)) return { compliant, issues: [] };
  return { compliant, issues: compliant ? [] : [`${label} issue ${rng.int(1, 9)}`] };
}

const silentlyFails = (block: Compliance | undefined): boolean => block !== undefined && !block.compliant && block.issues.length === 0;

// graphFinding's severities (review-findings.ts:214-220) applied to the finding's source rather than its text.
function bySource(source: string, finding: Finding): { severity: string; category: string } {
  if (source === 'knowledge') return { severity: 'blocking', category: source };
  if (source === 'continuity') return { severity: finding.severity === 'hard' ? 'blocking' : 'warning', category: source };
  if (source === 'mechanics') return { severity: finding.severity === 'hard' ? 'warning' : 'note', category: source };
  return { severity: 'warning', category: source };
}

const rng = createRng(0x6721);
type Stored = { severity: string; category: string };
const cases: { verdict: string; findings: Stored[]; native: Stored[]; route: string; holds: boolean; lossy: boolean }[] = [];
const routes = new Set<string>();
for (let index = 0; index < 600; index++) {
  const judgeResult = rng.chance(0.1)
    ? null
    : {
        verdict: rng.chance(0.75) ? 'consistent' : 'contradiction',
        findings: Array.from({ length: rng.int(0, 2) }, () => ({
          severity: rng.chance(0.5) ? 'hard' : 'soft',
          text: `${rng.chance(0.15) ? rng.pick(prefixes) : ''}${rng.pick(continuity)}`,
        })),
        endingCompliance: compliance(rng, 'ending', true),
        briefCompliance: rng.chance(0.9) ? compliance(rng, 'brief', true) : undefined,
        readabilityCompliance: compliance(rng, 'readability'),
        knowledgeCompliance: compliance(rng, 'knowledge'),
      };
  const mechanicalFindings = Array.from({ length: rng.int(0, 2) }, () => ({
    severity: rng.chance(0.4) ? 'hard' : 'soft',
    text: `${MECHANICAL_PREFIX}${rng.pick(['too short', 'repeats an opening', 'reuses a phrase'])}`,
  }));
  const withForbidden = rng.chance(0.4);
  const scan = rng.chance(0.5) ? [leak] : [];
  const renderedContract = rng.chance(0.6) ? 'contract' : '';
  const pass = judgePass(
    judgeResult,
    renderedContract,
    withForbidden ? forbidden : [],
    { prose: 'The ledger lay open.', mechanicalFindings, runId: 'run', chapter: 1 },
    quiet,
    graph.mergeKnowledgeCompliance,
    () => scan,
    READABILITY_PREFIX,
  );
  const autoFix = rng.chance(0.5);
  const maxFixes = 3;
  const route = graph.routeAfterJudge({
    verdict: pass.verdict,
    autoFix,
    attempt: autoFix ? maxFixes : rng.int(0, maxFixes),
    maxFixes,
    findings: pass.findings,
    previousFindings: [],
    endingCompliant: pass.endingCompliant,
    knowledgeCompliant: pass.knowledgeCompliant,
    mechanicallyCompliant: !mechanicalFindings.some(finding => finding.severity === 'hard'),
    briefCompliant: pass.briefCompliant,
    readabilityCompliant: pass.readabilityCompliant,
  }) as string;
  if (!['accept', 'acceptAsIs', 'awaitReview'].includes(route)) throw new Error(`a repair-off or spent pass routed to ${route}`);
  routes.add(route);
  const stored = reviewFindings.graphJudgeOutcome('The ledger lay open.', { verdict: pass.verdict, findings: pass.findings });
  const ending = renderedContract ? judgeResult?.endingCompliance : undefined;
  const brief = judgeResult?.briefCompliance;
  const readability = judgeResult?.readabilityCompliance?.compliant === false ? judgeResult.readabilityCompliance.issues.length : 0;
  const counts: [string, number][] = [
    ['continuity', (judgeResult?.findings.length ?? 0) + (judgeResult ? 0 : 1)],
    ['ending', ending && !ending.compliant ? ending.issues.length : 0],
    ['brief', brief ? (brief.compliant ? 0 : brief.issues.length) : 1],
    ['readability', readability],
  ];
  const knowledgeCount = pass.findings.length - mechanicalFindings.length - counts.reduce((sum, [, count]) => sum + count, 0);
  if (knowledgeCount < 0) throw new Error('the judge block composed findings in another order');
  counts.push(['knowledge', knowledgeCount], ['mechanics', mechanicalFindings.length]);
  const sources = counts.flatMap(([source, count]) => Array.from({ length: count }, () => source));
  const native = pass.findings.map((finding, position) => bySource(sources[position] as string, finding));
  if (silentlyFails(ending)) native.push({ severity: 'warning', category: 'ending' });
  if (silentlyFails(brief)) native.push({ severity: 'warning', category: 'brief' });
  const prefixed = (judgeResult?.findings ?? []).some((finding: Finding) => prefixes.some(prefix => finding.text.startsWith(prefix)));
  cases.push({
    verdict: stored.verdict,
    findings: stored.findings.map((finding: Stored) => ({ severity: finding.severity, category: finding.category })),
    native,
    route,
    holds: route !== 'accept',
    lossy: silentlyFails(ending) || silentlyFails(brief) || prefixed,
  });
}
if (routes.size !== 3) throw new Error(`routes reached: ${[...routes].join(', ')}`);
if (!cases.some(entry => !entry.holds && entry.findings.some(finding => finding.severity === 'blocking'))) throw new Error('no accepted pass stores a blocking finding');
if (cases.filter(entry => entry.lossy).length < 20) throw new Error('too few lossy passes');

writeFileSync(join(outDir, 'generation-holds.json'), `${JSON.stringify({ cases })}\n`);
