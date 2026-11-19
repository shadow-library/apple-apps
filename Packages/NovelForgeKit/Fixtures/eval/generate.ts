import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');

const evalDir = join(platformRepo, 'apps/novel-forge-server/src/modules/eval');
const metrics = await import(join(evalDir, 'deterministic-metrics.ts'));
const invariants = await import(join(evalDir, 'process-invariants.ts'));

interface Chapter {
  chapter: number;
  body: string;
  hookType: string | null;
}

const CHAPTERS: Chapter[] = [
  {
    chapter: 1,
    hookType: 'cliffhanger',
    body: [
      'Mara climbed the lighthouse stairs at dusk with the lamp in her hand. The wind pushed at the shutters and the old stones held the cold.',
      'She found the logbook open on the desk and its last page torn away. Her eyes widened. Somebody had been here before her.',
      '"Who was it?" she asked the empty room.',
      '"I do not know," said the keeper from the doorway. "I did not see him go."',
      'Outside the gulls wheeled over the black water and the tide came in fast.',
    ].join('\n\n'),
  },
  {
    chapter: 2,
    hookType: 'turn',
    body: [
      'Mara waited at the foot of the lighthouse until the keeper came down. He carried the logbook under his arm and would not say who had torn the last page.',
      'Her eyes widened again when he opened it. A single line of ink ran down the margin, and it was her own handwriting.',
      '"I never wrote that," she said. "It is not mine."',
      'The keeper shrugged. "The tide does not care whose it is."',
      'Behind them the tide crept over the rocks and the gulls went quiet.',
    ].join('\n\n'),
  },
  {
    chapter: 3,
    hookType: null,
    body: [
      'The lamp would not light. Mara struck the match three times and the wick stayed dark, as if the flame had somewhere better to be.',
      '```system\nLAMP: unlit\nOIL: 40%\n```',
      'She sat on the cold floor and listened to the sea. A breath hitched in her throat, and she let it go slowly. Nothing happened. Nothing at all happened for a long while.',
      'At last the keeper came back with a lantern and a different story.',
    ].join('\n\n'),
  },
  {
    chapter: 4,
    hookType: 'cliffhanger',
    body: 'Mara climbed the lighthouse stairs at dusk with the lamp in her hand. She found the logbook open on the desk and its last page torn away. Outside the gulls wheeled over the black water and the tide came in fast.',
  },
];

function windowed(chapters: Chapter[], priorWindow: number): Map<number, string[]> {
  const bodies = new Map(chapters.map(c => [c.chapter, c.body]));
  const numbers = [...bodies.keys()].sort((a, b) => a - b);
  return new Map(
    chapters.map(c => [
      c.chapter,
      numbers
        .filter(n => n < c.chapter)
        .slice(-priorWindow)
        .map(n => bodies.get(n) ?? ''),
    ]),
  );
}

const metricCases = [
  { name: 'default window and target', chapters: CHAPTERS, priorWindow: 10, target: null },
  { name: 'window of one', chapters: CHAPTERS, priorWindow: 1, target: null },
  { name: 'no window', chapters: CHAPTERS, priorWindow: 0, target: { min: 20, max: 400 } },
  { name: 'one chapter', chapters: CHAPTERS.slice(0, 1), priorWindow: 10, target: { min: 20, max: 60 } },
  { name: 'no chapters', chapters: [], priorWindow: 10, target: null },
].map(({ name, chapters, priorWindow, target }) => {
  const resolved = metrics.resolveWordTarget(target ? { wordTargetMin: target.min, wordTargetMax: target.max } : undefined);
  const report = metrics.computeDeterministicMetricsReport(chapters, windowed(chapters, priorWindow), resolved);
  return { name, chapters, priorWindow, target, expected: JSON.stringify(report) };
});

const DRAFTS = [
  { chapter: 1, judge: 'consistent', reviewStatus: 'approved', status: 'draft' },
  { chapter: 2, judge: 'evaluation_failed', reviewStatus: 'contradiction', status: 'draft' },
  { chapter: 3, judge: 'evaluation_failed', reviewStatus: 'approved', status: 'draft' },
  { chapter: 4, judge: 'evaluation_failed', reviewStatus: 'final', status: 'final' },
  { chapter: 5, judge: null, reviewStatus: 'needs_review', status: 'draft' },
];

const invariantCases = [
  { name: 'no drafts', drafts: [], approvals: [] },
  { name: 'every fail-open draft approved by a human', drafts: DRAFTS, approvals: [3, 4] },
  { name: 'a fail-open draft reached approved with no approval', drafts: DRAFTS, approvals: [4] },
  { name: 'fail-open drafts reached approved and final with no approval', drafts: DRAFTS, approvals: [] },
  { name: 'only judged drafts', drafts: DRAFTS.slice(0, 1), approvals: [1] },
].map(({ name, drafts, approvals }) => ({
  name,
  drafts,
  approvals,
  failOpen: JSON.stringify(invariants.checkFailOpenInvariant(drafts, approvals.map(chapter => ({ chapter })))),
  rate: JSON.stringify(invariants.computeEvaluationFailedRate(drafts)),
}));

const here = dirname(fileURLToPath(import.meta.url));
writeFileSync(join(here, 'metrics.json'), JSON.stringify(metricCases) + '\n');
writeFileSync(join(here, 'invariants.json'), JSON.stringify(invariantCases) + '\n');
