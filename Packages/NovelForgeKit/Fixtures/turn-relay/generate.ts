import { plugin } from 'bun';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');

const server = join(platformRepo, 'apps/novel-forge-server/src');

plugin({
  name: 'turn-relay-fixture-stubs',
  setup(build) {
    const silent = { warn() {}, debug() {}, info() {}, error() {} };
    build.module('@shadow-library/common', () => ({ exports: { Logger: { getLogger: () => silent } }, loader: 'object' }));
    build.module('@server/constants', () => ({ exports: { APP_NAME: 'fixture' }, loader: 'object' }));
  },
});

const { ReplyStreamScanner } = await import(join(server, 'modules/ai/reply-stream-scanner.ts'));
const { EmitterRelay, describeStreamedChange } = await import(join(server, 'modules/refinement/chat-turn-emitter.ts'));
const { TurnEventLog } = await import(join(server, 'modules/refinement/turn-event-log.ts'));

// `ReplyStreamRelay` is not exported: its declaration, with the sentence helpers before it, is read from the reference and run as written.
const routerSource = readFileSync(join(server, 'modules/ai/model-router.service.ts'), 'utf8');
const relayStart = routerSource.indexOf('const SENTENCE_END');
const relayEnd = routerSource.indexOf('@Injectable()', relayStart);
if (relayStart < 0 || relayEnd < 0) throw new Error('ReplyStreamRelay was not found in model-router.service.ts');
const relaySource = new Bun.Transpiler({ loader: 'ts' }).transformSync(routerSource.slice(relayStart, relayEnd));
const ReplyStreamRelay = new Function('ReplyStreamScanner', `${relaySource}\nreturn ReplyStreamRelay;`)(ReplyStreamScanner) as new (
  handlers: { onDelta(text: string): void; onChange(change: { index: number; element: unknown }): void; onReset(): void },
  onSinkError: (err: unknown) => void,
  refuses?: (text: string) => boolean,
) => { push(chunk: string): void; restart(): void; settle(raw: string): void; readonly replyFound: boolean };

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

const VETO = 'VETO';
const refuses = (text: string): boolean => text.includes(VETO);

// Reply atoms as they appear inside the JSON string: escapes, astral text, sentence ends and their closers.
const REPLY_ATOMS = [
  'the bell rang ',
  'Mara ',
  'tide and ash ',
  '. ',
  '.',
  '! ',
  '? ',
  '...',
  '\\n',
  '\\n\\n',
  '.\\"',
  '.\\" ',
  ".' ",
  '.” ',
  '!’ ',
  '.) ',
  '.] ',
  '?\\")] ',
  '\\"quoted\\" ',
  '\\\\ ',
  '\\t',
  '\\u00e9',
  '\\u002E ',
  '\\ud83d\\ude00',
  '😀',
  '𝒜 ',
  '日本語。',
  'e\\u0301 ',
  ' ',
  '\\u2028',
  '1.5 ',
  VETO + ' ',
  'VE',
  'TO ',
];

const OPS = [
  'premise.update',
  'organise.rule',
  'action.plan_chapter',
  'action.organise_notes',
  'volume.create',
  'milestone.update',
  'promise.create',
  'brief.update',
  'draft.rewrite',
  'bible_document.upsert',
  'entity.upsert',
  'fact.upsert',
];

function replyText(rng: Rng, atoms: number, veto: boolean): string {
  let out = '';
  for (let i = 0; i < atoms; i++) {
    const atom = rng.pick(REPLY_ATOMS);
    out += !veto && atom.includes('VE') ? 'calm ' : atom;
  }
  return out;
}

function quoted(text: string): string {
  return JSON.stringify(text);
}

function changeElement(rng: Rng, veto: boolean): string {
  const op = rng.pick(OPS);
  const members: string[] = [`"op":${quoted(op)}`];
  const word = (): string => rng.pick(['Mara', '  Tide  ', 'ash\tgrove', '', ' ', 'Old Keep', veto && rng.chance(0.3) ? 'VETO hall' : 'Keep', '😀 star']);
  switch (op) {
    case 'premise.update':
      for (const field of ['premise', 'theme', 'readerPromise', 'ending', 'brief', 'opposition']) if (rng.chance(0.3)) members.push(`${quoted(field)}:${quoted(word())}`);
      break;
    case 'volume.create':
      if (rng.chance(0.5)) members.push(`"title":${quoted(word())}`);
      members.push(`"volumeKey":${rng.pick(['2', '"v-2"', '1.5', 'null'])}`);
      break;
    case 'milestone.update':
      if (rng.chance(0.5)) members.push(`"label":${quoted(word())}`);
      members.push(`"milestoneKey":${rng.pick(['"m1"', '7', '" "'])}`);
      break;
    case 'promise.create':
      if (rng.chance(0.5)) members.push(`"label":${quoted(word())}`);
      members.push(`"key":${rng.pick(['"p-1"', '3'])}`);
      break;
    case 'brief.update':
    case 'draft.rewrite':
      if (rng.chance(0.5)) members.push(`"title":${quoted(word())}`);
      members.push(`"chapter":${rng.pick(['4', '12', '"x"', '1e21'])}`);
      break;
    case 'bible_document.upsert':
      members.push(`"slug":${rng.pick(['"old-keep_map"', '"a"', '"-"'])}`);
      if (rng.chance(0.5)) members.push(`"frontmatter":${rng.pick(['{"title":"The Keep"}', '{"title":"  "}', '[]', 'null', '{}'])}`);
      break;
    case 'entity.upsert':
      members.push(`"type":${rng.pick(['"character"', '"faction"', '"location"', '"power_rule"', '"item"', '7'])}`);
      if (rng.chance(0.6)) members.push(`"name":${quoted(word())}`);
      members.push(`"entityKey":${rng.pick(['"mara"', '42'])}`);
      break;
    default:
      if (rng.chance(0.5)) members.push(`"name":${quoted(word())}`);
      if (rng.chance(0.5)) members.push(`"factKey":${rng.pick(['"f1"', '9'])}`);
  }
  if (rng.chance(0.2)) members.push(`"nested":{"list":[1,"two",{"three":${quoted(word())}}],"n":2.50}`);
  if (rng.chance(0.15)) members.push(`"2":"b","1":"a"`);
  for (let i = members.length - 1; i > 1; i--) {
    const j = rng.int(1, i);
    [members[i], members[j]] = [members[j] as string, members[i] as string];
  }
  const space = rng.chance(0.3) ? ' ' : '';
  return '{' + members.join(',' + space) + '}';
}

interface Doc {
  reply: string;
  elements: string[];
  replyFirst: boolean;
  preamble: string;
  trailer: string;
}

function makeDoc(rng: Rng, veto: boolean): Doc {
  return {
    reply: replyText(rng, rng.int(0, 14), veto),
    elements: Array.from({ length: rng.int(0, 3) }, () => changeElement(rng, veto)),
    replyFirst: rng.chance(0.7),
    preamble: rng.pick(['', '', '', 'Here you go:\n```json\n', '{} ']),
    trailer: rng.pick(['', '', '\n```', ' {"reply":"second"}']),
  };
}

function render(doc: Doc, withReply = true): string {
  const reply = withReply ? `"reply":"${doc.reply}"` : '"question":"none"';
  const changes = `"changeSet":[${doc.elements.join(',')}]`;
  const members = doc.replyFirst ? [reply, changes] : [changes, reply];
  return doc.preamble + '{' + members.join(',') + '}' + doc.trailer;
}

function variant(rng: Rng, doc: Doc, veto: boolean): Doc {
  const roll = rng.int(0, 5);
  if (roll === 0) return { ...doc, reply: doc.reply + 'more.' };
  if (roll === 1) return { ...doc, reply: replyText(rng, rng.int(1, 6), veto) };
  if (roll === 2) return { ...doc, elements: [...doc.elements, changeElement(rng, veto)] };
  if (roll === 3) return { ...doc, elements: doc.elements.slice(1) };
  if (roll === 4) return { ...doc, elements: doc.elements.map(element => element.replace(/,/g, ' , ').replace(/:/g, ' : ')), preamble: '', trailer: '' };
  return { ...doc, elements: [...doc.elements].reverse() };
}

function isHigh(code: number): boolean {
  return code >= 0xd800 && code <= 0xdbff;
}

// Cuts never fall inside a raw surrogate pair: a Swift string, which every delta of a structured stream is, cannot hold half of one.
function chunks(rng: Rng, text: string): string[] {
  const style = rng.pick([0, 1, 2, 3, 3, 3, 4, 4, 4, 4]);
  if (style === 0 || text.length === 0) return [text];
  const out: string[] = [];
  let start = 0;
  while (start < text.length) {
    let size = style === 1 ? 1 : style === 2 ? rng.int(1, 4) : style === 3 ? rng.int(3, 12) : rng.int(8, 40);
    let end = Math.min(text.length, start + size);
    if (end < text.length && isHigh(text.charCodeAt(end - 1))) end += 1;
    out.push(text.slice(start, end));
    start = end;
  }
  return out;
}

type Op =
  | { op: 'call'; unrestricted: boolean }
  | { op: 'push'; chunk: string }
  | { op: 'restart' }
  | { op: 'settle'; raw: string }
  | { op: 'supersede' }
  | { op: 'lookup'; round: number; tool: string; args: string; status: 'running' | 'ok' | 'error' }
  | { op: 'user'; message: string }
  | { op: 'flush' }
  | { op: 'done'; reply: string }
  | { op: 'error'; code: string; message: string };

const LOOKUP_ARGS = ['{}', '{"chapter":3}', '{"slug":"old-keep","section":"History"}', '{"from":1,"to":2.5,"query":"ash\\u2028grove"}', '{"b":1,"a":[true,null],"10":"x","2":"y"}'];

function uuid(rng: Rng): string {
  const hex = (count: number): string => Array.from({ length: count }, () => rng.int(0, 15).toString(16)).join('');
  return `${hex(8)}-${hex(4)}-4${hex(3)}-a${hex(3)}-${hex(12)}`;
}

function streamCall(rng: Rng, ops: Op[], unrestricted: boolean): void {
  ops.push({ op: 'call', unrestricted });
  let doc = makeDoc(rng, unrestricted);
  ops.push({ op: 'restart' });
  if (rng.chance(0.25)) {
    const abandoned = render(makeDoc(rng, unrestricted));
    for (const chunk of chunks(rng, abandoned.slice(0, rng.int(0, abandoned.length)))) ops.push({ op: 'push', chunk });
    ops.push({ op: 'restart' });
  }
  const withReply = rng.chance(0.92);
  const raw = render(doc, withReply);
  for (const chunk of chunks(rng, raw)) {
    ops.push({ op: 'push', chunk });
    if (rng.chance(0.05)) ops.push({ op: 'flush' });
  }
  const ending = rng.int(0, 9);
  if (ending <= 5) ops.push({ op: 'settle', raw });
  else if (ending <= 7) {
    doc = variant(rng, doc, unrestricted);
    ops.push({ op: 'settle', raw: render(doc) });
  } else if (ending === 8) {
    ops.push({ op: 'restart' });
    ops.push({ op: 'settle', raw });
  }
}

function scenario(rng: Rng): Op[] {
  const ops: Op[] = [];
  const unrestricted = rng.chance(0.5);
  ops.push({ op: 'user', message: uuid(rng) });
  const rounds = rng.int(0, 2);
  for (let round = 0; round <= rounds; round++) {
    streamCall(rng, ops, unrestricted);
    if (round === rounds) break;
    for (let i = rng.int(1, 2); i > 0; i--) {
      const tool = rng.pick(['get_brief', 'get_bible_document', 'get_notes', 'nope']);
      const args = rng.pick(LOOKUP_ARGS);
      ops.push({ op: 'lookup', round, tool, args, status: 'running' });
      ops.push({ op: 'lookup', round, tool, args, status: rng.chance(0.8) ? 'ok' : 'error' });
    }
    if (rng.chance(0.5)) ops.push({ op: 'flush' });
    ops.push({ op: 'supersede' });
  }
  if (rng.chance(0.8)) ops.push({ op: 'done', reply: uuid(rng) });
  else ops.push({ op: 'error', code: 'AI_001', message: rng.pick(['The model answer could not be read', 'tab\there "quoted" 😀']) });
  return ops;
}

type RelayEvent = ['delta', string] | ['change', number, string] | ['reset'];
type TurnEvent = ['delta', string] | ['change', number, string, string, string] | ['reset'];

type Frame = [number, string, string];

/** What one op produced, by the op's index; an op that produced nothing has no step. */
type Step = [number, RelayEvent[] | null, TurnEvent[] | null, Frame[] | null];

async function run(ops: Op[]): Promise<Step[]> {
  const batches: { seq: number; event: string; data: string }[][] = [];
  const sink = { append: async (_projectId: bigint, _runId: string, records: { seq: number; event: string; data: string }[]) => void batches.push(records) };
  const log = new TurnEventLog(sink, 1n, 'run', { coalesceMs: 1e9 });
  let turnEvents: TurnEvent[] = [];
  const emitter = new EmitterRelay(
    {
      onRunId: () => undefined,
      onUserMessage: () => undefined,
      onLookup: (event: unknown) => log.append('lookup', event),
      onDelta: (text: string) => {
        turnEvents.push(['delta', text]);
        log.delta(text);
      },
      onChange: (event: { index: number; op: string; label: string; group: string }) => {
        turnEvents.push(['change', event.index, event.op, event.label.toWellFormed(), event.group]);
        log.append('change', event);
      },
      onReset: () => {
        turnEvents.push(['reset']);
        log.append('reset', {});
      },
    },
    (err: unknown) => {
      throw err;
    },
  );
  const handlers = emitter.streamHandlers;
  let relayEvents: RelayEvent[] = [];
  const relayHandlers = {
    onDelta: (text: string) => {
      relayEvents.push(['delta', text]);
      handlers.onDelta(text);
    },
    onChange: (change: { index: number; element: unknown }) => {
      relayEvents.push(['change', change.index, JSON.stringify(change.element)]);
      handlers.onChange?.(change);
    },
    onReset: () => {
      relayEvents.push(['reset']);
      handlers.onReset?.();
    },
  };
  let relay: InstanceType<typeof ReplyStreamRelay> | null = null;
  const steps: Step[] = [];
  for (const [index, op] of ops.entries()) {
    relayEvents = [];
    turnEvents = [];
    const written = batches.length;
    switch (op.op) {
      case 'call':
        relay = new ReplyStreamRelay(relayHandlers, err => {
          throw err;
        }, op.unrestricted ? refuses : undefined);
        break;
      case 'push':
        relay?.push(op.chunk);
        break;
      case 'restart':
        relay?.restart();
        break;
      case 'settle':
        relay?.settle(op.raw);
        break;
      case 'supersede':
        emitter.supersedeOnNextDelta();
        break;
      case 'lookup':
        emitter.lookup({ round: op.round, tool: op.tool, args: { ...JSON.parse(op.args) }, status: op.status });
        break;
      case 'user':
        log.append('user', { message: op.message });
        break;
      case 'flush':
        await log.flush();
        break;
      case 'done':
        await log.finish('done', { reply: op.reply });
        break;
      case 'error':
        await log.finish('error', { code: op.code, message: op.message });
        break;
    }
    const frames = batches.slice(written).flat().map((record): Frame => [record.seq, record.event, record.data]);
    if (relayEvents.length + turnEvents.length + frames.length === 0) continue;
    steps.push([index, relayEvents.length > 0 ? relayEvents : null, turnEvents.length > 0 ? turnEvents : null, frames.length > 0 ? frames : null]);
  }
  return steps;
}

const rng = createRng(0x7e1a7);
const scenarios: { ops: (string | Op)[]; steps: Step[] }[] = [];
for (let i = 0; i < 160; i++) {
  const ops = scenario(rng);
  const steps = await run(ops);
  scenarios.push({ ops: ops.map(op => (op.op === 'push' ? op.chunk : op)), steps });
}

const DESCRIBE_ELEMENTS = [
  '{"op":"premise.update"}',
  '{"op":"premise.update","theme":"x","ending":null,"opposition":0}',
  '{"op":"premise.update","brief":"b","readerPromise":"r","protagonistKey":"p","endingQuestion":"q"}',
  '{"op":"organise.rule","name":"ignored"}',
  '{"op":"action.plan_chapter"}',
  '{"op":"action.organise_notes"}',
  '{"op":"volume.create","volumeKey":2}',
  '{"op":"volume.create","volumeKey":-0}',
  '{"op":"volume.create","volumeKey":1e21}',
  '{"op":"volume.create","volumeKey":1.0000001e-7}',
  '{"op":"volume.create","volumeKey":123456789012345678901}',
  '{"op":"volume.create","volumeKey":1e400}',
  '{"op":"volume.create","volumeKey":"\\u00a0\\ufeff"}',
  '{"op":"volume.create"}',
  '{"op":"volume.create","title":"\\u2028 First\\u3000Light \\u0085"}',
  '{"op":"milestone.update","milestoneKey":7}',
  '{"op":"milestone.update","label":"","milestoneKey":"m"}',
  '{"op":"milestone.update"}',
  '{"op":"promise.create","key":"p-1"}',
  '{"op":"promise.resolve","label":"Keep\\n\\n the   oath","key":"p"}',
  '{"op":"brief.update","chapter":4}',
  '{"op":"brief.update","chapter":4.25,"title":" "}',
  '{"op":"draft.rewrite","title":"The\\tEnd"}',
  '{"op":"bible_document.upsert","slug":"old-keep_map"}',
  '{"op":"bible_document.upsert","slug":"-"}',
  '{"op":"bible_document.upsert","slug":5,"frontmatter":{"title":"  Keep  "}}',
  '{"op":"bible_document.upsert","slug":"a_b","frontmatter":[]}',
  '{"op":"bible_document.upsert","frontmatter":{"title":7}}',
  '{"op":"bible_document.upsert"}',
  '{"op":"entity.upsert","type":"character","name":"Mara"}',
  '{"op":"entity.upsert","type":"faction","entityKey":"f"}',
  '{"op":"entity.upsert","type":"location","entityKey":3}',
  '{"op":"entity.upsert","type":"power_rule"}',
  '{"op":"entity.upsert","type":"Character","name":"x"}',
  '{"op":"entity.upsert","type":7}',
  '{"op":"entity.delete","type":"character","name":"m"}',
  '{"op":"fact.upsert","factKey":"f1"}',
  '{"op":"fact.upsert","name":" ","entityKey":" ","factKey":2}',
  '{"op":"  "}',
  '{"op":"x y\\tz"}',
  '{"op":"thing","name":"' + 'word '.repeat(30) + '"}',
  '{"op":"thing","name":"' + 'x'.repeat(118) + '😀tail"}',
  '{"op":"thing","name":"' + 'x'.repeat(119) + '😀"}',
  '{"op":"thing","name":"' + 'x'.repeat(120) + '"}',
  '{"op":"thing","name":"' + 'x'.repeat(121) + '"}',
  '{"op":"thing","name":"e\\u0301\\u0301 combining"}',
  '{"op":"thing","name":"a","name":"b"}',
];
const describe = DESCRIBE_ELEMENTS.map((element, index) => {
  const event = describeStreamedChange(index, JSON.parse(element));
  return { element, index, op: event.op, label: event.label.toWellFormed(), group: event.group };
});

const sentenceEnds = ['', 'a', 'a.', 'a. b', '."', '.\'”’)]]x', '!?\n', 'x.\n"', 'end.”', 'no end', '..."', '?)', '.)]x.'].map(text => {
  const out: string[] = [];
  const relay = new ReplyStreamRelay({ onDelta: t => void out.push(t), onChange: () => undefined, onReset: () => undefined }, () => undefined, () => false);
  relay.push(`{"reply":${JSON.stringify(text)}`);
  return { text, released: out };
});

const output = JSON.stringify({ scenarios, describe, sentenceEnds });
writeFileSync(join(dirname(fileURLToPath(import.meta.url)), 'cases.json'), output + '\n');

const counts = { scenarios: scenarios.length, ops: scenarios.reduce((sum, entry) => sum + entry.ops.length, 0), describe: describe.length, sentenceEnds: sentenceEnds.length };
process.stdout.write(`${JSON.stringify(counts)} ${output.length} bytes\n`);
