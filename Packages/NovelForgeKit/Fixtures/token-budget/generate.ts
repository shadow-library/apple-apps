import { plugin } from 'bun';
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');

const outDir = dirname(fileURLToPath(import.meta.url));
const budgetModule = join(platformRepo, 'apps/novel-forge-server/src/modules/ai/context/token-budget.ts');
const tiktokenEntry = join(platformRepo, 'node_modules/.bun/js-tiktoken@1.0.21/node_modules/js-tiktoken/dist/index.js');

const { getEncoding } = await import(tiktokenEntry);
const o200k = getEncoding('o200k_base');
const exactTokens = (text: string): number => (text ? o200k.encode(text).length : 0);

const HUNDREDTHS_PER_TOKEN = 100;

type RunKind = 'letter' | 'digit' | 'space' | 'control' | 'symbol' | 'wide' | 'alphabetic' | 'otherBmp' | 'astral';

function kindOf(code: number): RunKind {
  if (code < 0x80) {
    if ((code >= 0x41 && code <= 0x5a) || (code >= 0x61 && code <= 0x7a)) return 'letter';
    if (code >= 0x30 && code <= 0x39) return 'digit';
    if (code === 0x20) return 'space';
    if (code < 0x20 || code === 0x7f) return 'control';
    return 'symbol';
  }
  if (code >= 0x10000) return 'astral';
  if ((code >= 0x3040 && code <= 0x30ff) || (code >= 0x3400 && code <= 0x9fff) || (code >= 0xac00 && code <= 0xd7af) || (code >= 0xf900 && code <= 0xfaff)) return 'wide';
  if (code <= 0x2fff && /^\p{L}$/u.test(String.fromCodePoint(code))) return 'alphabetic';
  return 'otherBmp';
}

function runCost(kind: RunKind, length: number): number {
  switch (kind) {
    case 'letter': return 110 + 65 * Math.max(0, Math.ceil((length - 9) / 8));
    case 'digit': return 125 * Math.ceil(length / 3);
    case 'space': return length === 1 ? 0 : 50 + 5 * length;
    case 'control': return 105 + 10 * length;
    case 'symbol': return 80 + 25 * length;
    case 'wide': return 100 * length;
    case 'alphabetic': return 45 * length;
    case 'otherBmp': return 100 * length;
    case 'astral': return 250 * length;
  }
}

const RUN_KINDS: readonly RunKind[] = ['letter', 'digit', 'space', 'control', 'symbol'];

function estimateTokens(text: string): number {
  let sum = 0;
  let kind: RunKind | null = null;
  let length = 0;
  for (const char of text) {
    const next = kindOf(char.codePointAt(0) ?? 0);
    if (next === kind && RUN_KINDS.includes(next)) {
      length += 1;
      continue;
    }
    if (kind !== null) sum += runCost(kind, length);
    kind = next;
    length = 1;
  }
  if (kind !== null) sum += runCost(kind, length);
  return Math.ceil(sum / HUNDREDTHS_PER_TOKEN);
}

plugin({
  name: 'token-budget-fixture-stubs',
  setup(build) {
    build.module('js-tiktoken', () => ({ exports: { getEncoding: () => ({ encode: (text: string) => ({ length: estimateTokens(text) }) }) }, loader: 'object' }));
  },
});

const reference = await import(budgetModule);

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
    chance: (p) => next() < p,
    pick: (items) => items[Math.floor(next() * items.length)] as never,
  };
}

const rng = createRng(20260611);

const WORDS = ('the a of and to in he she it was had were that with for on as at by from his her they them there then when what which who whom would could should '
  + 'lighthouse keeper stairs window grey sea sky morning lantern harbour captain letter promise winter river bridge silence shadow memory garden kitchen mother brother '
  + 'walked climbed whispered remembered carried opened closed turned waited listened wondered believed forgot answered followed slowly quietly suddenly always never '
  + 'old young cold long narrow bright empty heavy small distant familiar broken careful quiet').split(' ');
const CJK = ['灯塔守护者慢慢地爬上楼梯', '像四十年来每天做的那样', '数着每一步', '窗外是灰色的大海', '他想起了母亲的信', 'これは日本語の文章です', 'ひらがなとカタカナと漢字', '今日は天気がいいですね', '안녕하세요 오늘은 날씨가 좋습니다', '우리 함께 산책하러 가요'];
const EMOJI = ['😀', '🎉', '🔥', '👍🏽', '❤️', '🚀', '👩‍👩‍👧', '🇯🇵', '🧑🏽‍💻', '𝒳', '𠮷'];
const CYRILLIC = ['Старый смотритель маяка', 'медленно поднимался по лестнице', 'считая каждую ступеньку', 'Élodie préfère les crêpes', 'là où l’été est déjà très chaud', 'كان حارس المنارة العجوز يصعد السلم'];
const CODE = ['function foo(a: number, b: string): Promise<void> {', '  return bar(a)?.baz[b] ?? null;', '}', 'const items = list.filter((x) => x.id !== id).map(String);', 'SELECT id, title FROM chapters WHERE novel_id = $1 ORDER BY number;', 'https://example.com/path/to/resource?query=value&other=thing#fragment'];

function sentence(words: number): string {
  const parts: string[] = [];
  for (let i = 0; i < words; i++) parts.push(rng.pick(WORDS));
  const text = parts.join(' ');
  return `${text.charAt(0).toUpperCase()}${text.slice(1)}${rng.pick(['.', '.', '.', '!', '?', ', and then.'])}`;
}

function paragraph(sentences: number): string {
  const out: string[] = [];
  for (let i = 0; i < sentences; i++) out.push(sentence(rng.int(5, 18)));
  return out.join(' ');
}

function prose(paragraphs: number, separator = '\n\n'): string {
  const out: string[] = [];
  for (let i = 0; i < paragraphs; i++) out.push(paragraph(rng.int(1, 5)));
  return out.join(separator);
}

function mixed(pool: readonly string[], count: number, joiner: string): string {
  const out: string[] = [];
  for (let i = 0; i < count; i++) out.push(rng.pick(pool));
  return out.join(joiner);
}

function hex(length: number): string {
  let out = '';
  for (let i = 0; i < length; i++) out += '0123456789abcdef'[rng.int(0, 15)];
  return out;
}

interface CorpusEntry {
  id: string;
  category: string;
  text: string;
}

const NARRATIVE = [
  'Marta reached the harbour at dusk, when the fishing boats were already tied up and the gulls had gone quiet on the roofs. She carried one bag and a letter she had not yet decided to deliver. The ferryman looked at her boots, then at her face, and said nothing at all, which she took as a kindness.\n\nThe inn was at the end of the quay, its windows yellow against the grey water. Inside, a fire burned low and three men argued about the price of salt as though it were a matter of honour.',
  '"You are late," said the old woman, without turning from the stove. "The soup went cold an hour ago, and so did my patience." Tomas set his satchel on the floor and tried to look sorry. It was not hard; his feet ached, his coat was soaked through, and he had lost the map somewhere between the mill and the bridge.\n\n"I took the wrong road," he admitted. "Twice."\n\nShe laughed then, a short dry sound, and pushed a bowl across the table toward him.',
  'There are rooms in every house that people stop entering without ever deciding to. In the house on Alder Street it was the small one at the top of the stairs, where the sewing machine still stood under its cloth and the window looked onto nothing but the neighbour\'s wall. Nobody had forbidden it. They simply walked past, year after year, a little more quietly each time.',
  'The expedition left in March, when the passes were still treacherous, because the captain feared that waiting would cost them more than the snow. By the second week the mules had begun to falter. By the third, two of the porters had turned back, and the maps, drawn by a man who had never seen the range, proved as useful as a rumour. Still they climbed, and still, each evening, someone read aloud from the one book they had thought to bring.',
  'He had expected the city to feel larger. Instead it pressed in on him: the narrow streets, the shuttered shops, the smell of rain on hot stone. A boy ran past with a loaf under his arm, shouting something he could not catch, and for a moment Elias stood very still, remembering the village, the river, the way his sister used to call him in for supper.',
  'Chapter Twelve opens in the weeks after the funeral. Ada keeps the shop open out of habit, not hope, and each morning she rearranges the same shelf of jars. Nobody comes in. Nobody needs to; the street has quietly decided to leave her alone, and she does not know whether to be grateful or hurt.',
];

const corpus: CorpusEntry[] = [];
const add = (category: string, text: string): void => {
  corpus.push({ id: `${category}-${corpus.filter((entry) => entry.category === category).length}`, category, text });
};

for (const text of NARRATIVE) add('narrative', text);
for (let i = 0; i < 14; i++) add('prose', prose(rng.int(1, 4)));
for (let i = 0; i < 3; i++) add('prose-long', prose(rng.int(18, 30)));
for (let i = 0; i < 6; i++) add('cjk', mixed(CJK, rng.int(2, 12), rng.pick(['', '，', ' '])));
for (let i = 0; i < 4; i++) add('cyrillic-accents-arabic', mixed(CYRILLIC, rng.int(2, 8), ' '));
for (let i = 0; i < 4; i++) add('emoji', mixed(EMOJI, rng.int(3, 40), rng.pick(['', ' '])));
for (let i = 0; i < 6; i++) add('code', mixed(CODE, rng.int(2, 10), '\n'));
for (let i = 0; i < 4; i++) add('digits', Array.from({ length: rng.int(3, 12) }, () => String(rng.int(0, 999999999))).join(rng.pick([' ', ', ', '-'])));
for (let i = 0; i < 3; i++) add('identifiers', Array.from({ length: rng.int(2, 6) }, () => hex(rng.int(16, 64))).join(' '));
add('whitespace', ' '.repeat(200));
add('whitespace', ' '.repeat(2000));
add('whitespace', '\n'.repeat(300));
add('whitespace', '\n\n'.repeat(150));
add('whitespace-exotic', '\t \u00a0\u2003 \u3000\r\n'.repeat(40));
add('whitespace', `${prose(3)}${'\n'.repeat(40)}${prose(2)}`);
for (let i = 0; i < 4; i++) add('mixed', `${prose(2)}\n\n${mixed(CJK, 3, '')} ${mixed(EMOJI, 4, '')}\n${mixed(CODE, 3, '\n')}`);

const entries = corpus.map((entry) => ({ ...entry, o200k: exactTokens(entry.text), estimate: estimateTokens(entry.text), codePoints: Array.from(entry.text).length }));

interface Band {
  category: string;
  samples: number;
  minRatio: number;
  maxRatio: number;
  aggregateRatio: number;
}

const bands: Band[] = [];
for (const category of [...new Set(entries.map((entry) => entry.category))]) {
  const group = entries.filter((entry) => entry.category === category);
  const ratios = group.map((entry) => entry.estimate / entry.o200k);
  const round = (value: number): number => Math.round(value * 1000) / 1000;
  bands.push({
    category,
    samples: group.length,
    minRatio: round(Math.min(...ratios)),
    maxRatio: round(Math.max(...ratios)),
    aggregateRatio: round(group.reduce((sum, entry) => sum + entry.estimate, 0) / group.reduce((sum, entry) => sum + entry.o200k, 0)),
  });
}

const truncationTexts: { id: string; text: string }[] = [
  { id: 'empty', text: '' },
  { id: 'spaces', text: '     ' },
  { id: 'newlines', text: '\n\n\n\n' },
  { id: 'single-word', text: 'Supercalifragilisticexpialidocious' },
  { id: 'one-paragraph', text: paragraph(4) },
  { id: 'two-paragraphs', text: prose(2) },
  { id: 'many-paragraphs', text: prose(10) },
  { id: 'many-paragraphs-long', text: prose(14) },
  { id: 'triple-breaks', text: `${paragraph(2)}\n\n\n\n${paragraph(2)}\n\n\n${paragraph(1)}` },
  { id: 'crlf', text: prose(4, '\r\n\r\n') },
  { id: 'crlf-lines', text: prose(3, '\r\n') },
  { id: 'single-newlines', text: prose(4, '\n') },
  { id: 'leading-break', text: `\n\n${prose(3)}` },
  { id: 'trailing-break', text: `${prose(3)}\n\n` },
  { id: 'leading-space', text: `   ${paragraph(2)}` },
  { id: 'trailing-space', text: `${paragraph(2)}   ` },
  { id: 'unicode-whitespace', text: 'alpha\u00a0beta\u2003gamma\u3000delta\ufeffepsilon zeta\u2028eta\u2029theta' },
  { id: 'huge-paragraph', text: paragraph(30) },
  { id: 'huge-word', text: hex(500) },
  { id: 'cjk-paragraph', text: mixed(CJK, 30, '') },
  { id: 'cjk-paragraphs', text: mixed(CJK, 24, '\n\n') },
  { id: 'cjk-spaced', text: mixed(CJK, 20, ' ') },
  { id: 'emoji-run', text: mixed(EMOJI, 40, '') },
  { id: 'emoji-words', text: mixed(EMOJI, 30, ' ') },
  { id: 'astral-paragraphs', text: `${mixed(EMOJI, 12, '')}\n\n${mixed(EMOJI, 12, ' ')}\n\n${mixed(EMOJI, 12, '')}` },
  { id: 'combining', text: 'cafe\u0301 nai\u0308ve re\u0301sume\u0301 \u0645\u0631\u062d\u0628\u0627 a\u0300\u0301\u0302 '.repeat(12) },
  { id: 'code', text: mixed(CODE, 16, '\n') },
  { id: 'code-paragraphs', text: mixed(CODE, 14, '\n\n') },
  { id: 'mixed-scripts', text: `${paragraph(2)}\n\n${mixed(CJK, 6, '')}\n\n${mixed(EMOJI, 8, ' ')}\n\n${mixed(CYRILLIC, 4, ' ')}` },
  { id: 'long-word-then-prose', text: `${hex(300)}\n\n${paragraph(3)}` },
  { id: 'prose-then-long-word', text: `${paragraph(3)}\n\n${hex(300)}` },
];

interface TruncationCase {
  text: string;
  maxTokens: number;
  head: { text: string; truncated: boolean };
  tail: { text: string; truncated: boolean };
  leading: string;
  trailing: string;
}

const truncation: { id: string; estimate: number; cases: TruncationCase[] }[] = truncationTexts.map(({ id, text }) => {
  const total = estimateTokens(text);
  const budgets = [...new Set([0, 1, 3, 8, 21, 60, 200, total - 1, total, total + 1, Math.floor(total / 2)])].filter((budget) => budget >= 0).sort((a, b) => a - b);
  const cases = budgets.map((maxTokens) => ({
    maxTokens,
    head: reference.truncateAtParagraph(text, maxTokens),
    tail: reference.truncateAtParagraphTail(text, maxTokens),
    leading: reference.leadingChars(text, maxTokens),
    trailing: reference.trailingChars(text, maxTokens),
  }));
  return { id, text, estimate: total, cases } as never;
});

interface SectionInput {
  key: string;
  tokens: number;
  required?: boolean;
  priority?: number;
}

const budgetCases: { sections: SectionInput[]; budget: number; fitting: number[]; omitted: unknown[] }[] = [];
for (let i = 0; i < 400; i++) {
  const count = i < 4 ? i : rng.int(1, 8);
  const sections: SectionInput[] = [];
  for (let s = 0; s < count; s++) {
    const section: SectionInput = { key: rng.chance(0.1) && s > 0 ? (sections[0]?.key ?? 'dup') : `section-${s}`, tokens: rng.chance(0.15) ? 0 : rng.int(1, 300) };
    if (rng.chance(0.25)) section.required = true;
    else if (rng.chance(0.1)) section.required = false;
    if (rng.chance(0.55)) section.priority = rng.int(0, 4);
    sections.push(section);
  }
  const total = sections.reduce((sum, section) => sum + section.tokens, 0);
  const budget = rng.pick([0, -5, 1, rng.int(1, 120), rng.int(1, 400), total, total - 1, total + 1, rng.int(0, Math.max(total, 1))]);
  const result = reference.applyBudget(sections, budget);
  budgetCases.push({ sections, budget, fitting: result.fitting.map((section: SectionInput) => sections.indexOf(section)), omitted: result.omitted });
}

const output = {
  model: 'runs-v1',
  corpus: entries,
  bands,
  truncation,
  budgets: budgetCases,
};

writeFileSync(join(outDir, 'token-budget.json'), `${JSON.stringify(output)}\n`);
console.log(JSON.stringify(bands, null, 1));
