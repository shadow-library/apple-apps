import { plugin } from 'bun';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');

const server = join(platformRepo, 'apps/novel-forge-server/src');
const reviewDir = join(server, 'modules/review');
const here = dirname(fileURLToPath(import.meta.url));
const noop = () => undefined;

plugin({
  name: 'review-findings-fixture-stubs',
  setup(build) {
    build.module('drizzle-orm', () => ({ exports: { and: noop, eq: noop, inArray: noop, lt: noop }, loader: 'object' }));
    build.module('@shadow-library/common', () => ({ exports: { Config: { get: noop } }, loader: 'object' }));
    build.module('@server/database', () => ({ exports: { schema: new Proxy({}, { get: () => new Proxy({}, { get: () => null }) }) }, loader: 'object' }));
    build.module('@server/common', () => ({
      exports: Object.fromEntries(['chapterUnlockContext', 'evaluateUnlock', 'isOpenCanon', 'parseKnowledgeContract', 'revealRequirements', 'revealTermPattern'].map(name => [name, noop])),
      loader: 'object',
    }));
  },
});

const findings = await import(join(reviewDir, 'review-findings.ts'));
// review-prompts.ts comes from the platform working copy, whose uncommitted edit drops the judge task's Context block.
const prompts = await import(join(reviewDir, 'review-prompts.ts'));
const metrics = await import(join(server, 'modules/eval/deterministic-metrics.ts'));

const overrideSource = readFileSync(join(reviewDir, 'review-records.ts'), 'utf8');
const overrideMarker = "export const APPROVAL_OVERRIDE_REASON = 'approved by the author';";
if (!overrideSource.includes(overrideMarker)) throw new Error('the approval override reason moved');
const gateMarker = 'if (!latest || isReviewStale(latest, { draftRevision: draft.revision, bodyHash: hashReviewedBody(draft.body) })) return null;';
if (!overrideSource.includes(gateMarker)) throw new Error('the open blocking findings rule moved');
const gateTail = "openFindings(latest.findings, latest.remedies).filter(finding => finding.severity === 'blocking')";
if (!overrideSource.includes(gateTail)) throw new Error('the open blocking findings rule moved');

interface Rng {
  next(): number;
  int(min: number, max: number): number;
  chance(p: number): boolean;
  pick<T>(items: readonly T[]): T;
  subset<T>(items: readonly T[], p?: number): T[];
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
    subset: (items, p = 0.5) => items.filter(() => next() < p),
  };
}

const rng = createRng(0x0801);

const KINDS = ['judge', 'editorial', 'mechanics', 'readability'] as const;
const CATEGORIES = ['continuity', 'brief', 'ending', 'knowledge', 'readability', 'mechanics', 'editorial', 'proofreading'] as const;
const SEVERITIES = ['blocking', 'warning', 'note'] as const;
const ACTIONS = ['dismissed', 'fixing_myself', 'overridden'] as const;
const PROOFREAD_KINDS = ['grammar', 'spelling', 'punctuation', 'tense', 'pov', 'name', 'reference'] as const;

const BODY = 'Mara counted the lanterns on the quay twice. “Nine,” she said. “There were ten last night.”';
const SENTENCES = [
  'Mara counted the lanterns on the quay twice.',
  '“Nine,” she said, “and there were ten last night.”',
  'The harbour master did not look up from his ledger.',
  'Rain ran down the crooked slates of the customs house.',
  'Tomas whistled a tune nobody on the quay could name.',
  'She tucked the key into her coat and walked on.',
  'A gull stood on the rail and watched the water.',
  'Nothing in the ledger matched what she had seen.',
  'The café on the corner smelled of burnt sugar and wet wool.',
  '“İstanbul is far,” said Ines, “but the boat leaves at dawn.”',
  'He said ‘no’ and left the door open behind him.',
  'The lamp warmed to her touch like a living thing.',
  'Café Naïve stayed open late; the kettle never cooled.',
  '一盏灯亮了，她没有回头。',
  'They shared bread, cheese and a long silence.',
];
const LONG_CLAUSES = [
  'the harbour master, who had kept the ledger since before the old bridge fell and who trusted no hand but his own, turned each page slowly',
  'while the rain, which had begun at dusk and showed no sign of ending before the tide turned, ran down every slate and gutter on the quay',
  'and Mara, remembering what her mother had said about counting lanterns twice whenever the fog came in from the estuary, began again from the pier',
];
const ORNATE = ['The architecture of her grief held the house together.', 'The silence had a weight she could taste.', 'The room held its breath.', 'His voice like a bell carried.'];

function prose(sentences: number, joiner = ' '): string {
  return Array.from({ length: sentences }, () => rng.pick(SENTENCES)).join(joiner);
}

function paragraphs(count: number, perParagraph: number): string {
  return Array.from({ length: count }, () => prose(perParagraph)).join('\n\n');
}

function longSentences(count: number): string {
  return Array.from({ length: count }, () => `${rng.pick(LONG_CLAUSES)}, ${rng.pick(LONG_CLAUSES)}, and ${rng.pick(LONG_CLAUSES)}.`).join(' ');
}

const BODIES: string[] = [
  BODY,
  '',
  '   ',
  prose(6),
  paragraphs(8, 4),
  paragraphs(40, 4),
  paragraphs(60, 3),
  `${paragraphs(30, 4)}\n\n${ORNATE.join(' ')} ${ORNATE.join(' ')}\n\n${paragraphs(10, 3)}`,
  longSentences(30),
  `${paragraphs(20, 4)}\n\n${longSentences(12)}`,
  `${paragraphs(10, 4)}\n\n${paragraphs(1, 4)}\n\n${paragraphs(1, 4)}`,
  'Café Naïve stayed open. “Nine,” she said.',
];
const shared = paragraphs(1, 6);
BODIES.push(`${shared}\n\n${paragraphs(14, 4)}\n\n${shared}`);
BODIES.push(`${paragraphs(30, 4)}\n\n\`\`\`\nunclosed fence\n`);

const evidencePool = (body: string): string[] => {
  const sentences = body.split(/(?<=[.!?”])\s+/).filter(Boolean);
  return [
    ...sentences,
    ...sentences.map(sentence => `…${sentence.slice(3, -2)}…`),
    ...sentences.map(sentence => `...${sentence.slice(2)}`),
    ...sentences.map(sentence => sentence.replace(/[“”]/g, '"').replace(/[‘’]/g, "'")),
    ...sentences.map(sentence => `  ${sentence.toUpperCase()} `),
    ...sentences.map(sentence => sentence.replace(/ /g, '  ')),
    '',
    'ab',
    '…',
    'She counted eleven lanterns.',
    'a quote the model invented',
  ];
};

const TEXT_POOL = [
  'Canon says ten, yet "There were ten last night." reads as news.',
  'The quay is unnamed.',
  'Ten lanterns!',
  'ten   lanterns',
  'Tenfold café “There were ten last night.” and “Nine,” she said.',
  'The dialogue "short one" is under twelve characters; "this quoted passage is long enough to count" is not.',
  '“Nine,” she said, “and there were ten last night.” contradicts chapter 2',
  'Naïve and Naïve are one name',
  '日本語の文章 — still a finding',
  '',
  'Punctuation-only ??? !!!',
  'İstanbul at dawn',
];

const table: string[] = [];
function id(body: string): number {
  const found = table.indexOf(body);
  if (found >= 0) return found;
  table.push(body);
  return table.length - 1;
}

function wrapJson<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T;
}

const hashCases = BODIES.map(body => [id(body), findings.hashReviewedBody(body)]);

const staleCases: unknown[] = [];
for (const body of BODIES.slice(0, 5)) {
  const reviewed = { draftRevision: 2, bodyHash: findings.hashReviewedBody(body) };
  staleCases.push([reviewed, { draftRevision: 2, bodyHash: findings.hashReviewedBody(body) }]);
  staleCases.push([reviewed, { draftRevision: 3, bodyHash: findings.hashReviewedBody(body) }]);
  staleCases.push([reviewed, { draftRevision: 2, bodyHash: findings.hashReviewedBody(`${body} More.`) }]);
  staleCases.push([reviewed, null]);
  staleCases.push([{ draftRevision: null, bodyHash: reviewed.bodyHash }, { draftRevision: null, bodyHash: reviewed.bodyHash }]);
  staleCases.push([{ draftRevision: null, bodyHash: reviewed.bodyHash }, { draftRevision: 1, bodyHash: reviewed.bodyHash }]);
  staleCases.push([reviewed, { draftRevision: null, bodyHash: reviewed.bodyHash }]);
}
const staleRows = staleCases.map(([review, current]) => [review, current, findings.isReviewStale(review as never, current as never)]);

const fingerprintRows: unknown[] = [];
for (const kind of KINDS) for (const category of CATEGORIES) for (const text of TEXT_POOL) fingerprintRows.push([kind, category, text, findings.findingFingerprint(kind, category, text)]);

const evidenceRows: unknown[] = [];
for (const body of BODIES.slice(0, 4).concat(BODIES.slice(-3))) {
  const pool = evidencePool(body);
  for (let index = 0; index < 18; index++) {
    const candidates = Array.from({ length: rng.int(0, 3) }, () => (rng.chance(0.1) ? null : rng.pick(pool)));
    evidenceRows.push([id(body), candidates, findings.verifiedEvidence(body, candidates)]);
  }
}

function draftFinding(body: string): Record<string, unknown> {
  const pool = evidencePool(body);
  const draft: Record<string, unknown> = { severity: rng.pick(SEVERITIES), category: rng.pick(CATEGORIES), text: rng.pick(TEXT_POOL) };
  if (rng.chance(0.4)) draft.text = `${draft.text} "${rng.pick(pool)}"`;
  if (rng.chance(0.2)) draft.text = `Quoted “${rng.pick(pool)}” in curly marks`;
  if (rng.chance(0.5)) draft.evidence = rng.chance(0.15) ? null : rng.pick(pool);
  return draft;
}

const settleRows: unknown[] = [];
for (const kind of KINDS) {
  for (const body of BODIES.slice(0, 5)) {
    const drafts = Array.from({ length: rng.int(0, 5) }, () => draftFinding(body));
    drafts.push(...drafts.slice(0, 1));
    settleRows.push([kind, id(body), drafts, wrapJson(findings.settleFindings(kind, body, drafts as never))]);
  }
}
settleRows.push(['judge', id(BODY), [{ severity: 'warning', category: 'continuity', text: 'Canon says ten, yet "There were ten last night." reads as news.' }], wrapJson(findings.settleFindings('judge', BODY, [{ severity: 'warning', category: 'continuity', text: 'Canon says ten, yet "There were ten last night." reads as news.' }] as never))]);

const dispositionRows: unknown[] = [];
for (const failed of [false, true]) {
  for (const severities of [[], ['note'], ['warning'], ['blocking'], ['note', 'warning'], ['warning', 'blocking'], ['note', 'note', 'blocking'], ['note', 'warning', 'note']]) {
    const list = severities.map(severity => ({ severity }));
    dispositionRows.push([severities, failed, findings.dispositionOf(list, failed)]);
  }
}

const idsOf = (list: { id: string }[]): string[] => list.map(finding => finding.id);
const openRows: unknown[] = [];
for (let index = 0; index < 60; index++) {
  const list = Array.from({ length: rng.int(0, 6) }, (_, position) => ({ id: `f${position + 1}` }));
  const remedies = rng.subset(list, 0.5).map(finding => ({ findingId: finding.id, action: rng.pick(ACTIONS) }));
  if (rng.chance(0.2)) remedies.push({ findingId: 'f99', action: 'dismissed' });
  openRows.push([list.map(finding => finding.id), remedies, idsOf(findings.openFindings(list, remedies))]);
}

const gateRows: unknown[] = [];
for (let index = 0; index < 90; index++) {
  const body = rng.pick(BODIES.slice(0, 5));
  const revision = rng.int(1, 4);
  const reviewedBody = rng.chance(0.75) ? body : `${body} edited`;
  const reviewed = { draftRevision: rng.chance(0.75) ? revision : revision + 1, bodyHash: findings.hashReviewedBody(reviewedBody) };
  const list = Array.from({ length: rng.int(0, 5) }, (_, position) => ({ id: `f${position + 1}`, severity: rng.pick(SEVERITIES), fingerprint: `fp${index}-${position}` }));
  const remedies = rng.subset(list, 0.5).map(finding => ({ findingId: finding.id, action: rng.pick(ACTIONS) }));
  const latest = rng.chance(0.1) ? null : { ...reviewed, findings: list, remedies };
  const draft = { revision, body };
  const draftRow = { revision, body: id(body) };
  const stale = !latest || findings.isReviewStale(latest, { draftRevision: draft.revision, bodyHash: findings.hashReviewedBody(draft.body) });
  const open = stale ? [] : findings.openFindings(latest.findings, latest.remedies).filter((finding: { severity: string }) => finding.severity === 'blocking');
  const overrides = open.map((finding: { id: string; fingerprint: string }) => ({ findingId: finding.id, fingerprint: finding.fingerprint, action: 'overridden', reason: 'approved by the author' }));
  gateRows.push([latest, draftRow, idsOf(open), overrides]);
}

function compliance(): Record<string, unknown> | undefined {
  if (rng.chance(0.3)) return undefined;
  const compliant = rng.chance(0.5);
  return { compliant, issues: compliant ? (rng.chance(0.2) ? ['a stray issue'] : []) : Array.from({ length: rng.int(0, 3) }, () => rng.pick(TEXT_POOL)) };
}

function facts(): Record<string, unknown>[] {
  return Array.from({ length: rng.int(0, 2) }, (_, index) => ({ factKey: `fact_${index}`, text: rng.pick(SENTENCES) }));
}

function judgeOutput(body: string): Record<string, unknown> | null {
  if (rng.chance(0.12)) return null;
  const output: Record<string, unknown> = {
    verdict: rng.pick(['consistent', 'contradiction']),
    findings: Array.from({ length: rng.int(0, 3) }, () => ({ severity: rng.pick(['hard', 'soft']), text: rng.chance(0.4) ? `${rng.pick(TEXT_POOL)} "${rng.pick(evidencePool(body))}"` : rng.pick(TEXT_POOL) })),
  };
  for (const key of ['briefCompliance', 'endingCompliance', 'knowledgeCompliance', 'readabilityCompliance']) {
    const value = compliance();
    if (value) output[key] = value;
  }
  return output;
}

const judgeRows: unknown[] = [];
for (let index = 0; index < 140; index++) {
  const body = rng.pick(BODIES.slice(0, 5));
  const pool = evidencePool(body);
  const evidence = {
    output: judgeOutput(body),
    hasBrief: rng.chance(0.6),
    hasEndingContract: rng.chance(0.5),
    lockedFromReader: facts(),
    hiddenFromCast: facts(),
    leaks: Array.from({ length: rng.chance(0.35) ? rng.int(1, 2) : 0 }, () => ({ factKey: `fact_${rng.int(0, 3)}`, term: rng.pick(['lanterns', 'heir', 'İstanbul', 'Nine']), excerpt: `…${rng.pick(pool)}…` })),
  };
  judgeRows.push([id(body), evidence, wrapJson(findings.judgeOutcome(body, evidence as never))]);
}

const GRAPH_PREFIXES = ['', 'brief: ', 'ending contract: ', 'knowledge leak: ', 'readability: ', 'mechanical: ', 'Brief: ', 'mechanical:'];
const graphRows: unknown[] = [];
for (let index = 0; index < 80; index++) {
  const body = rng.pick(BODIES.slice(0, 5));
  const pass = {
    verdict: rng.pick(['consistent', 'contradiction', 'evaluation_failed', null]),
    findings: Array.from({ length: rng.int(0, 5) }, () => ({ severity: rng.pick(['hard', 'soft']), text: `${rng.pick(GRAPH_PREFIXES)}${rng.pick(TEXT_POOL)}` })),
  };
  graphRows.push([id(body), pass, wrapJson(findings.graphJudgeOutcome(body, pass))]);
}

function slip(body: string): Record<string, unknown> {
  const sentence = rng.pick(body.split(/(?<=[.!?”])\s+/).filter(Boolean).concat(['an invented span']));
  const quote = rng.chance(0.2) ? `  ${sentence} ` : sentence;
  const fix = rng.pick([`${sentence} again`, sentence, sentence.toUpperCase(), '', '   ', `${sentence}!`]);
  const value: Record<string, unknown> = { kind: rng.pick(PROOFREAD_KINDS), quote, fix };
  if (rng.chance(0.5)) value.reason = rng.pick(['the Story Bible spells it Marra', '', '  ', 'tense of the scene']);
  return value;
}

const editorialRows: unknown[] = [];
for (let index = 0; index < 90; index++) {
  const body = rng.pick(BODIES.slice(0, 5).concat(BODIES.slice(-3)));
  const output: Record<string, unknown> = { disposition: rng.pick(['approve', 'revision_requested']) };
  if (rng.chance(0.7)) output.note = rng.pick(['A solid chapter.', '  trimmed  ', '', '   ']);
  if (rng.chance(0.7)) {
    output.findings = Array.from({ length: rng.int(0, 3) }, () => {
      const finding: Record<string, unknown> = { severity: rng.pick(['blocking', 'suggestion']), text: rng.pick(TEXT_POOL) };
      if (rng.chance(0.5)) finding.evidence = rng.pick(evidencePool(body));
      return finding;
    });
  }
  if (rng.chance(0.75)) {
    const count = rng.chance(0.1) ? 30 : rng.int(0, 5);
    const slips = Array.from({ length: count }, () => slip(body));
    if (count > 1 && rng.chance(0.4)) slips.push(slips[0] as never);
    output.proofreading = slips;
  }
  const hasBrief = rng.chance(0.5);
  editorialRows.push([id(body), output, hasBrief, wrapJson(findings.editorialOutcome(body, output, hasBrief))]);
}
const manySlips = Array.from({ length: 25 }, (_, position) => ({ kind: 'tense', quote: 'Mara counted', fix: `Mara counts ${position}` }));
editorialRows.push([id(BODY), { disposition: 'revision_requested', proofreading: manySlips }, false, wrapJson(findings.editorialOutcome(BODY, { disposition: 'revision_requested', proofreading: manySlips }, false))]);

const TARGETS = [null, { min: 5, max: 20 }, { min: 650, max: 700 }, { min: 2400, max: 3200 }, { min: 100.5, max: 400.25 }];
const mechanicsRows: unknown[] = [];
for (const body of BODIES) {
  for (const target of TARGETS) {
    const prior = rng.pick([[], [BODIES[3]!], [BODIES[3]!, BODIES[4]!], [`${BODIES[4]}`]]);
    const resolved = metrics.resolveWordTarget(target ? { wordTargetMin: target.min, wordTargetMax: target.max } : undefined);
    mechanicsRows.push([id(body), prior.map(id), target, wrapJson(findings.mechanicsOutcome(body, prior, resolved))]);
  }
}

const readabilityRows = BODIES.concat([paragraphs(120, 2), Array.from({ length: 120 }, (_, position) => `Mara lit lamp ${position}. She walked on.`).join('\n\n')]).map(body => [
  id(body),
  wrapJson(findings.readabilityOutcome(body)),
]);

const FACTS = [
  { factKey: 'lamp_heir', text: 'Mara is the lamp-keeper’s heir.', allowedClues: ['the lamp warms to her touch', '  ', ' a second clue '] },
  { factKey: 'harbour_debt', text: 'The harbour master owes the Guild.' },
  { factKey: 'empty_clues', text: 'Nothing is said.', allowedClues: [] },
  { factKey: 'café_naïve', text: 'İstanbul is a ruse.', allowedClues: ['one'] },
];
const settledPool = [
  { fingerprint: 'a', action: 'dismissed', reason: 'sold in chapter 2', text: 'Ten lanterns in canon.' },
  { fingerprint: 'b', action: 'fixing_myself', reason: null, text: 'The quay is unnamed.' },
  { fingerprint: 'c', action: 'overridden', reason: null, text: 'Plan skips the bribe.' },
  { fingerprint: 'd', action: 'overridden', reason: '', text: 'Empty reason shown without a tail.' },
  { fingerprint: 'e', action: 'dismissed', reason: 'no text', text: '' },
];
const taskRows: unknown[] = [];
for (let index = 0; index < 80; index++) {
  const task = {
    body: rng.pick(BODIES.slice(0, 5)),
    chapterBrief: rng.pick([null, '', 'Mara notices a lantern is missing.']),
    endingContract: rng.pick(['', 'hookType: cliffhanger']),
    lockedFromReader: rng.subset(FACTS, 0.4),
    hiddenFromCast: rng.subset(FACTS, 0.4),
    readabilityEvidence: rng.pick([null, '', '## READABILITY EVIDENCE\n120 words · average sentence 9.0 words']),
    settled: rng.subset(settledPool, 0.5),
  };
  taskRows.push([{ ...task, body: id(task.body) }, prompts.renderJudgeTask(task)]);
}
const settledRows = [[], settledPool, settledPool.slice(1, 2), settledPool.slice(0, 1)].map(list => [list, prompts.renderSettledFindings(list)]);

writeFileSync(
  join(here, 'review-findings.json'),
  JSON.stringify({
    bodies: table,
    hash: hashCases,
    stale: staleRows,
    fingerprint: fingerprintRows,
    evidence: evidenceRows,
    settle: settleRows,
    disposition: dispositionRows,
    open: openRows,
    gate: gateRows,
    judge: judgeRows,
    graph: graphRows,
    editorial: editorialRows,
    mechanics: mechanicsRows,
    readability: readabilityRows,
    tasks: taskRows,
    settled: settledRows,
  }) + '\n',
);
