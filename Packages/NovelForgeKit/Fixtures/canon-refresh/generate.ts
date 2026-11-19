import { plugin } from 'bun';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');

const server = join(platformRepo, 'apps/novel-forge-server/src');
const outDir = dirname(fileURLToPath(import.meta.url));
const classes = await import(join(server, 'classes/app-error-code.ts'));
const briefScenes = await import(join(server, 'common/brief-scenes.ts'));
const unlockCondition = await import(join(server, 'common/unlock-condition.ts'));
const docTitle = await import(join(server, 'common/bible-doc-title.ts'));
const revealTerm = await import(join(server, 'common/reveal-term.ts'));
const openCanon = await import(join(server, 'common/open-canon.ts'));

plugin({
  name: 'canon-refresh-fixture-stubs',
  setup(build) {
    build.module('@server/classes', () => ({ exports: { AppErrorCode: classes.AppErrorCode }, loader: 'object' }));
    build.module('@server/common', () => ({
      exports: {
        validateBriefScenes: briefScenes.validateBriefScenes,
        validateUnlockCondition: unlockCondition.validateUnlockCondition,
        deriveBibleDocTitle: docTitle.deriveBibleDocTitle,
        revealTermPattern: revealTerm.revealTermPattern,
        isOpenCanon: openCanon.isOpenCanon,
      },
      loader: 'object',
    }));
    build.module('@server/database', () => ({ exports: {}, loader: 'object' }));
    build.module('@server/database/schemas', () => ({ exports: {}, loader: 'object' }));
  },
});

const material = await import(join(server, 'modules/audit/bible-audit-material.ts'));
const changeSets = await import(join(server, 'modules/refinement/change-set/index.ts'));
const writePolicy = await import(join(server, 'modules/refinement/write-policy.ts'));
const bibleDocs = await import(join(server, 'modules/ai/context/bible-docs.ts'));

const CANON_REFRESH_OPS = ['bible_document.upsert', 'entity.upsert'];
const promptSource = await Bun.file(join(server, 'modules/ai/prompts/chapter-canon-refresh.prompt.ts')).text();
if (!promptSource.includes("export const CANON_REFRESH_OPS = ['bible_document.upsert', 'entity.upsert'] as const;")) throw new Error('CANON_REFRESH_OPS moved');

// bible-audit-report.ts taken from its source with its imports bound by hand: importing it pulls in the prompt index and every schema behind it.
const report = ((): Record<string, (...args: never[]) => unknown> => {
  const source = readFileSync(join(server, 'modules/audit/bible-audit-report.ts'), 'utf8');
  const start = source.indexOf('\nexport interface AuditReportInput');
  if (!source.startsWith("import { revealTermPattern } from '@server/common';") || start === -1) throw new Error('bible-audit-report.ts moved');
  const body = source.slice(start);
  const script = new Bun.Transpiler({ loader: 'ts' }).transformSync(body).replaceAll('export function', 'function').replaceAll('export const', 'const');
  const names = ['revealTermPattern', 'isWriterExcludedBibleDoc', 'AUDIT_OPS', 'CANON_REFRESH_OPS', 'CONTRADICTION_OPS', 'changeSetRefs', 'parseOptionalChangeSet', 'contentTokens', 'normaliseForQuote', 'quoteFoundIn'];
  const exported = `${script}\nreturn { buildCanonRefreshReport, renderReportSummary };`;
  return new Function(...names, exported)(
    revealTerm.revealTermPattern, bibleDocs.isWriterExcludedBibleDoc, [], CANON_REFRESH_OPS, [], changeSets.changeSetRefs, changeSets.parseOptionalChangeSet,
    writePolicy.contentTokens, writePolicy.normaliseForQuote, writePolicy.quoteFoundIn,
  );
})();

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

type Rec = Record<string, unknown>;

const WORDS = [
  'tower', 'lantern', 'marsh', 'river', 'oath', 'queen', 'harbour', 'salt', 'crown', 'bell', 'iron', 'winter', 'flood', 'smuggler', 'archive', 'tide', 'storm', 'pact',
  'Mara', 'Kael', 'Ember', 'guild', 'gate', 'ledger', 'ash', 'glass', 'road', 'mill', 'watch', 'ferry', 'the', 'and', 'of', 'is', 'now', 'it', 'café', 'café',
  'Ｔｏｗｅｒ', '王国', '灯笼', 'ひかり', '왕국', '𠮷野家', 'naïve', 'don’t',
];
const ENDS = ['.', '.', '!', '?', '。', '."', '.”'];
const GAPS = [' ', ' ', '\n', '  ', '\n\n', '\t'];
const SECTIONS = ['project', 'world', 'power', 'lore', 'plot', 'story_state', 'ai'];
const SLUGS = ['premise', 'factions', 'magic', 'history', 'timeline', 'open-questions', 'volume-plan', 'volumes', 'escalation-map', 'places', 'cast', 'rules'];
const TYPES = ['character', 'faction', 'location', 'power_rule', 'item', 'concept', 'creature'];
const KEYS = ['mara', 'kael', 'guild', 'harbour', 'lamp', 'ember-gate', 'salt-road', 'queen', 'watch', 'ferry', 'Mara', 'mára', 'mára'];

function sentence(rng: Rng, words: number): string {
  return `${Array.from({ length: words }, () => rng.pick(WORDS)).join(' ')}${rng.pick(ENDS)}`;
}

function passage(rng: Rng, sentences: number): string {
  return Array.from({ length: sentences }, () => sentence(rng, rng.int(3, 9))).join(rng.pick(GAPS));
}

function sometimes<T>(rng: Rng, p: number, value: () => T): T | null {
  return rng.chance(p) ? value() : null;
}

function long(rng: Rng, chars: number): string {
  let text = '';
  while (text.length < chars) text += `${sentence(rng, rng.int(4, 12))} `;
  return text;
}

function unique<T>(items: T[], key: (item: T) => string): T[] {
  const seen = new Set<string>();
  return items.filter(item => !seen.has(key(item)) && (seen.add(key(item)), true));
}

function rows(rng: Rng, size: 'small' | 'large'): Rec {
  const big = size === 'large';
  const documents = unique(
    Array.from({ length: rng.int(0, big ? 40 : 6) }, () => ({
      section: rng.pick(SECTIONS),
      slug: rng.pick(SLUGS),
      body: rng.chance(0.15) ? rng.pick([null, '', '   \n']) : big && rng.chance(0.6) ? long(rng, rng.int(7_500, 9_000)) : passage(rng, rng.int(1, 5)),
    })),
    doc => `${doc.section}/${doc.slug}`,
  );
  const entities = unique(
    Array.from({ length: rng.int(0, big ? 40 : 6) }, () => ({
      entityKey: rng.pick(KEYS),
      type: rng.pick(TYPES),
      name: rng.pick(['Mara', 'Kael', 'The Guild', 'Harbour', '  ', 'Ember Gate']),
      status: sometimes(rng, 0.6, () => passage(rng, 1)),
      motivation: sometimes(rng, 0.5, () => passage(rng, 1)),
      notes: sometimes(rng, 0.4, () => (big && rng.chance(0.3) ? long(rng, 1_800) : passage(rng, 2))),
      body: sometimes(rng, 0.5, () => passage(rng, rng.int(1, 3))),
    })),
    entity => entity.entityKey,
  );
  const facts = unique(
    Array.from({ length: rng.int(0, big ? 30 : 4) }, (_, index) => ({
      factKey: `${rng.pick(['heir', 'pact', 'flood', 'bell'])}-${index}`,
      text: passage(rng, 1),
      writerNote: sometimes(rng, 0.4, () => rng.pick([passage(rng, 1), '  '])),
      terms: sometimes(rng, 0.5, () => [rng.pick(WORDS), rng.pick(['iron crown', 'salt pact', 'ab'])]),
      allowedClues: sometimes(rng, 0.4, () => (rng.chance(0.2) ? [] : [passage(rng, 1), passage(rng, 1)])),
      revealChapter: sometimes(rng, 0.6, () => rng.int(0, 6)),
      disclosedInChapter: sometimes(rng, 0.3, () => rng.int(1, 4)),
      source: rng.pick(['brief', 'manual', 'seed', 'generated', 'import']),
    })),
    fact => fact.factKey,
  );
  const number = rng.int(1, 9);
  const content = big && rng.chance(0.5) ? long(rng, rng.int(59_000, 63_000)) : rng.chance(0.1) ? '  ' : passage(rng, rng.int(2, 8));
  const chapter = { number, title: sometimes(rng, 0.7, () => rng.pick(['The Lamp', '  ', 'Salt'])), summary: sometimes(rng, 0.6, () => passage(rng, 1)), content };
  const reviewItems = Array.from({ length: rng.int(0, 4) }, () => ({ claim: passage(rng, 1), decision: rng.pick(['kept', 'edited', 'skipped']) }));
  return { documents, entities, facts, chapter, reviewItems };
}

function materialOut(built: { bible: string; chapter: string; sources: Map<string, string>; partial: Set<string>; checked: Rec }): Rec {
  return { bible: built.bible, chapter: built.chapter, sources: [...built.sources.entries()], partial: [...built.partial].sort(), checked: built.checked };
}

const materialCases: Rec[] = [];
const materialRng = createRng(0x28a);
for (let index = 0; index < 60; index++) {
  const input = rows(materialRng, index % 20 === 0 ? 'large' : 'small');
  materialCases.push({ rows: input, material: materialOut(material.renderRefreshMaterial(input)) });
}

// Over every budget at once (bible-audit-material.ts:45-50): pages, records and facts that do not fit are counted as omitted.
{
  const rng = createRng(0x28c);
  const input = rows(rng, 'small');
  input.documents = SECTIONS.slice(0, 6).flatMap(section => SLUGS.slice(0, 3).map(slug => ({ section, slug, body: long(rng, 8_100) })));
  input.entities = Array.from({ length: 30 }, (_, index) => ({
    entityKey: `record-${index}`, type: rng.pick(TYPES), name: 'Mara', status: null, motivation: null, notes: long(rng, 1_600), body: null,
  }));
  input.facts = Array.from({ length: 22 }, (_, index) => ({
    factKey: `fact-${index}`, text: long(rng, 1_450), writerNote: null, terms: null, allowedClues: null, revealChapter: null, disclosedInChapter: null, source: 'manual',
  }));
  materialCases.push({ rows: input, material: materialOut(material.renderRefreshMaterial(input)) });
}

function quoteFrom(rng: Rng, text: string): string {
  const words = text.split(/\s+/).filter(Boolean);
  if (words.length === 0) return rng.pick(WORDS);
  const start = rng.int(0, Math.max(0, words.length - 3));
  return words.slice(start, start + rng.int(1, 5)).join(' ');
}

function op(rng: Rng, input: Rec, secrets: Rec[]): Rec {
  const documents = input.documents as Rec[];
  const entities = input.entities as Rec[];
  const secret = secrets.length > 0 && rng.chance(0.3) ? rng.pick(secrets) : null;
  const leak = (): string =>
    secret
      ? rng.pick([
          `${passage(rng, 1)} ${secret.text as string}`,
          `${passage(rng, 1)} ${((secret.terms as string[] | null) ?? ['iron crown'])[0]} ${sentence(rng, 3)}`,
          `${(secret.text as string).split(' ').reverse().join(' ')}.`,
        ])
      : passage(rng, rng.int(1, 3));
  if (rng.chance(0.5)) {
    const existing = documents.length > 0 && rng.chance(0.7) ? rng.pick(documents) : null;
    const target = existing ?? { section: rng.pick(SECTIONS), slug: rng.pick(SLUGS) };
    const body = existing && rng.chance(0.5) ? `${(existing.body as string | null) ?? ''} ${leak()}`.trim() : leak();
    return {
      op: 'bible_document.upsert',
      section: target.section,
      slug: target.slug,
      ...(rng.chance(0.9) ? { body } : {}),
      ...(rng.chance(0.2) ? { frontmatter: { title: rng.pick(['Places', 'Rules']), tags: [rng.pick(WORDS)] } } : {}),
    };
  }
  const existing = entities.length > 0 && rng.chance(0.7) ? rng.pick(entities) : null;
  const key = existing ? (existing.entityKey as string) : rng.pick(KEYS);
  return {
    op: 'entity.upsert',
    entityKey: key,
    type: existing ? existing.type : rng.pick(TYPES.filter(type => type !== 'creature')),
    ...(rng.chance(0.5) ? { status: leak() } : {}),
    ...(rng.chance(0.4) ? { notes: leak() } : {}),
    ...(rng.chance(0.3) ? { body: leak() } : {}),
    ...(rng.chance(0.2) ? { name: existing?.name ?? 'Kael' } : {}),
  };
}

const reportCases: Rec[] = [];
const reportRng = createRng(0x28b);
for (let index = 0; index < 240; index++) {
  const input = rows(reportRng, index % 40 === 0 ? 'large' : 'small');
  const built = material.renderRefreshMaterial(input);
  const chapterRef = `chapter:${(input.chapter as Rec).number}`;
  const chapterText = built.sources.get(chapterRef) ?? '';
  const labels = [...built.sources.keys()];
  const secretRows = material.secretFacts(input.facts);
  const ops: Rec[] = [];
  const updates = Array.from({ length: reportRng.int(0, 5) }, () => {
    const evidence = Array.from({ length: reportRng.int(1, 3) }, (_, position) => {
      const ref = position === 0 && reportRng.chance(0.8) ? chapterRef : reportRng.chance(0.8) && labels.length > 0 ? reportRng.pick(labels) : 'doc:none/none';
      const source = built.sources.get(ref) ?? '';
      return { ref, quote: reportRng.chance(0.8) ? quoteFrom(reportRng, ref === chapterRef ? chapterText : source) : passage(reportRng, 1) };
    });
    const changeSet = Array.from({ length: reportRng.int(0, 2) }, () => {
      const made = ops.length > 0 && reportRng.chance(0.2) ? (reportRng.chance(0.5) ? reportRng.pick(ops) : { ...reportRng.pick(ops), notes: passage(reportRng, 1) }) : op(reportRng, input, secretRows);
      ops.push(made);
      return made;
    });
    // The prompt's postValidate (chapter-canon-refresh.prompt.ts:38-39) sends back a reply whose ops do not validate, so none reaches the report.
    const valid = changeSets.validateChangeSet(changeSet, CANON_REFRESH_OPS, { entityMaterialization: false }).length === 0;
    return { finding: passage(reportRng, 1), evidence, changeSet: valid ? changeSet : [] };
  });
  // chapter-canon-refresh.service.ts:96-104
  const documents = input.documents as Rec[];
  const entities = input.entities as Rec[];
  const existingRefs = new Set([...documents.map(doc => `doc:${doc.section}/${doc.slug}`), ...entities.map(entity => `entity:${entity.entityKey}`)]);
  const refresh = { updates };
  const reportBuilt = report.buildCanonRefreshReport({
    refresh,
    chapterRef,
    sources: built.sources,
    partial: built.partial,
    existingRefs,
    current: material.currentRecords({ ...input, chapters: [], isolatedChapters: [] }),
    secrets: secretRows,
  });
  const summary = reportBuilt.findings.length > 0 ? `Chapter ${(input.chapter as Rec).number}: ${report.renderReportSummary(reportBuilt.findings, built.checked.copy)}` : null;
  reportCases.push({ rows: input, refresh, findings: reportBuilt.findings, changeSet: reportBuilt.changeSet, summary });
}

const write = (name: string, value: unknown): void => writeFileSync(join(outDir, name), JSON.stringify(value) + '\n');
write('material.json', { cases: materialCases });
write('report.json', { cases: reportCases });
