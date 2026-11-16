import { plugin } from 'bun';
import { writeFileSync } from 'node:fs';
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

plugin({
  name: 'write-policy-fixture-stubs',
  setup(build) {
    build.module('@server/classes', () => ({ exports: { AppErrorCode: classes.AppErrorCode }, loader: 'object' }));
    build.module('@server/common', () => ({
      exports: {
        validateBriefScenes: briefScenes.validateBriefScenes,
        validateUnlockCondition: unlockCondition.validateUnlockCondition,
        deriveBibleDocTitle: docTitle.deriveBibleDocTitle,
      },
      loader: 'object',
    }));
    build.module('@server/database', () => ({ exports: {}, loader: 'object' }));
    build.module('@server/database/schemas', () => ({ exports: {}, loader: 'object' }));
    build.onResolve({ filter: /\/artifact-state$/ }, () => ({ path: 'artifact-state', namespace: 'stub' }));
    build.onLoad({ filter: /.*/, namespace: 'stub' }, () => ({ contents: 'export {};', loader: 'js' }));
  },
});

const policy = await import(join(server, 'modules/refinement/write-policy.ts'));
const changeSet = await import(join(server, 'modules/refinement/change-set/index.ts'));
const bibleDocs = await import(join(server, 'modules/ai/context/bible-docs.ts'));

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
type Token = string | number[];

const encodeToken = (token: string): Token => (token.isWellFormed() ? token : [...token].flatMap(part => Array.from({ length: part.length }, (_, i) => part.charCodeAt(i))));
const encodeTokens = (tokens: Iterable<string>): Token[] => [...tokens].map(encodeToken);

const WORDS = [
  'tower', 'lantern', 'lanterns', 'marsh', 'river', 'oath', 'queen', 'stories', 'cities', 'ties', 'lies', 'glass', 'class', 'boss', 'harbour', 'mara', "mara's", 'ember',
  'salt', 'crown', 'bell', 'iron', 'winter', 'flood', 'betrayal', 'smuggler', 'archive', 'tide', 'storm', 'pact', '42', '7', 'x', 'Tower', 'RIVER', 'Ｔｏｗｅｒ', 'ﬁre',
  'ΟΔΟΣ', 'İstanbul', 'straße', 'caf\u00e9', 'cafe\u0301', 'na\u00efve', "don't", 'isn’t', 'won’t', 'Mara’s', 'Kelvin', 'Å', '😀', 'ภาษา', '王国', '塔', '灯笼', '𠀀', '𠮷野家',
  'ひかり', 'カタカナ', 'ラーメン', '왕국', '바다', '𐐀ngel', '𝒜sh', '½', 'x²', '①', 'éclair', 'a', 'the', 'and', 'of', 'is', 'one', 'now', 'it',
];
const HEDGES = ['if', 'maybe', 'perhaps', 'might', 'could', 'probably', 'possibly', 'wonder whether', 'suppose', 'imagine', 'not sure', 'or should', 'Maybe', 'IF', '也许', 'もし', '아마', '多分'];
const NEGATIONS = ['not', 'no', 'never', 'without', 'nor', 'cannot', "don't", 'doesn’t', '不是', '没有', 'ではない', '아니'];
const REJECTIONS = ['bad idea', 'terrible idea', 'no way', 'scrap', 'drop that', 'instead', 'Instead', 'scrapping'];
const CLAUSE_MARKS = [', ', '; ', ': ', ' (', ') ', '、', ' - ', ' — ', ' – ', ' ', ' ', '  '];
const TERMINATORS = ['.', '.', '!', '?', '。', '！', '？', '', '...', '?!', '…', '？'];
const CLOSERS = ['', '', '', '"', "'", '”', '’', ')', ']', '」', '』', '"\'', '」』', '”)', '）'];
const GAPS = [' ', ' ', '  ', '\n', '\r\n', '\n\n', '', '\t', '　', ' ', ' ', ' ', '﻿', '\u0085', '​', '᠎', '\u000b', '\u000c', ' ', ' ', ' ', ' '];
const OPENERS = ['', '', '', '"', '“', "'", '‘', '「', '('];

function sentence(rng: Rng, words: readonly string[] = WORDS, clean = false): string {
  const parts: string[] = [];
  const cue = clean ? 1 : rng.next();
  if (cue < 0.15) parts.push(rng.pick(HEDGES), ' ');
  else if (cue < 0.27) parts.push(rng.pick(NEGATIONS), ' ');
  const count = rng.int(1, 9);
  for (let i = 0; i < count; i++) {
    parts.push(rng.pick(words));
    if (i < count - 1) parts.push(rng.chance(0.2) ? rng.pick(CLAUSE_MARKS) : ' ');
  }
  if (!clean && rng.chance(0.1)) parts.push(` ${rng.pick(REJECTIONS)}`);
  const body = parts.join('');
  return `${rng.pick(OPENERS)}${body}${clean ? rng.pick(['.', '!', '。', '']) : rng.pick(TERMINATORS)}${rng.pick(CLOSERS)}`;
}

function text(rng: Rng, words: readonly string[] = WORDS, maxSentences = 5, clean = false): string {
  const count = rng.int(clean ? 1 : 0, maxSentences);
  let out = '';
  for (let i = 0; i < count; i++) out += (i > 0 ? rng.pick(GAPS) : '') + sentence(rng, words, clean);
  return out;
}

const FIXED_TEXTS = [
  '', ' ', '\t\n', '?', '.', '。', 'Maybe.', 'He said "the tower falls." Then it rose!', "It's Mara's tower.", 'cities ties lies boss glass class', '中𠀀', '𠀀', '中', 'ー', 'カー',
  '𠀀𠀀𠮷', '塔の王国。灯笼！灯笼？', 'Line one\r\nLine two\rLine three\n\nLine four', ' \t\u000b\u000c        　﻿ ', 'a\u0085b᠎c​d',
  'Wait… what?', 'Ｔｏｗｅｒ？ Ｙｅｓ！', 'ΟΔΟΣ. ΣΑΣ.', 'İİ ı I', 'ﬁre ﬂood', '½ x² ① ㈱', 'Kelvin Ångstrom', "isn't don't won't", 'not sure about the tower', 'or should the river win',
  '왕국의 바다', 'ภาษาไทยดี', '."""""""" next', 'A.)] B.」』C', 'end?"\')  ', '“Quoted,” she said. ‘Single’ — dash – dash', 'a — b – c - d', 'mara\'s mara’s maraʼs mara‛s',
  'instead, the tower falls', 'The tower falls instead.', 'no way the river floods', 'the queen never left the tower', '也许塔会倒。塔会倒。', 'もし塔が倒れたら', '아마 탑이 무너진다',
  'éclair éclair', '𐐀ngel 𐐨ngel', 'x́́́ y', '1st 2nd 3rd 42', "rock'n'roll o'clock", "'''", '"""', '  "the tower"  ', '​​',
];

const textCases: unknown[] = [];
const quoteCases: unknown[] = [];

function recordText(value: string): void {
  const sentences: string[] = policy.splitSentences(value);
  const words = policy.authorWords(value);
  textCases.push([
    value,
    policy.normaliseForQuote(value),
    encodeTokens(policy.contentTokens(value)),
    sentences,
    sentences.map(s => (policy.sentenceIsTentative(s) ? '1' : '0')).join(''),
    encodeTokens(words.stated),
    encodeTokens(words.hedged),
  ]);
}

function recordQuote(quote: string, value: string): void {
  quoteCases.push([quote, value, policy.quoteFoundIn(quote, value), policy.quoteIsTentative(quote, value)]);
}

function quoteFrom(rng: Rng, value: string): string {
  const pieces = value.split(/(\s+)/);
  const start = rng.int(0, Math.max(0, pieces.length - 1));
  const span = pieces.slice(start, start + rng.int(3, 21)).join('');
  const roll = rng.next();
  if (roll < 0.1) return span.toUpperCase();
  if (roll < 0.2) return `"${span}"`;
  if (roll < 0.25) return `  '${span}'  `;
  if (roll < 0.3) return span.replace(/'/g, '’').replace(/"/g, '“');
  if (roll < 0.35) return span.replace(/ /g, '\n ');
  if (roll < 0.4) return span.normalize('NFD');
  return span;
}

const textRng = createRng(0x5eed11);
for (const fixed of FIXED_TEXTS) {
  recordText(fixed);
  recordQuote(fixed, fixed);
  recordQuote(fixed, `${fixed} and more words here.`);
}
for (let i = 0; i < 200; i++) recordText(text(textRng));
for (let i = 0; i < 380; i++) {
  const value = textRng.chance(0.1) ? textRng.pick(FIXED_TEXTS) : text(textRng);
  recordQuote(textRng.chance(0.85) ? quoteFrom(textRng, value) : sentence(textRng), value);
}
for (let run = 1; run <= 40; run += 3) recordText(`It ends.${'"'.repeat(run)} Then ${'」'.repeat(run)}starts。${'』'.repeat(run)}x`);

const SECTIONS = ['project', 'world', 'power', 'plot', 'story_state', 'ai', 'lore'];
const ENTITY_TYPES = ['character', 'faction', 'location', 'power_rule', 'item', 'concept'];
const PAGES: [string, string][] = [
  ['project', 'premise'], ['project', 'timeline'], ['project', 'open-questions'], ['project', 'cast'], ['project', 'notes'], ['story_state', 'volume-plan'], ['story_state', 'volumes'],
  ['story_state', 'now'], ['plot', 'escalation-map'], ['plot', 'beats'], ['world', 'setting-overview'], ['world', 'factions-and-locations'], ['world', 'harbour'],
  ['power', 'system-and-limits'], ['power', 'tides'], ['lore', 'songs'], ['ai', 'characters'], ['project', 'Timeline'], ['project', 'timeline '],
];
const ENTITY_KEYS = ['mara', 'vell', 'tower', 'queen', 'harbour_guild', 'mara’s', '\u00e9', 'e\u0301'];
const FACT_KEYS = ['oath_broken', 'queen_is_mara', 'tide_secret', 'tower'];
const VOLUME_KEYS = ['v1', 'v2', 'winter', 'tower'];
const MILESTONE_KEYS = ['m1', 'tower_falls', 'oath', 'crowned'];
const PROMISE_KEYS = ['p1', 'who_rang', 'tower', 'oath'];
const STORY_FIELDS: string[] = changeSet.declaredOpFields('premise.update');

interface Story {
  message: string;
  words: string[];
  clean: boolean;
}

function prose(rng: Rng, story: Story, min = 0, max = 10): string {
  const count = rng.int(min, max);
  const out: string[] = [];
  for (let i = 0; i < count; i++) out.push(story.clean || rng.chance(0.85) ? rng.pick(story.words) : rng.pick(WORDS));
  const joined = out.join(rng.chance(0.2) ? ', ' : ' ');
  return rng.chance(0.05) ? rng.pick(['', ' ', '\t', '　']) : joined;
}

function maybe(rng: Rng, record: Rec, key: string, p: number, value: () => unknown): void {
  if (rng.chance(p)) record[key] = value();
}

function contentOp(rng: Rng, story: Story): Rec {
  const kind = rng.chance(0.75)
    ? rng.pick(['premise.update', 'bible_document.upsert', 'entity.upsert', 'entity.upsert', 'fact.upsert', 'volume.upsert', 'promise.create', 'promise.update', 'milestone.upsert'])
    : rng.pick([
        'promise.set_payoff', 'brief.update', 'brief.update', 'bible_document.remove', 'volume.remove', 'brief.remove', 'draft.update', 'draft.remove', 'draft.rewrite_passage',
        'entity.remove', 'fact.remove', 'milestone.remove', 'promise.drop', 'organise.rule', 'action', 'action',
      ]);
  const op: Rec = {};
  const text = (min = 0, max = 8) => () => prose(rng, story, min, max);
  const strings = () => Array.from({ length: rng.int(0, 3) }, () => prose(rng, story, 1, 4));
  switch (kind) {
    case 'premise.update': {
      op['op'] = kind;
      for (const field of STORY_FIELDS) maybe(rng, op, field, 0.25, field === 'themes' ? strings : field === 'protagonistKey' ? () => rng.pick(ENTITY_KEYS) : text());
      break;
    }
    case 'bible_document.upsert':
    case 'bible_document.remove': {
      op['op'] = kind;
      const [section, slug] = rng.pick(PAGES);
      const form = rng.next();
      if (form < 0.08) Object.assign(op, { section: `doc:${section}/${slug}`, slug: '' });
      else if (form < 0.12) Object.assign(op, { section, slug: `${section}/${slug}` });
      else Object.assign(op, { section, slug });
      if (kind === 'bible_document.upsert') {
        maybe(rng, op, 'body', 0.7, text(0, 14));
        maybe(rng, op, 'frontmatter', 0.3, () => ({ title: prose(rng, story, 1, 3), tags: strings(), n: 3, flag: true, nested: { note: prose(rng, story, 0, 4), none: null } }));
      }
      break;
    }
    case 'entity.upsert':
      Object.assign(op, { op: kind, entityKey: rng.pick(ENTITY_KEYS), type: rng.pick(ENTITY_TYPES) });
      maybe(rng, op, 'name', 0.5, () => rng.pick(['Mara Vell', 'The Tower', 'Queen of Salt', 'mara', 'Vell']));
      for (const field of ['status', 'motivation', 'notes', 'body']) maybe(rng, op, field, 0.35, text());
      break;
    case 'fact.upsert':
      Object.assign(op, { op: kind, factKey: rng.pick(FACT_KEYS) });
      maybe(rng, op, 'body', 0.5, text(0, 12));
      maybe(rng, op, 'subjects', 0.3, () => Array.from({ length: rng.int(0, 2) }, () => rng.pick(ENTITY_KEYS)));
      maybe(rng, op, 'constraintNote', 0.25, text());
      maybe(rng, op, 'writerNote', 0.15, text());
      maybe(rng, op, 'terms', 0.25, strings);
      maybe(rng, op, 'revealChapter', 0.12, () => (rng.chance(0.3) ? null : rng.int(1, 9)));
      maybe(rng, op, 'unlock', 0.15, () =>
        rng.chance(0.25)
          ? null
          : {
              all: Array.from({ length: rng.int(1, 3) }, () =>
                rng.pick([{ milestone: rng.pick(MILESTONE_KEYS) }, { volume: rng.pick(VOLUME_KEYS) }, { chapter: rng.int(1, 9) }, { ending: true }]),
              ),
            },
      );
      maybe(rng, op, 'allowedClues', 0.1, () => (rng.chance(0.3) ? null : [prose(rng, story, 1, 3) || 'clue']));
      break;
    case 'volume.upsert':
      Object.assign(op, { op: kind, volumeKey: rng.pick(VOLUME_KEYS) });
      maybe(rng, op, 'ordinal', 0.25, () => rng.int(0, 4));
      maybe(rng, op, 'title', 0.4, text(0, 4));
      maybe(rng, op, 'objective', 0.25, text());
      maybe(rng, op, 'body', 0.2, text());
      maybe(rng, op, 'state', 0.1, () => rng.pick(['not_started', 'active', '']));
      break;
    case 'promise.create':
      Object.assign(op, { op: kind, kind: rng.pick(['thread', 'mystery']), key: rng.pick(PROMISE_KEYS), label: prose(rng, story, 1, 8) || 'who rang the bell' });
      maybe(rng, op, 'openedChapter', 0.2, () => rng.int(1, 9));
      break;
    case 'promise.update':
      Object.assign(op, { op: kind, kind: rng.pick(['thread', 'mystery']), key: rng.pick(PROMISE_KEYS) });
      maybe(rng, op, 'label', 0.6, text(0, 8));
      maybe(rng, op, 'lastAdvancedChapter', 0.2, () => rng.int(1, 9));
      maybe(rng, op, 'status', 0.2, () => rng.pick(['open', 'paid_off']));
      break;
    case 'promise.set_payoff':
      Object.assign(op, { op: kind, kind: rng.pick(['thread', 'mystery']), key: rng.pick(PROMISE_KEYS) });
      if (rng.chance(0.3)) op['someday'] = true;
      else {
        if (rng.chance(0.15)) op['someday'] = false;
        maybe(rng, op, 'payoffMilestoneKey', 0.4, () => rng.pick([...MILESTONE_KEYS, null, '']));
        maybe(rng, op, 'payoffVolumeKey', 0.4, () => rng.pick([...VOLUME_KEYS, null, '']));
        maybe(rng, op, 'payoffWindow', 0.3, () => (rng.chance(0.3) ? null : rng.int(1, 5)));
      }
      maybe(rng, op, 'dormant', 0.2, () => rng.chance(0.5));
      break;
    case 'milestone.upsert':
      Object.assign(op, { op: kind, milestoneKey: rng.pick(MILESTONE_KEYS) });
      maybe(rng, op, 'label', 0.6, () => prose(rng, story, 1, 6) || 'the tower falls');
      maybe(rng, op, 'subjectEntityKey', 0.4, () => rng.pick([...ENTITY_KEYS, null, '']));
      maybe(rng, op, 'kind', 0.3, () => rng.pick(['rank', 'event', 'learned_from', 'custom']));
      break;
    case 'brief.update':
      Object.assign(op, { op: kind, chapter: rng.int(1, 6) });
      maybe(rng, op, 'title', 0.3, text(0, 4));
      maybe(rng, op, 'volumeKey', 0.3, () => rng.pick([...VOLUME_KEYS, '']));
      maybe(rng, op, 'pov', 0.3, () => rng.pick([...ENTITY_KEYS, null, '']));
      maybe(rng, op, 'scenes', 0.3, () =>
        rng.chance(0.2) ? null : Array.from({ length: rng.int(0, 2) }, () => ({ summary: prose(rng, story, 1, 4) || 'scene', pov: rng.pick([...ENTITY_KEYS, null]) })),
      );
      maybe(rng, op, 'knowledgeContract', 0.3, () =>
        rng.chance(0.2)
          ? null
          : {
              pov: [rng.pick(ENTITY_KEYS)],
              ...(rng.chance(0.6) ? { learns: Array.from({ length: rng.int(0, 2) }, () => ({ entityKey: rng.pick(ENTITY_KEYS), factKey: rng.pick(FACT_KEYS) })) } : {}),
            },
      );
      maybe(rng, op, 'claimedMilestones', 0.3, () => (rng.chance(0.2) ? null : [rng.pick(MILESTONE_KEYS)]));
      maybe(rng, op, 'contextRefs', 0.3, () => [rng.pick(['bible_doc:world/harbour', 'doc:plot/beats', 'entity:mara', 'bible_doc:', 'bible_doc'])]);
      break;
    case 'draft.update':
      Object.assign(op, { op: kind, chapter: rng.int(1, 6), body: prose(rng, story, 0, 6) });
      break;
    case 'draft.rewrite_passage':
      Object.assign(op, { op: kind, chapter: rng.int(1, 6), passage: 'the tower', replacement: prose(rng, story, 1, 4) });
      break;
    case 'volume.remove':
      Object.assign(op, { op: kind, volumeKey: rng.pick(VOLUME_KEYS) });
      break;
    case 'brief.remove':
    case 'draft.remove':
      Object.assign(op, { op: kind, chapter: rng.int(1, 6) });
      break;
    case 'entity.remove':
      Object.assign(op, { op: kind, entityKey: rng.pick(ENTITY_KEYS) });
      break;
    case 'fact.remove':
      Object.assign(op, { op: kind, factKey: rng.pick(FACT_KEYS) });
      break;
    case 'milestone.remove':
      Object.assign(op, { op: kind, milestoneKey: rng.pick(MILESTONE_KEYS) });
      break;
    case 'promise.drop':
      Object.assign(op, { op: kind, kind: rng.pick(['thread', 'mystery']), key: rng.pick(PROMISE_KEYS) });
      break;
    case 'organise.rule':
      Object.assign(op, { op: kind, rule: prose(rng, story, 1, 5) || 'rule', optionId: 'o1' });
      break;
    default:
      Object.assign(
        op,
        rng.pick<Rec>([
          { op: 'action.generate_chapter', chapter: rng.int(1, 6) },
          { op: 'action.audit_bible' },
          { op: 'action.enhance_premise' },
          { op: 'action.judge_draft', chapter: rng.int(1, 6) },
          { op: 'action.revise_draft', chapter: rng.int(1, 6), note: 'tighten' },
          { op: 'action.approve_draft', chapter: rng.int(1, 6) },
          { op: 'action.apply_continuity', chapter: rng.int(1, 6) },
          { op: 'action.validate', scope: 'chapter', chapter: rng.int(1, 6) },
          { op: 'action.validate', scope: 'novel' },
          { op: 'action.finalize', upTo: rng.int(1, 6) },
          { op: 'action.organise_notes' },
          { op: 'action.plan_chapter', chapter: rng.int(1, 6) },
          { op: 'action.plan_chapter' },
          { op: 'action.advance_volume', volumeKey: rng.pick(VOLUME_KEYS) },
        ]),
      );
  }
  const quote = rng.next();
  if (quote < 0.7) op['quote'] = quoteFrom(rng, story.message);
  else if (quote < 0.76) op['quote'] = sentence(rng);
  else if (quote < 0.8) op['quote'] = rng.pick(['', ' ', '　']);
  if (rng.chance(0.15)) op['rationale'] = 'because';
  return op;
}

function companionOp(rng: Rng, story: Story): Rec {
  const op: Rec = rng.chance(0.7)
    ? { op: 'entity.upsert', entityKey: rng.pick(ENTITY_KEYS), type: rng.pick(['location', 'concept', 'power_rule', 'faction', 'character']), name: prose(rng, story, 1, 2) }
    : { op: 'milestone.upsert', milestoneKey: rng.pick(MILESTONE_KEYS), label: prose(rng, story, 1, 4) || 'the tower falls', subjectEntityKey: rng.pick(ENTITY_KEYS) };
  if (rng.chance(0.5)) op['quote'] = quoteFrom(rng, story.message);
  return op;
}

function currentFields(rng: Rng, ref: string, story: Story): Rec {
  const value = () => (rng.chance(0.15) ? rng.pick([null, '', ' ']) : prose(rng, story, 0, rng.chance(0.25) ? 12 : 4));
  const pick = (fields: string[]): Rec => Object.fromEntries(fields.filter(() => rng.chance(0.7)).map(field => [field, value()]));
  const kind = ref.slice(0, ref.indexOf(':') === -1 ? ref.length : ref.indexOf(':'));
  const extra: Rec = rng.chance(0.15) ? { [rng.pick(['entityKey', 'factKey', 'volumeKey', 'milestoneKey', 'key', 'name', 'slug', 'section'])]: prose(rng, story, 1, 3) } : {};
  switch (kind) {
    case 'premise':
      return { ...pick(STORY_FIELDS.filter(field => field !== 'themes')), ...(rng.chance(0.4) ? { themes: rng.chance(0.3) ? [] : [prose(rng, story, 1, 3)] } : {}), ...extra };
    case 'doc':
      return { body: value(), frontmatter: rng.chance(0.5) ? null : { title: prose(rng, story, 1, 3), list: [prose(rng, story, 0, 3), 4] }, ...extra };
    case 'volume':
      return { ordinal: rng.chance(0.3) ? null : rng.int(0, 3), ...pick(['title', 'objective', 'body']), state: 'active', ...extra };
    case 'entity':
      return { type: rng.pick(ENTITY_TYPES), name: rng.pick(['Mara Vell', null, 'Tower']), ...pick(['status', 'motivation', 'notes', 'body']), ...extra };
    case 'fact':
      return {
        ...pick(['body', 'constraintNote', 'writerNote']),
        subjects: rng.chance(0.5) ? [] : [rng.pick(ENTITY_KEYS)],
        terms: rng.chance(0.4) ? [] : [prose(rng, story, 1, 3)],
        revealChapter: rng.chance(0.5) ? null : 3,
        unlock: null,
        allowedClues: rng.chance(0.5) ? null : [],
        ...extra,
      };
    case 'milestone':
      return { label: value(), subjectEntityKey: rng.chance(0.5) ? null : 'mara', kind: 'event', ...extra };
    case 'promise':
      return {
        label: value(),
        lastAdvancedChapter: rng.chance(0.5) ? null : 2,
        status: rng.pick(['open', 'open', 'paid_off', 'dropped']),
        payoffMilestoneKey: rng.chance(0.6) ? null : rng.pick(['m1', '', ' ']),
        payoffVolumeKey: rng.chance(0.7) ? null : 'v1',
        payoffWindow: rng.chance(0.7) ? null : rng.pick([0, 2]),
        dormant: rng.chance(0.2),
        ...extra,
      };
    default:
      return extra;
  }
}

const isValid = (ops: Rec[]): boolean => (changeSet.validateChangeSet(JSON.parse(JSON.stringify(ops)), undefined, { entityMaterialization: false }) as string[]).length === 0;

const encodeDisposition = (d: { side: string; source?: string; reason?: string; rule?: string }): string =>
  d.side === 'direct' ? `d:${d.source}` : d.rule ? `c:${d.reason}:${d.rule}` : `c:${d.reason}`;

const policyCases: unknown[] = [];

interface Options {
  vocabulary?: string;
  mode?: string;
  ideas?: string;
  justDiscussing?: boolean;
  hold?: string;
}

function recordPolicy(ops: Rec[], message: string, current: [string, string][], options: Options): void {
  if (!isValid(ops)) throw new Error(`invalid scenario ${JSON.stringify(ops)}`);
  const raw = JSON.stringify(ops);
  const parsed = JSON.parse(raw);
  changeSet.validateChangeSet(parsed, undefined, { entityMaterialization: false });
  const state = { current: new Map(current.map(([ref, fields]) => [ref, JSON.parse(fields)])) };
  const { vocabulary, mode = 'auto', ideas, justDiscussing, hold = 'none' } = options;
  const split = policy.splitChangeSet({ ops: parsed, authorMessage: message, vocabulary, mode, ideas, justDiscussing, hold, state });
  const words = vocabulary ?? message;
  const perOp = parsed.map((op: Rec) => {
    const [ref] = changeSet.changeSetRefs([op]);
    const fields = ref === undefined ? undefined : state.current.get(ref);
    return [
      policy.alwaysCardRule(op, state) ?? null,
      policy.ideaCardRule(op) ?? null,
      policy.isPlannerSide(op),
      policy.opReferences(op),
      policy.launders(op, fields, words),
      policy.exceedsNoveltyBudget(op, fields, words),
      policy.exceedsRemovalBudget(op, fields),
    ];
  });
  policyCases.push([
    raw,
    message,
    vocabulary ?? null,
    mode,
    ideas ?? null,
    justDiscussing ?? null,
    hold,
    current,
    split.dispositions.map(encodeDisposition),
    split.held,
    split.sources,
    perOp,
  ]);
}

const said = 'The tower falls at dawn and Mara keeps the lantern burning. The harbour guild smuggles salt through the marsh.';
const quote = 'Mara keeps the lantern burning';
const page = (section: string, slug: string, body: string, extra: Rec = {}): Rec => ({ op: 'bible_document.upsert', section, slug, body, ...extra });
const entity = (entityKey: string, type: string, extra: Rec = {}): Rec => ({ op: 'entity.upsert', entityKey, type, ...extra });
const milestone = (milestoneKey: string, extra: Rec = {}): Rec => ({ op: 'milestone.upsert', milestoneKey, ...extra });
const fields = (value: Rec): string => JSON.stringify(value);
const SCENARIOS: [Rec[], string, [string, string][], Options][] = [
  [[entity('mara', 'character', { body: 'tower lantern' }), entity('mara', 'character', { notes: 'keeps the lantern burning', quote })], said, [], {}],
  [[{ op: 'entity.remove', entityKey: 'vell' }, milestone('m1', { label: 'tower falls' }), milestone('m1', { label: 'tower falls at dawn', subjectEntityKey: 'vell' })], said, [], { ideas: 'apply' }],
  [[{ op: 'fact.upsert', factKey: 'f1', body: 'smuggles salt' }, entity('vell', 'character', { name: 'Vell', notes: 'smuggles salt' }), milestone('m1', { label: 'tower falls at dawn', subjectEntityKey: 'vell' })], said, [['entity:vell', fields({ name: 'Vell' })]], { ideas: 'apply' }],
  [[entity('dawn', 'location', { name: 'Dawn' }), page('world', 'setting-overview', 'The tower falls at dawn', { quote: 'The tower falls at dawn' })], said, [], {}],
  [
    [entity('dawn', 'location', { name: 'Dawn' }), entity('salt', 'concept', { name: 'Salt', quote: 'guild smuggles salt through the marsh' }), page('world', 'setting-overview', 'The tower falls', { quote: 'The tower falls at dawn' })],
    said, [], {},
  ],
  [[page('world', 'harbour', 'salt through the marsh', { quote: 'smuggles salt through the marsh' }), entity('guild', 'faction')], said, [], {}],
  [[page('project', 'cast', 'Mara keeps the lantern', { quote }), entity('mara', 'character', { name: 'Mara' })], said, [], {}],
  [[page('project', 'cast', '   ', { quote }), entity('mara', 'character', { name: 'Mara' })], said, [], {}],
  [[milestone('m1', { label: 'tower falls at dawn' }), entity('mara', 'character', { notes: 'keeps the lantern burning', quote })], said, [], { hold: 'writer_read', ideas: 'apply' }],
  [[milestone('m1', { label: 'tower falls at dawn' }), entity('mara', 'character', { notes: 'keeps the lantern burning', quote })], said, [], { hold: 'turn', ideas: 'apply' }],
  [[{ op: 'entity.remove', entityKey: 'mara' }], said, [], { hold: 'turn' }],
  [[entity('mara', 'character', { notes: 'keeps the lantern burning', quote })], said, [], { justDiscussing: true, hold: 'turn' }],
  [[entity('mara', 'character', { notes: 'keeps the lantern burning', quote })], said, [], { mode: 'manual', hold: 'writer_read' }],
  [[entity('mara', 'character', { notes: 'keeps the lantern burning', quote })], said, [], { justDiscussing: false }],
  [[{ op: 'promise.set_payoff', kind: 'thread', key: 'p1', someday: true }], said, [['promise:thread:p1', fields({ status: 'open', payoffWindow: 0 })]], {}],
  [[{ op: 'promise.set_payoff', kind: 'thread', key: 'p1', someday: true }], said, [['promise:thread:p1', fields({ status: 'open', payoffMilestoneKey: ' ' })]], {}],
  [[{ op: 'promise.set_payoff', kind: 'thread', key: 'p1', payoffMilestoneKey: null }], said, [['promise:thread:p1', fields({ payoffMilestoneKey: 'm1' })]], {}],
  [[{ op: 'promise.set_payoff', kind: 'mystery', key: 'p1', payoffVolumeKey: 'v1', payoffMilestoneKey: 'm2' }], said, [], {}],
  [[{ op: 'premise.update', premise: '', quote }], said, [['premise', fields({ premise: 'The tower' })]], {}],
  [[{ op: 'premise.update', themes: [], quote }], said, [['premise', fields({ themes: ['salt'] })]], {}],
  [[{ op: 'premise.update', theme: 'Mara keeps the lantern burning', quote }], said, [['premise', fields({ theme: 'old' })]], {}],
  [[{ op: 'premise.update', theme: 'Mara keeps the lantern burning', quote }], said, [['premise', fields({ theme: ' ', premise: 'x' })]], {}],
  [[{ op: 'volume.upsert', volumeKey: 'v1', body: 'notes', quote }], said, [], {}],
  [[{ op: 'volume.upsert', volumeKey: 'v1', ordinal: 2, quote }], said, [['volume:v1', fields({ ordinal: 1 })]], {}],
  [[{ op: 'volume.upsert', volumeKey: 'v1', ordinal: 2, title: 'tower', quote }], said, [], { ideas: 'apply' }],
  [[{ op: 'volume.upsert', volumeKey: 'v1', objective: 'the tower falls', quote: 'unrelated words entirely here' }], said, [], { ideas: 'apply' }],
  [[{ op: 'fact.upsert', factKey: 'f1', body: 'Mara keeps the lantern burning', quote }], said, [['fact:f1', fields({ body: 'old' })]], {}],
  [[{ op: 'fact.upsert', factKey: 'f1', body: 'Mara keeps the lantern burning', quote }], said, [], {}],
  [[{ op: 'fact.upsert', factKey: 'f1', writerNote: 'x', quote }], said, [], {}],
  [[{ op: 'fact.upsert', factKey: 'f1', revealChapter: null, quote }], said, [], {}],
  [[{ op: 'fact.upsert', factKey: 'f1', terms: ['lantern'], quote }], said, [['fact:f1', fields({ terms: [] })]], {}],
  [[{ op: 'fact.upsert', factKey: 'f1', terms: ['lantern'], quote }], said, [], {}],
  [[{ op: 'fact.upsert', factKey: 'f1', subjects: ['mara'], unlock: { all: [{ milestone: 'm1' }, { volume: 'v2' }, { chapter: 3 }, { ending: true }] } }], said, [], {}],
  [[{ op: 'promise.create', kind: 'thread', key: 'p1', label: 'lantern burning', quote }], said, [['promise:thread:p1', fields({ status: 'open' })]], {}],
  [[{ op: 'promise.create', kind: 'thread', key: 'p1', label: 'lantern burning', quote }], said, [['promise:thread:p1', fields({ status: 'dropped' })]], {}],
  [[{ op: 'promise.create', kind: 'thread', key: 'p1', label: 'lantern burning', quote }], said, [['promise:thread:p1', fields({})]], {}],
  [[{ op: 'promise.update', kind: 'thread', key: 'p1', status: 'open', lastAdvancedChapter: 2 }], said, [], {}],
  [[{ op: 'promise.update', kind: 'thread', key: 'p1', lastAdvancedChapter: 2 }], said, [], {}],
  [[entity('mara', 'character', { body: 'Mara keeps the lantern burning while queens betray smugglers across winter floods and iron crowns', quote })], said, [], {}],
  [[entity('mara', 'character', { body: 'Mara keeps the lantern burning while queens betray smugglers across winter floods and iron crowns', quote })], said, [], { ideas: 'apply' }],
  [[entity('mara', 'character', { body: 'lantern', quote })], said, [['entity:mara', fields({ body: 'harbour guild smuggles salt through the marsh tower dawn' })]], {}],
  [[entity('mara', 'character', { body: 'lantern', quote })], said, [['entity:mara', fields({ body: 'harbour guild smuggles salt through the marsh tower dawn' })]], { ideas: 'apply' }],
  [[entity('mara', 'character', { body: 'Mara keeps the lantern burning for the queen', quote })], 'Mara keeps the lantern burning. Maybe the queen betrays her?', [], {}],
  [[entity('mara', 'character', { body: 'Mara keeps the lantern burning', quote })], 'Mara never keeps the lantern burning.', [], {}],
  [[entity('mara', 'character', { body: 'Mara keeps the lantern burning', quote })], 'No, Mara keeps the lantern burning.', [], {}],
  [[entity('mara', 'character', { body: 'Mara keeps the lantern burning', quote })], 'Mara keeps the lantern burning instead.', [], {}],
  [[entity('mara', 'character', { body: 'Mara keeps the lantern burning', quote })], 'Instead, Mara keeps the lantern burning.', [], {}],
  [[entity('mara', 'character', { body: 'Mara keeps the lantern burning', quote })], 'Does Mara keep the lantern? Mara keeps the lantern burning', [], {}],
  [[entity('mara', 'character', { body: 'Mara keeps the lantern burning near salt marsh', quote })], said, [], { vocabulary: 'Mara keeps the lantern burning. Salt marsh.' }],
  [[entity('mara', 'character', { body: 'Mara keeps the lantern burning near salt marsh', quote })], said, [], { vocabulary: '' }],
  [[entity('mara', 'character', { name: 'Lantern Keeper', body: 'lantern keeper burning', quote })], said, [], {}],
  [[entity('mara', 'character', { body: 'mara mara', quote })], said, [['entity:mara', fields({ entityKey: 'mara', name: 'Mara' })]], {}],
  [[entity('mara', 'character', { body: 'Mara keeps the lantern burning', quote: '  ' })], said, [], {}],
  [[entity('mara', 'character', { body: 'Mara keeps the lantern burning', quote: 'the lantern' })], said, [], {}],
  [[{ op: 'organise.rule', rule: 'r', optionId: 'o', quote }], said, [], { ideas: 'apply' }],
  [[{ op: 'brief.update', chapter: 2, pov: 'mara', volumeKey: 'v1', contextRefs: ['bible_doc:world/harbour', 'doc:x', 'bible_doc:'], claimedMilestones: ['m1'], scenes: [{ summary: 's', pov: 'vell' }, { summary: 't', pov: null }], knowledgeContract: { pov: ['mara'], learns: [{ entityKey: 'vell', factKey: 'f1' }] } }], said, [], {}],
  [[{ op: 'action.plan_chapter', chapter: 3 }, { op: 'action.advance_volume', volumeKey: 'v2' }, { op: 'action.validate', scope: 'novel' }], said, [], {}],
  [[page('story_state', 'volumes', 'tower', { quote }), page('project', 'timeline', 'tower', { quote }), page('project', 'premise', 'Mara keeps the lantern burning', { quote })], said, [], {}],
  [[{ op: 'draft.update', chapter: 2, body: 'x' }, entity('mara', 'character', { notes: 'keeps the lantern burning', quote }), { op: 'brief.update', chapter: 2, pov: 'mara' }], said, [], {}],
];

const dawn = 'The tower falls at dawn and Mara keeps the lantern burning.';
for (const [key, type, section, slug] of [
  ['guild', 'faction', 'world', 'factions-and-locations'],
  ['mara', 'character', 'project', 'cast'],
]) {
  const unquoted = entity(key, type, { quote: 'unrelated quote words here' });
  const quoted = entity(key, type, { notes: 'keeps the lantern burning', quote });
  const body = page(section, slug, quote, { quote });
  for (const hold of ['none', 'writer_read']) {
    SCENARIOS.push([[unquoted, quoted, body], dawn, [], { hold }]);
    SCENARIOS.push([[body, unquoted, quoted], dawn, [], { hold }]);
  }
}

for (const [ops, message, current, options] of SCENARIOS) recordPolicy(ops, message, current, options);

const policyRng = createRng(0xd11);
for (let i = 0; i < 270; i++) {
  const rng = policyRng;
  const clean = rng.chance(0.4);
  const message = !clean && rng.chance(0.08) ? rng.pick(FIXED_TEXTS) : text(rng, WORDS, clean ? 4 : 6, clean);
  const story: Story = { message, words: message.split(/[\s,;:()、.!?。！？"'”’」』]+/).filter(Boolean), clean };
  if (story.words.length === 0) story.words.push('tower');
  const ops: Rec[] = [];
  const target = rng.int(1, 6);
  for (let attempt = 0; attempt < target * 4 && ops.length < target; attempt++) {
    ops.push(contentOp(rng, story));
    if (!isValid(ops)) ops.pop();
    if (rng.chance(0.2)) ops.push(companionOp(rng, story));
    if (!isValid(ops)) ops.pop();
  }
  if (ops.length === 0) continue;
  const parsed = JSON.parse(JSON.stringify(ops));
  changeSet.validateChangeSet(parsed, undefined, { entityMaterialization: false });
  const refs: string[] = [...changeSet.changeSetRefs(parsed), ...parsed.flatMap((op: Rec) => policy.opReferences(op))];
  const current: [string, string][] = [];
  for (const ref of new Set(refs)) if (rng.chance(0.5)) current.push([ref, JSON.stringify(currentFields(rng, ref, story))]);
  if (rng.chance(0.03) && current.length > 0) current.push([current[0]![0], JSON.stringify(currentFields(rng, current[0]![0], story))]);
  recordPolicy(ops, message, current, {
    vocabulary: rng.chance(0.6) ? undefined : rng.chance(0.1) ? '' : `${message}${rng.pick(GAPS)}${text(rng, WORDS, 3)}`,
    mode: rng.chance(0.9) ? 'auto' : 'manual',
    ideas: rng.pick([undefined, 'apply', 'apply', 'card']),
    justDiscussing: rng.pick([undefined, undefined, false, false, false, false, false, true]),
    hold: rng.pick(['none', 'none', 'turn', 'writer_read', 'writer_read']),
  });
}

const tables = {
  direct: [...policy.DIRECT_OP_KINDS],
  alwaysCard: Object.entries(policy.ALWAYS_CARD),
  ideaPolicy: Object.entries(policy.IDEA_POLICY),
  sources: [...policy.OP_SOURCES],
};

const DOC_SECTIONS = [...SECTIONS, 'Project', 'doc:project', '', 'unknown'];
const DOC_SLUGS = [
  'timeline', 'open-questions', 'volume-plan', 'volumes', 'escalation-map', 'premise', 'cast', 'Timeline', 'timeline ', ' timeline', 'open_questions', 'volume-plan/x', '',
  'time\u200bline', 'ti\u0301meline', 'tímeline',
];
const docs = {
  organisedTimeline: bibleDocs.ORGANISED_TIMELINE_DOC,
  openQuestions: bibleDocs.OPEN_QUESTIONS_DOC,
  access: DOC_SECTIONS.flatMap(section =>
    DOC_SLUGS.map(slug => {
      const access = bibleDocs.bibleDocAccess({ section, slug });
      if (access.writerExcluded !== bibleDocs.isWriterExcludedBibleDoc({ section, slug }) || access.plannerOnly !== bibleDocs.isPlannerOnlyBibleDoc({ section, slug })) {
        throw new Error('bibleDocAccess disagrees with its predicates');
      }
      return [section, slug, access.writerExcluded, access.plannerOnly];
    }),
  ),
};

const write = (name: string, value: unknown): void => writeFileSync(join(outDir, name), JSON.stringify(value) + '\n');
write('text.json', { texts: textCases, quotes: quoteCases });
write('policy.json', { tables, cases: policyCases });
write('bible-docs.json', docs);
