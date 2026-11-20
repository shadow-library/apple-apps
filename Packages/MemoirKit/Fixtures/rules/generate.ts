import { createHash } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');
const outDir = dirname(fileURLToPath(import.meta.url));
const levelTableSwift = join(outDir, '../../Sources/MemoirCore/Rules/LevelCurve+V1.swift');

const rules = await import(join(platformRepo, 'apps/memoir-server/src/modules/rules/index.ts'));
const ruleset = rules.currentRuleset();

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
interface Case {
  id: string;
  input: Json;
  output: Json;
}
type Exact = (input: Json) => unknown;

const STRICTNESSES = ['anchor', 'routine', 'goal', 'recovery', 'optional'] as const;
const BANDS = ['on_time', 'late_0_2h', 'late_2h_plus', 'day_1', 'day_2', 'day_3', 'day_4'] as const;
const COMPLETIONS = ['full', 'partial'] as const;
const ONE_SHOTS = ['none', 'returner', 'comeback'] as const;
const MODES = ['standard', 'low_intensity', 'high_intensity'] as const;
const STATES = ['completed', 'partial', 'late', 'recovery', 'skipped', 'missed', 'postponed', 'rescheduled'] as const;
const MOMENTUM = ['cold', 'steady', 'warm'] as const;
const TIER_DAYS = [0, 3, 7, 30, 100];

interface Q {
  n: bigint;
  d: bigint;
}

const abs = (value: bigint): bigint => (value < 0n ? -value : value);
const gcd = (left: bigint, right: bigint): bigint => {
  let [a, b] = [abs(left), abs(right)];
  while (b !== 0n) [a, b] = [b, a % b];
  return a;
};
const q = (n: bigint, d = 1n): Q => {
  if (d === 0n) throw new Error('zero denominator');
  const sign = d < 0n ? -1n : 1n;
  const g = gcd(n, d) || 1n;
  return { n: (sign * n) / g, d: (sign * d) / g };
};
const isQ = (value: unknown): value is Q => typeof value === 'object' && value !== null && typeof (value as Q).n === 'bigint';
const int = (value: number): Q => {
  if (!Number.isSafeInteger(value)) throw new Error(`not a safe integer: ${value}`);
  return q(BigInt(value));
};
const decimal = (value: number): Q => {
  const text = String(value);
  const match = /^(-?)(\d+)(?:\.(\d+))?$/.exec(text);
  if (!match) throw new Error(`not a plain decimal: ${text}`);
  const fraction = match[3] ?? '';
  const n = BigInt(match[2] + fraction) * (match[1] === '-' ? -1n : 1n);
  return q(n, 10n ** BigInt(fraction.length));
};
const add = (a: Q, b: Q): Q => q(a.n * b.d + b.n * a.d, a.d * b.d);
const sub = (a: Q, b: Q): Q => q(a.n * b.d - b.n * a.d, a.d * b.d);
const mul = (a: Q, b: Q): Q => q(a.n * b.n, a.d * b.d);
const div = (a: Q, b: Q): Q => q(a.n * b.d, a.d * b.n);
const cmp = (a: Q, b: Q): number => {
  const difference = a.n * b.d - b.n * a.d;
  return difference < 0n ? -1 : difference > 0n ? 1 : 0;
};
const max = (a: Q, b: Q): Q => (cmp(a, b) >= 0 ? a : b);
const min = (a: Q, b: Q): Q => (cmp(a, b) <= 0 ? a : b);
const floorBig = (n: bigint, d: bigint): bigint => (n >= 0n ? n / d : -((-n + d - 1n) / d));
const floor = (a: Q): Q => q(floorBig(a.n, a.d));
const ceil = (a: Q): Q => q(-floorBig(-a.n, a.d));
const roundHalfUp = (a: Q): Q => floor(add(a, q(1n, 2n)));
const ZERO = q(0n);
const ONE = q(1n);
const SAFE = BigInt(Number.MAX_SAFE_INTEGER);
const toNumber = (a: Q): number => {
  if (abs(a.n) > SAFE || a.d > SAFE) throw new Error('rational beyond the safe range');
  return Number(a.n) / Number(a.d);
};

const numberAt = (value: Json, key: string): number => (value as Record<string, number>)[key] as number;

// Comparison of a reference output with the exact model: a fractional field agrees when the float is the nearest double to the exact value.

const agrees = (reference: unknown, exact: unknown): boolean => {
  if (isQ(exact)) return typeof reference === 'number' && toNumber(exact) === reference;
  if (Array.isArray(exact)) return Array.isArray(reference) && reference.length === exact.length && exact.every((item, index) => agrees(reference[index], item));
  if (typeof exact === 'object' && exact !== null) {
    if (typeof reference !== 'object' || reference === null || Array.isArray(reference)) return false;
    const keys = Object.keys(exact);
    return keys.length === Object.keys(reference).length && keys.every(key => agrees((reference as Record<string, unknown>)[key], (exact as Record<string, unknown>)[key]));
  }
  return reference === exact;
};

const differingFields = (reference: unknown, exact: unknown, path: string): string[] => {
  if (agrees(reference, exact)) return [];
  if (isQ(exact) || typeof exact !== 'object' || exact === null || typeof reference !== 'object' || reference === null) return [path || '.'];
  return Object.keys(exact).flatMap(key => differingFields((reference as Record<string, unknown>)[key], (exact as Record<string, unknown>)[key], path ? `${path}.${key}` : key));
};

const exactJson = (value: unknown): Json => {
  if (isQ(value)) return { fraction: [toNumber(q(value.n)), toNumber(q(value.d))] };
  if (Array.isArray(value)) return value.map(exactJson);
  if (typeof value === 'object' && value !== null) return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, exactJson(item)]));
  return value as Json;
};

const clean = (value: unknown): Json => JSON.parse(JSON.stringify(value)) as Json;

const writeJson = (name: string, groups: Record<string, readonly unknown[]>): void => {
  const body = Object.entries(groups)
    .map(([key, items]) => `${JSON.stringify(key)}: [\n${items.map(item => JSON.stringify(item)).join(',\n')}\n]`)
    .join(',\n');
  writeFileSync(join(outDir, name), `{\n${body}\n}\n`);
};

interface Divergence {
  file: string;
  function: string;
  id: string;
  fields: string[];
  reference: Json;
  exact: Json;
}
const divergences: Divergence[] = [];

const fixture = (file: string, groups: Record<string, { cases: Case[]; exact?: Exact }>): void => {
  const out: Record<string, Case[]> = {};
  for (const [name, group] of Object.entries(groups)) {
    const ids = new Set<string>();
    for (const entry of group.cases) {
      if (ids.has(entry.id)) throw new Error(`duplicate case id ${name}/${entry.id}`);
      ids.add(entry.id);
      if (!group.exact) continue;
      const exact = group.exact(entry.input);
      const fields = differingFields(entry.output, exact, '');
      if (fields.length > 0) divergences.push({ file, function: name, id: entry.id, fields, reference: entry.output, exact: exactJson(exact) });
    }
    out[name] = group.cases;
  }
  writeJson(file, out);
};

const cases = (name: string, inputs: readonly Json[], call: (input: Json) => unknown): Case[] =>
  inputs.map((input, index) => ({ id: `${name}#${index}`, input, output: clean(call(input)) }));

const product = <T>(...axes: (readonly T[])[]): T[][] => axes.reduce<T[][]>((rows, axis) => rows.flatMap(row => axis.map(value => [...row, value])), [[]]);

const range = (from: number, to: number, step = 1): number[] => {
  const values: number[] = [];
  for (let value = from; value <= to; value += step) values.push(value);
  return values;
};

const lcg = (seed: number) => {
  let state = seed >>> 0;
  return () => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state / 0x1_0000_0000;
  };
};
const pick = <T>(next: () => number, values: readonly T[]): T => values[Math.floor(next() * values.length)] ?? (values[0] as T);
const integer = (next: () => number, upper: number): number => Math.floor(next() * (upper + 1));
const runs = (seed: number, count = 200) => Array.from({ length: count }, (_value, index) => lcg(seed + index * 7919));

// Ruleset: the reference RULESET_V1 in exact units, in the shape the native `Ruleset` encodes to.

const units = (value: number, scale: number): number => {
  const scaled = mul(decimal(value), int(scale));
  if (scaled.d !== 1n) throw new Error(`${value} is not a whole number of 1/${scale}`);
  return toNumber(scaled);
};

const levelCosts = range(1, ruleset.level.maxLevel - 1).map(level => rules.xpToAdvance(ruleset, level) as number);

const nativeRuleset = (): Json => {
  const r = ruleset;
  const thousandths = (value: number) => ({ thousandths: units(value, 1000) });
  const mapValues = <T, U>(record: Record<string, T>, map: (value: T) => U) => Object.fromEntries(Object.entries(record).map(([key, value]) => [key, map(value)]));
  const swiftKeys = (value: unknown): Json => {
    if (Array.isArray(value)) return value.map(swiftKeys);
    if (typeof value !== 'object' || value === null) return value as Json;
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key.replace(/Xp/g, 'XP').replace(/Hp/g, 'HP'), swiftKeys(item)]));
  };
  return swiftKeys({
    version: r.version,
    strictness: mapValues(r.strictness, (rule: { crownWeight: number }) => ({ ...rule, crownWeight: { halves: units(rule.crownWeight, 2) } })),
    reward: {
      ...r.reward,
      partialXpFactor: thousandths(r.reward.partialXpFactor),
      lockXpModifier: thousandths(r.reward.lockXpModifier),
      oneShotXpModifiers: mapValues(r.reward.oneShotXpModifiers, thousandths),
    },
    level: { maxLevel: r.level.maxLevel, xpToAdvance: levelCosts },
    streaks: { ...r.streaks, tiers: r.streaks.tiers.map((tier: { xpModifier: number }) => ({ ...tier, xpModifier: thousandths(tier.xpModifier) })) },
    shields: r.shields,
    intensityModes: r.intensityModes,
    crown: r.crown,
    recovery: r.recovery,
    comeback: r.comeback,
    returner: r.returner,
    momentum: {
      ...r.momentum,
      recentDayWeights: r.momentum.recentDayWeights.map((weight: number) => ({ tenths: units(weight, 10) })),
      coldBelowRatio: thousandths(r.momentum.coldBelowRatio),
      warmAboveRatio: thousandths(r.momentum.warmAboveRatio),
    },
    capacity: {
      ...r.capacity,
      ratchetFactor: thousandths(r.capacity.ratchetFactor),
      coldMomentumFactor: thousandths(r.capacity.coldMomentumFactor),
      heavyMissDayFactor: thousandths(r.capacity.heavyMissDayFactor),
      softWarningRatio: thousandths(r.capacity.softWarningRatio),
      modalWarningRatio: thousandths(r.capacity.modalWarningRatio),
    },
    reasonTags: r.reasonTags,
    quickLogs: r.quickLogs,
    subscriptionConfirmationCoins: r.subscriptionConfirmationCoins,
  });
};

const canonical = (value: Json): string => {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (typeof value === 'object' && value !== null) {
    const keys = Object.keys(value).sort();
    return `{${keys.map(key => `${JSON.stringify(key)}:${canonical(value[key] as Json)}`).join(',')}}`;
  }
  if (typeof value === 'number' && !Number.isSafeInteger(value)) throw new Error(`canonical JSON holds integers only: ${value}`);
  return JSON.stringify(value);
};

const canonicalRuleset = canonical(nativeRuleset());
writeFileSync(
  join(outDir, 'ruleset-v1.json'),
  `{\n"sha256": ${JSON.stringify(createHash('sha256').update(canonicalRuleset).digest('hex'))},\n"canonical": ${canonicalRuleset}\n}\n`,
);

// Level curve. 100 * level^1.5 is sqrt(10000 * level^3); a square root of an integer is never a half, so rounding needs only the integer root.

const isqrt = (value: bigint): bigint => {
  if (value < 2n) return value;
  let x = BigInt(Math.floor(Math.sqrt(Number(value))));
  while (x * x > value) x -= 1n;
  while ((x + 1n) * (x + 1n) <= value) x += 1n;
  return x;
};

if (ruleset.level.curveExponent !== 1.5) throw new Error('the exact level model covers an exponent of 1.5 only');
const exactCost = (level: number): bigint => {
  if (level < 1 || level >= ruleset.level.maxLevel) return 0n;
  const radicand = BigInt(ruleset.level.curveCoefficient) ** 2n * BigInt(level) ** 3n;
  const root = isqrt(radicand);
  return radicand - root * root > root ? root + 1n : root;
};
const exactThresholds: bigint[] = [0n, 0n];
for (let level = 1; level < ruleset.level.maxLevel; level++) exactThresholds.push((exactThresholds[exactThresholds.length - 1] ?? 0n) + exactCost(level));
const clampLevel = (level: number) => Math.min(Math.max(Math.trunc(level), 1), ruleset.level.maxLevel);
const exactLevelFor = (xp: number): number => {
  const total = BigInt(Math.max(0, Math.trunc(xp)));
  let level = 1;
  while (level < ruleset.level.maxLevel && (exactThresholds[level + 1] ?? 0n) <= total) level++;
  return level;
};

const thresholds = range(1, ruleset.level.maxLevel).map(level => rules.xpThresholdForLevel(ruleset, level) as number);
const levelForInputs = [
  -1_000, 0, 1, 99, 100, 382, 383, 902, 903, 1_702, 1_703, Number.MAX_SAFE_INTEGER,
  ...thresholds.flatMap(threshold => [threshold - 1, threshold, threshold + 1]),
  (thresholds[thresholds.length - 1] ?? 0) * 1_000,
  ...range(0, 200_000, 137),
].filter((value, index, all) => all.indexOf(value) === index);

fixture('level.json', {
  xpToAdvance: {
    cases: cases('xpToAdvance', [1, 2, 3, 4, 9, 16, 100, 999, 1000, 0, -4, ...range(1, 998), -1, 1001], level => rules.xpToAdvance(ruleset, level)),
    exact: input => int(Number(exactCost(input as number))),
  },
  xpThresholdForLevel: {
    cases: cases('xpThresholdForLevel', [1, 2, 3, 4, 5, 0, -50, 1499, ...range(1, 999), 1000], level => rules.xpThresholdForLevel(ruleset, level)),
    exact: input => int(Number(exactThresholds[clampLevel(input as number)] ?? 0n)),
  },
  levelFor: {
    cases: cases('levelFor', levelForInputs, xp => rules.levelFor(ruleset, xp)),
    exact: input => exactLevelFor(input as number),
  },
});

interface RewardInput {
  strictness: string;
  band: string;
  completion: string;
  streakDays: number;
  lockActive: boolean;
  oneShot: string;
}

const rewardInput = (overrides: Partial<RewardInput>): RewardInput => ({
  strictness: 'routine',
  band: 'on_time',
  completion: 'full',
  streakDays: 0,
  lockActive: false,
  oneShot: 'none',
  ...overrides,
});

const exactReward = (input: RewardInput) => {
  const reward = ruleset.reward;
  const tableXp = int(reward.baseXp[input.strictness][input.band]);
  const baseXp = input.completion === 'partial' ? floor(mul(tableXp, decimal(reward.partialXpFactor))) : tableXp;
  const tier = rules.streakTierFor(ruleset, input.streakDays);
  const oneShotConsumed = ruleset.strictness[input.strictness].consumesOneShot ? input.oneShot : 'none';
  const lock = input.lockActive ? decimal(reward.lockXpModifier) : ONE;
  const oneShot = oneShotConsumed === 'none' ? ONE : decimal(reward.oneShotXpModifiers[oneShotConsumed]);
  const modifier = mul(mul(decimal(tier.xpModifier), lock), oneShot);
  const xp = min(int(reward.xpCeiling), floor(mul(baseXp, modifier)));
  const earnsBaseCoins = input.completion === 'full' && input.band === 'on_time';
  const coins = (earnsBaseCoins ? reward.baseCoins[input.strictness] : 0) + (oneShotConsumed === 'comeback' ? reward.comebackCoinBonus : 0);
  return { xp: toNumber(xp), coins, statTick: reward.statTick, baseXp: toNumber(baseXp), modifier, streakTier: tier.id, oneShotConsumed };
};

const rewardDomain = product<unknown>(STRICTNESSES, BANDS, COMPLETIONS, TIER_DAYS, [false, true], ONE_SHOTS).map(
  ([strictness, band, completion, streakDays, lockActive, oneShot]) => ({ strictness, band, completion, streakDays, lockActive, oneShot }) as RewardInput,
);

const rewardSpecInputs: RewardInput[] = [
  ...STRICTNESSES.flatMap(strictness => BANDS.map(band => rewardInput({ strictness, band }))),
  ...STRICTNESSES.flatMap(strictness => [
    rewardInput({ strictness, band: 'late_0_2h' }),
    rewardInput({ strictness, band: 'day_1' }),
    rewardInput({ strictness, completion: 'partial' }),
  ]),
  rewardInput({ completion: 'partial' }),
  rewardInput({ band: 'day_4' }),
  rewardInput({ streakDays: 100, lockActive: true, oneShot: 'comeback' }),
  ...(
    [
      ['anchor', 'on_time'],
      ['anchor', 'late_0_2h'],
      ['anchor', 'late_2h_plus'],
      ['anchor', 'day_1'],
      ['anchor', 'day_2'],
      ['routine', 'on_time'],
      ['routine', 'late_0_2h'],
      ['goal', 'on_time'],
      ['recovery', 'on_time'],
      ['optional', 'on_time'],
    ] as const
  ).map(([strictness, band]) => rewardInput({ strictness, band, completion: 'partial' })),
  rewardInput({ strictness: 'routine', band: 'late_0_2h', completion: 'partial', oneShot: 'comeback' }),
  rewardInput({ strictness: 'anchor', streakDays: 7 }),
  rewardInput({ strictness: 'anchor', streakDays: 30 }),
  rewardInput({ strictness: 'anchor', streakDays: 100 }),
  rewardInput({ strictness: 'anchor', lockActive: true }),
  rewardInput({ strictness: 'anchor', oneShot: 'returner' }),
  rewardInput({ strictness: 'anchor', oneShot: 'comeback' }),
  rewardInput({ strictness: 'routine', streakDays: 100, lockActive: true, oneShot: 'comeback' }),
  rewardInput({ strictness: 'anchor', streakDays: 100, lockActive: true, oneShot: 'comeback' }),
  rewardInput({ strictness: 'anchor', band: 'day_3', streakDays: 100, lockActive: true, oneShot: 'comeback' }),
  ...(['anchor', 'routine', 'goal', 'recovery', 'optional'] as const).flatMap(strictness => [
    rewardInput({ strictness, oneShot: 'returner' }),
    rewardInput({ strictness, oneShot: 'comeback' }),
  ]),
  rewardInput({ strictness: 'anchor', band: 'day_1', oneShot: 'comeback' }),
  rewardInput({ strictness: 'anchor', completion: 'partial', oneShot: 'comeback' }),
  { strictness: 'anchor', band: 'late_0_2h', completion: 'partial', streakDays: 42, lockActive: true, oneShot: 'returner' },
  rewardInput({ streakDays: -100 }),
  rewardInput({ streakDays: 1_099, lockActive: true, oneShot: 'returner' }),
];

const streakTierInputs = [-5, 0, 2, 3, 6, 7, 29, 30, 99, 100, 10_000, ...range(-2, 102)];

fixture('reward.json', {
  streakTierFor: { cases: cases('streakTierFor', streakTierInputs, days => rules.streakTierFor(ruleset, days)) },
  streakTierMinDays: { cases: cases('streakTierMinDays', ['none', 'bronze', 'silver', 'gold', 'platinum'], id => rules.streakTierMinDays(ruleset, id)) },
  computeReward: {
    cases: [
      ...cases('spec', rewardSpecInputs as unknown as Json[], input => rules.computeReward(ruleset, input)),
      ...cases('domain', rewardDomain as unknown as Json[], input => rules.computeReward(ruleset, input)),
    ],
    exact: input => exactReward(input as unknown as RewardInput),
  },
});

const timingInput = (overrides: Record<string, Json>) => ({ strictness: 'routine', startMinute: 540, durationMinutes: 45, daysElapsed: 0, minuteOfDay: 540, ...overrides });
const timingSpecInputs: Json[] = [
  timingInput({ strictness: 'anchor', daysElapsed: -1, minuteOfDay: 1437 }),
  timingInput({ daysElapsed: -1, minuteOfDay: 1437 }),
  ...[539, 540, 569, 570, 571, 689, 690, 691, 1439].map(minuteOfDay => timingInput({ strictness: 'anchor', minuteOfDay })),
  ...[539, 540, 584, 585, 704, 705, 1439].map(minuteOfDay => timingInput({ strictness: 'routine', minuteOfDay })),
  ...(['goal', 'recovery', 'optional'] as const).flatMap(strictness => [0, 540, 570, 1140, 1439].map(minuteOfDay => timingInput({ strictness, minuteOfDay }))),
  timingInput({ strictness: 'goal', minuteOfDay: 1439 }),
  timingInput({ strictness: 'routine', startMinute: null, minuteOfDay: 1439 }),
  timingInput({ strictness: 'anchor', startMinute: null, minuteOfDay: 1439 }),
  timingInput({ durationMinutes: 0, minuteOfDay: 539 }),
  timingInput({ durationMinutes: 0, minuteOfDay: 540 }),
  ...[1, 2, 3, 4, 5, 90].map(daysElapsed => timingInput({ daysElapsed })),
  timingInput({ daysElapsed: 1, minuteOfDay: 0 }),
  timingInput({ daysElapsed: 1, minuteOfDay: 1439 }),
  timingInput({ daysElapsed: -3, minuteOfDay: 540 }),
];

const timingRows = product<unknown>(STRICTNESSES, [null, 0, 540, 1400], [0, 45], range(-1, 5)).map(([strictness, startMinute, durationMinutes, daysElapsed]) => ({
  strictness,
  startMinute,
  durationMinutes,
  daysElapsed,
})) as unknown as Json[];

const bandRuns = (row: Json): Json => {
  const runsOut: [string, number][] = [];
  for (let minuteOfDay = 0; minuteOfDay < 1440; minuteOfDay++) {
    const band = rules.resolveTimingBand(ruleset, { ...(row as object), minuteOfDay }) as string;
    const last = runsOut[runsOut.length - 1];
    if (last && last[0] === band) last[1] += 1;
    else runsOut.push([band, 1]);
  }
  return runsOut;
};

fixture('timing.json', {
  resolveTimingBand: { cases: cases('resolveTimingBand', timingSpecInputs, input => rules.resolveTimingBand(ruleset, input)) },
  everyMinute: { cases: cases('everyMinute', timingRows, bandRuns) },
});

const EMPTY_STREAK = { currentDays: 0, longestDays: 0, shields: 0, completionsTowardShield: 0, pendingShieldGrant: 0 };
const streakState = (overrides: Record<string, number> = {}) => ({ ...EMPTY_STREAK, ...overrides });
const streakEvent = (overrides: Record<string, Json> = {}) => ({
  state: 'completed',
  strictness: 'routine',
  intensityMode: 'standard',
  streakOptIn: false,
  onTime: true,
  ...overrides,
});

const streakSpecApply: Json[] = [
  ...STATES.flatMap(state => [
    { state: streakState({ currentDays: 4 }), event: streakEvent({ state }) },
    { state: streakState({ currentDays: 4, shields: 1 }), event: streakEvent({ state }) },
  ]),
  { state: streakState({ currentDays: 9, longestDays: 12, shields: 1, completionsTowardShield: 3 }), event: streakEvent({ state: 'rescheduled' }) },
  { state: streakState({ currentDays: 6, shields: 1 }), event: streakEvent({ strictness: 'optional', state: 'missed' }) },
  { state: streakState({ currentDays: 6, shields: 1 }), event: streakEvent({ strictness: 'optional', state: 'completed' }) },
  { state: streakState({ currentDays: 6 }), event: streakEvent({ strictness: 'optional', streakOptIn: true }) },
  { state: streakState({ currentDays: 4, longestDays: 4 }), event: streakEvent() },
  { state: streakState({ currentDays: 1, longestDays: 40 }), event: streakEvent() },
  ...[0, 1, 2, 3, 6, 29, 99, 100].map(currentDays => ({ state: streakState({ currentDays }), event: streakEvent() })),
  ...(
    [
      ['completed', true],
      ['completed', false],
      ['partial', false],
      ['late', false],
      ['recovery', true],
    ] as const
  ).map(([state, onTime]) => ({ state: streakState({ completionsTowardShield: 2 }), event: streakEvent({ state, onTime }) })),
  { state: streakState({ currentDays: 12, longestDays: 12, shields: 2, completionsTowardShield: 4 }), event: streakEvent({ state: 'missed' }) },
  { state: streakState({ currentDays: 3, shields: 1 }), event: streakEvent({ strictness: 'goal', state: 'postponed' }) },
  { state: streakState({ currentDays: 9, longestDays: 20, completionsTowardShield: 5 }), event: streakEvent({ state: 'skipped' }) },
  ...[0, 1, 6, 7, 40].map(currentDays => ({ state: streakState({ currentDays }), event: streakEvent({ state: 'missed' }) })),
  { state: streakState({ currentDays: 5, shields: 2, pendingShieldGrant: 1 }), event: streakEvent({ state: 'missed' }) },
];

const streakGridStates = [
  EMPTY_STREAK,
  streakState({ currentDays: 2, longestDays: 2, completionsTowardShield: 4 }),
  streakState({ currentDays: 6, longestDays: 10, shields: 1, completionsTowardShield: 6 }),
  streakState({ currentDays: 4, longestDays: 4, shields: 2, completionsTowardShield: 4, pendingShieldGrant: 1 }),
  streakState({ currentDays: 9, longestDays: 20, completionsTowardShield: 9 }),
  streakState({ currentDays: 29, longestDays: 29, shields: 1, completionsTowardShield: 3 }),
  streakState({ currentDays: 99, longestDays: 120, shields: 2, completionsTowardShield: 9, pendingShieldGrant: 2 }),
  streakState({ currentDays: 7, longestDays: 7, shields: 3, completionsTowardShield: 0 }),
];
const streakGrid = product<unknown>(streakGridStates, STATES, STRICTNESSES, [false, true], MODES, [false, true]).map(
  ([state, logState, strictness, streakOptIn, intensityMode, onTime]) => ({
    state,
    event: { state: logState, strictness, intensityMode, streakOptIn, onTime },
  }),
) as unknown as Json[];

const shieldGrants = product<unknown>([0, 1, 2, 3], [0, 1, 2], [-3, 0, 1, 2, 5]).map(([shields, pendingShieldGrant, count]) => ({
  state: streakState({ currentDays: 5, longestDays: 8, shields: shields as number, completionsTowardShield: 2, pendingShieldGrant: pendingShieldGrant as number }),
  count,
})) as unknown as Json[];

const recomputeHistory = [
  ...Array.from({ length: 8 }, () => streakEvent()),
  streakEvent({ state: 'missed' }),
  streakEvent({ state: 'rescheduled' }),
  ...Array.from({ length: 3 }, () => streakEvent({ state: 'partial', onTime: false })),
  streakEvent({ state: 'postponed' }),
  streakEvent({ state: 'late', onTime: false }),
];
const recomputeInputs: Json[] = [
  { events: recomputeHistory, initial: null },
  { events: [streakEvent(), streakEvent({ state: 'missed' })], initial: streakState({ currentDays: 2, longestDays: 5, shields: 1 }) },
  { events: Array.from({ length: 40 }, () => streakEvent({ intensityMode: 'low_intensity' })), initial: null },
  { events: [], initial: streakState({ currentDays: 3 }) },
];

fixture('streak.json', {
  streakApplies: {
    cases: cases('streakApplies', product<unknown>(STRICTNESSES, [false, true]).map(([strictness, optIn]) => ({ strictness, optIn })) as unknown as Json[], input =>
      rules.streakApplies(ruleset, (input as Record<string, Json>).strictness, (input as Record<string, Json>).optIn),
    ),
  },
  applyStreakEvent: {
    cases: [
      ...cases('spec', streakSpecApply, input => rules.applyStreakEvent(ruleset, (input as Record<string, Json>).state, (input as Record<string, Json>).event)),
      ...cases('grid', streakGrid, input => rules.applyStreakEvent(ruleset, (input as Record<string, Json>).state, (input as Record<string, Json>).event)),
    ],
  },
  grantStreakShield: {
    cases: [
      ...cases('spec', [
        { state: streakState({ shields: 1 }), count: 1 },
        { state: streakState({ shields: 2 }), count: 1 },
        { state: streakState({ currentDays: 5, shields: 2 }), count: 1 },
        { state: streakState({ shields: 1 }), count: -3 },
      ], input => rules.grantStreakShield(ruleset, (input as Record<string, Json>).state, numberAt(input, 'count'))),
      ...cases('grid', shieldGrants, input => rules.grantStreakShield(ruleset, (input as Record<string, Json>).state, numberAt(input, 'count'))),
    ],
  },
  recomputeStreak: {
    cases: cases('recomputeStreak', recomputeInputs, input => {
      const { events, initial } = input as Record<string, Json>;
      return initial === null ? rules.recomputeStreak(ruleset, events) : rules.recomputeStreak(ruleset, events, initial);
    }),
  },
});

const hpBreak = (overrides: Record<string, Json> = {}) => ({
  occurrenceKey: 'quest-1@2026-08-24',
  strictness: 'anchor',
  state: 'missed',
  shielded: false,
  streakDaysBefore: 0,
  ...overrides,
});
const hpCostSpec: Json[] = [
  ...STRICTNESSES.map(strictness => ({ mode: 'standard', event: hpBreak({ strictness }) })),
  ...STATES.map(state => ({ mode: 'standard', event: hpBreak({ state }) })),
  ...(
    [
      ['standard', false, 0],
      ['standard', false, 30],
      ['standard', true, 30],
      ['low_intensity', false, 0],
      ['low_intensity', false, 100],
      ['high_intensity', false, 0],
      ['high_intensity', false, 6],
      ['high_intensity', false, 7],
      ['high_intensity', false, 100],
      ['high_intensity', true, 100],
    ] as const
  ).map(([mode, shielded, streakDaysBefore]) => ({ mode, event: hpBreak({ shielded, streakDaysBefore }) })),
];
const hpCostGrid = product<unknown>(MODES, STRICTNESSES, STATES, [false, true], [0, 6, 7, 8, 30, 100]).map(([mode, strictness, state, shielded, streakDaysBefore]) => ({
  mode,
  event: hpBreak({ strictness: strictness as string, state: state as string, shielded: shielded as boolean, streakDaysBefore: streakDaysBefore as number }),
})) as unknown as Json[];
const keyed = (count: number, overrides: Record<string, Json> = {}) =>
  Array.from({ length: count }, (_value, index) => hpBreak({ occurrenceKey: `quest-${index}@2026-08-24`, ...overrides }));
const dayHpSpec: Json[] = [
  { mode: 'standard', previousHpEnd: 1, breaks: [hpBreak(), hpBreak({ occurrenceKey: 'quest-2@2026-08-24', strictness: 'routine' })] },
  { mode: 'standard', previousHpEnd: 5, breaks: [hpBreak({ state: 'missed' }), hpBreak({ state: 'skipped' })] },
  { mode: 'high_intensity', previousHpEnd: 3, breaks: [hpBreak({ shielded: true, streakDaysBefore: 30 }), hpBreak({ shielded: false, streakDaysBefore: 30 })] },
  { mode: 'standard', previousHpEnd: 0, breaks: keyed(9) },
  { mode: 'low_intensity', previousHpEnd: 8, breaks: keyed(5) },
  { mode: 'standard', previousHpEnd: null, breaks: [] },
  ...MODES.flatMap(mode => [-3, 0, 2, 9].map(previousHpEnd => ({ mode, previousHpEnd, breaks: keyed(3, { streakDaysBefore: 30 }) }))),
];

const dayHp = (input: Json) => {
  const { mode, previousHpEnd, breaks } = input as Record<string, Json>;
  return rules.computeDayHp(ruleset, mode, { previousHpEnd, breaks });
};

fixture('hp.json', {
  hpMaxFor: { cases: cases('hpMaxFor', [...MODES], mode => rules.hpMaxFor(ruleset, mode)) },
  hpStartFor: {
    cases: cases('hpStartFor', product<unknown>(MODES, [null, -2, -1, ...range(0, 10)]).map(([mode, previous]) => ({ mode, previous })) as unknown as Json[], input =>
      rules.hpStartFor(ruleset, (input as Record<string, Json>).mode, (input as Record<string, Json>).previous),
    ),
  },
  hpCostFor: {
    cases: [
      ...cases('spec', hpCostSpec, input => rules.hpCostFor(ruleset, (input as Record<string, Json>).mode, (input as Record<string, Json>).event)),
      ...cases('grid', hpCostGrid, input => rules.hpCostFor(ruleset, (input as Record<string, Json>).mode, (input as Record<string, Json>).event)),
    ],
  },
  computeDayHp: { cases: cases('computeDayHp', dayHpSpec, dayHp) },
  energyLowIndicated: {
    cases: cases('energyLowIndicated', product<unknown>(MODES, [0, 1, 2, 5, 9]).map(([mode, misses]) => ({ mode, misses })) as unknown as Json[], input =>
      rules.energyLowIndicated((input as Record<string, Json>).mode, numberAt(input, 'misses')),
    ),
  },
});

const halvesOnly = (weight: number): Q => {
  const exact = decimal(weight);
  if (mul(exact, int(2)).d !== 1n) throw new Error(`crown weight ${weight} is not a whole number of halves`);
  return exact;
};
const exactShare = (weight: Q) => {
  const surviving = max(ZERO, weight);
  return {
    xp: toNumber(roundHalfUp(mul(surviving, int(ruleset.crown.xpPerWeight)))),
    coins: toNumber(min(int(ruleset.crown.maxCoins), ceil(div(surviving, int(ruleset.crown.coinsWeightDivisor))))),
  };
};
interface CrownState {
  endowedWeight: Q;
  forfeitedWeight: Q;
  grantedXp: number;
  grantedCoins: number;
}
const exactRemainder = (state: CrownState) => {
  const remainder = exactShare(sub(state.endowedWeight, state.forfeitedWeight));
  return { ...state, remainingXp: Math.min(state.grantedXp, remainder.xp), remainingCoins: Math.min(state.grantedCoins, remainder.coins) };
};
const exactSum = (weights: readonly number[]) => weights.reduce<Q>((total, weight) => add(total, max(ZERO, halvesOnly(weight))), ZERO);
const exactEndow = (weights: readonly number[]) => {
  const endowedWeight = exactSum(weights);
  const granted = exactShare(endowedWeight);
  return exactRemainder({ endowedWeight, forfeitedWeight: ZERO, grantedXp: granted.xp, grantedCoins: granted.coins });
};
const exactState = (state: Record<string, number>): CrownState => ({
  endowedWeight: halvesOnly(state.endowedWeight as number),
  forfeitedWeight: halvesOnly(state.forfeitedWeight as number),
  grantedXp: state.grantedXp as number,
  grantedCoins: state.grantedCoins as number,
});
const exactForfeit = (state: CrownState, weight: number) =>
  exactRemainder({ ...state, forfeitedWeight: min(state.endowedWeight, add(state.forfeitedWeight, max(ZERO, halvesOnly(weight)))) });
const exactRescale = (state: CrownState, weights: readonly number[]) => {
  const endowedWeight = exactSum(weights);
  return exactRemainder({ ...state, endowedWeight, forfeitedWeight: min(endowedWeight, state.forfeitedWeight) });
};

const A_DAY = [1.5, 1.0, 1.0];
const weightLists: number[][] = [[], ...range(1, 3).flatMap(length => product<number>(...Array.from({ length }, () => [1.5, 1, 0])))];
const endowInputs: Json[] = [A_DAY, [0, 0], [...A_DAY, 1.5, 1.5], [1.5], [-1, 2.5], [20], [9, 0.5], ...weightLists];
const forfeitWeights = [-5, 0, 0.5, 1, 1.5, 3.5, 99];
const crownStateOf = (weights: readonly number[], forfeits: readonly number[]) =>
  forfeits.reduce((state, weight) => rules.forfeitCrownSlice(ruleset, state, weight), rules.endowCrown(ruleset, weights));
const crownStates = [
  crownStateOf(A_DAY, []),
  crownStateOf(A_DAY, [1.5]),
  crownStateOf(A_DAY, [3.5]),
  crownStateOf([1.5, 1.5, 1.5, 1, 1, 1, 1], [1]),
  crownStateOf([1, 1], [2]),
  crownStateOf([], []),
];
const forfeitInputs: Json[] = [
  { state: crownStateOf(A_DAY, []), weight: 1.5 },
  { state: crownStateOf(A_DAY, []), weight: 99 },
  { state: crownStateOf(A_DAY, []), weight: -5 },
  ...product<unknown>(crownStates, forfeitWeights).map(([state, weight]) => ({ state, weight })),
] as unknown as Json[];
const rescaleInputs: Json[] = [
  { state: crownStateOf(A_DAY, []), weights: [...A_DAY, 1.5, 1.5] },
  { state: crownStateOf(A_DAY, []), weights: [1.5] },
  { state: crownStateOf(A_DAY, [3.5]), weights: [1.5] },
  ...product<unknown>(crownStates, [[], [1.5], [1, 1], [...A_DAY, 1.5, 1.5], [20]]).map(([state, weights]) => ({ state, weights })),
] as unknown as Json[];
const recomputeCrownInputs: Json[] = [
  { weights: A_DAY, forfeited: [1.5, 1] },
  ...product<unknown>([A_DAY, [1.5, 1.5], [1, 1, 1, 1], []], [[], [1.5], [1, 1.5], [99], [-2, 0.5]]).map(([weights, forfeited]) => ({ weights, forfeited })),
] as unknown as Json[];

const isoDays = (from: string, count: number): string[] => {
  const start = rules.parseLocalDate(from);
  return Array.from({ length: count }, (_value, index) => rules.formatLocalDate(rules.addDays(start, index)) as string);
};
const crownDates = [...isoDays('2026-08-17', 28), ...isoDays('2026-12-26', 10), ...isoDays('2024-02-24', 10), ...isoDays('1970-01-01', 8)];
const period = (input: Json) => {
  const { cadence, date } = input as Record<string, string>;
  const result = rules.crownPeriodOf(ruleset, cadence, rules.parseLocalDate(date));
  return { cadence: result.cadence, start: rules.formatLocalDate(result.start), closesOn: rules.formatLocalDate(result.closesOn) };
};
const bankInputs: Json[] = [
  [crownStateOf(A_DAY, [])],
  [crownStateOf(A_DAY, []), crownStateOf(A_DAY, [1.5]), crownStateOf(A_DAY, [])],
  [],
  crownStates,
].map(clean);

const asStates = (input: Json) => (input as unknown as Record<string, number>[]).map(exactState);

fixture('crown.json', {
  crownWeightFor: {
    cases: cases('crownWeightFor', [...STRICTNESSES], strictness => rules.crownWeightFor(ruleset, strictness)),
    exact: input => decimal(ruleset.strictness[input as string].crownWeight),
  },
  crownCadenceFor: { cases: cases('crownCadenceFor', [...MODES], mode => rules.crownCadenceFor(ruleset, mode)) },
  crownShare: {
    cases: cases('crownShare', [0, 1, 1.5, 3.5, 4, 9, 20, ...range(-2, 30, 0.5)], weight => rules.crownShare(ruleset, weight)),
    exact: input => exactShare(halvesOnly(input as number)),
  },
  endowCrown: { cases: cases('endowCrown', endowInputs, weights => rules.endowCrown(ruleset, weights)), exact: input => exactEndow(input as number[]) },
  forfeitCrownSlice: {
    cases: cases('forfeitCrownSlice', forfeitInputs, input => rules.forfeitCrownSlice(ruleset, (input as Record<string, Json>).state, numberAt(input, 'weight'))),
    exact: input => exactForfeit(exactState((input as Record<string, Json>).state as Record<string, number>), numberAt(input, 'weight')),
  },
  rescaleCrown: {
    cases: cases('rescaleCrown', rescaleInputs, input => rules.rescaleCrown(ruleset, (input as Record<string, Json>).state, (input as Record<string, Json>).weights)),
    exact: input => exactRescale(exactState((input as Record<string, Json>).state as Record<string, number>), (input as Record<string, Json>).weights as number[]),
  },
  crownPeriodOf: {
    cases: cases('crownPeriodOf', product<unknown>(['daily', 'weekly'], crownDates).map(([cadence, date]) => ({ cadence, date })) as unknown as Json[], period),
  },
  isCrownPeriodClose: {
    cases: cases('isCrownPeriodClose', product<unknown>(['daily', 'weekly'], crownDates).map(([cadence, date]) => ({ cadence, date })) as unknown as Json[], input => {
      const { cadence, date } = input as Record<string, string>;
      return rules.isCrownPeriodClose(ruleset, cadence, rules.parseLocalDate(date));
    }),
  },
  crownBankAmount: {
    cases: cases('crownBankAmount', bankInputs, days => rules.crownBankAmount(days)),
    exact: input =>
      asStates(input)
        .map(exactRemainder)
        .reduce((total, day) => ({ xp: total.xp + day.remainingXp, coins: total.coins + day.remainingCoins }), { xp: 0, coins: 0 }),
  },
  recomputeCrownDay: {
    cases: cases('recomputeCrownDay', recomputeCrownInputs, input =>
      rules.recomputeCrownDay(ruleset, (input as Record<string, Json>).weights, (input as Record<string, Json>).forfeited),
    ),
    exact: input => {
      const { weights, forfeited } = input as Record<string, number[]>;
      return (forfeited as number[]).reduce((state, weight) => exactForfeit(state, weight), exactEndow(weights as number[]));
    },
  },
});

const dayState = (overrides: Record<string, Json> = {}) => ({ armed: false, fires: 0, armedViaRecovery: false, ...overrides });
const missLists: Json[] = [
  [],
  ...product<unknown>(range(0, 5), STRICTNESSES).map(([daysAgo, strictness]) => [{ daysAgo, strictness }]),
  ...runs(97, 24).map(next => Array.from({ length: 2 + integer(next, 2) }, () => ({ daysAgo: integer(next, 5), strictness: pick(next, STRICTNESSES) }))),
] as unknown as Json[];
const armingSpec: Json[] = [
  ['standard', [{ daysAgo: 1, strictness: 'anchor' }], 'warm'],
  ['standard', [{ daysAgo: 1, strictness: 'anchor' }], 'cold'],
  ['standard', [{ daysAgo: 3, strictness: 'anchor' }], 'cold'],
  ['standard', [{ daysAgo: 3, strictness: 'anchor' }], 'steady'],
  ['standard', [{ daysAgo: 4, strictness: 'anchor' }], 'cold'],
  ['standard', [{ daysAgo: 1, strictness: 'routine' }], 'cold'],
  ['standard', [], 'cold'],
  ['low_intensity', [{ daysAgo: 1, strictness: 'anchor' }], 'warm'],
  ['low_intensity', [{ daysAgo: 1, strictness: 'routine' }], 'warm'],
  ['low_intensity', [{ daysAgo: 3, strictness: 'routine' }], 'steady'],
  ['low_intensity', [{ daysAgo: 4, strictness: 'routine' }], 'cold'],
  ['low_intensity', [{ daysAgo: 1, strictness: 'optional' }], 'cold'],
  ['high_intensity', [{ daysAgo: 1, strictness: 'anchor' }], 'cold'],
  ['high_intensity', [{ daysAgo: 3, strictness: 'anchor' }], 'cold'],
  ['high_intensity', [{ daysAgo: 1, strictness: 'routine' }], 'cold'],
  ['standard', [{ daysAgo: 0, strictness: 'anchor' }], 'cold'],
  ['high_intensity', [{ daysAgo: 1, strictness: 'anchor' }], 'steady'],
].map(([intensityMode, recentMisses, momentum]) => ({ intensityMode, recentMisses, momentum, returnerFired: false })) as unknown as Json[];
armingSpec.push({ intensityMode: 'standard', recentMisses: [{ daysAgo: 1, strictness: 'anchor' }], momentum: 'cold', returnerFired: true });
const armingGrid = product<unknown>(MODES, MOMENTUM, [false, true], missLists).map(([intensityMode, momentum, returnerFired, recentMisses]) => ({
  intensityMode,
  momentum,
  returnerFired,
  recentMisses,
})) as unknown as Json[];
const dayStates = product<unknown>([false, true], range(0, 3), [false, true]).map(([armed, fires, armedViaRecovery]) =>
  dayState({ armed, fires, armedViaRecovery }),
) as unknown as Json[];
const fireInputs = product<unknown>(dayStates, STRICTNESSES).map(([state, strictness]) => ({ state, strictness })) as unknown as Json[];
const once = rules.fireComeback(ruleset, dayState({ armed: true }), 'anchor').state;
const rearmed = rules.armComebackViaRecovery(once);
const twice = rules.fireComeback(ruleset, rearmed, 'routine');
const fireSpec: Json[] = [
  { state: dayState({ armed: true }), strictness: 'anchor' },
  { state: once, strictness: 'anchor' },
  { state: rearmed, strictness: 'routine' },
  { state: twice.state, strictness: 'routine' },
  { state: dayState(), strictness: 'anchor' },
  ...STRICTNESSES.map(strictness => ({ state: dayState({ armed: true }), strictness })),
];

const claimedDomain = product<unknown>(STRICTNESSES, BANDS, COMPLETIONS, TIER_DAYS, [false, true]).map(
  ([strictness, band, completion, streakDays, lockActive]) => ({ strictness, band, completion, streakDays, lockActive, oneShot: 'none' }) as RewardInput,
);
const bonusInputs: Json[] = [
  rewardInput({ strictness: 'routine' }),
  rewardInput({ strictness: 'optional' }),
  rewardInput({ strictness: 'anchor', streakDays: 100, lockActive: true }),
  ...claimedDomain,
] as unknown as Json[];
const netSpec = (
  [
    ['anchor', 'anchor'],
    ['anchor', 'routine'],
    ['routine', 'anchor'],
    ['routine', 'routine'],
  ] as const
).map(([forgone, claimed]) => ({ forgone: rewardInput({ strictness: forgone }), claimed: rewardInput({ strictness: claimed, streakDays: 100, lockActive: true }) }));
const netGrid = product<unknown>(STRICTNESSES, claimedDomain.filter(input => input.strictness === 'anchor' || input.strictness === 'routine')).map(([forgone, claimed]) => ({
  forgone: rewardInput({ strictness: forgone as string }),
  claimed,
}));

const exactBonus = (claimed: RewardInput) => {
  const withBonus = exactReward({ ...claimed, oneShot: 'comeback' });
  const without = exactReward({ ...claimed, oneShot: 'none' });
  return { xp: withBonus.xp - without.xp, coins: withBonus.coins - without.coins };
};

fixture('comeback.json', {
  evaluateComebackArming: {
    cases: [
      ...cases('spec', armingSpec, input => rules.evaluateComebackArming(ruleset, input)),
      ...cases('grid', armingGrid, input => rules.evaluateComebackArming(ruleset, input)),
    ],
  },
  comebackFireAllowance: { cases: cases('comebackFireAllowance', dayStates, state => rules.comebackFireAllowance(ruleset, state)) },
  canFireComeback: {
    cases: cases('canFireComeback', fireInputs, input => rules.canFireComeback(ruleset, (input as Record<string, Json>).state, (input as Record<string, Json>).strictness)),
  },
  fireComeback: {
    cases: [
      ...cases('spec', fireSpec, input => rules.fireComeback(ruleset, (input as Record<string, Json>).state, (input as Record<string, Json>).strictness)),
      ...cases('grid', fireInputs, input => rules.fireComeback(ruleset, (input as Record<string, Json>).state, (input as Record<string, Json>).strictness)),
    ],
  },
  armComebackViaRecovery: { cases: cases('armComebackViaRecovery', dayStates, state => rules.armComebackViaRecovery(state)) },
  comebackBonus: {
    cases: cases('comebackBonus', bonusInputs, claimed => rules.comebackBonus(ruleset, claimed)),
    exact: input => exactBonus(input as unknown as RewardInput),
  },
  comebackNetXp: {
    cases: [
      ...cases('spec', netSpec as unknown as Json[], input => rules.comebackNetXp(ruleset, input)),
      ...cases('grid', netGrid as unknown as Json[], input => rules.comebackNetXp(ruleset, input)),
    ],
    exact: input => {
      const { forgone, claimed } = input as unknown as Record<string, RewardInput>;
      return exactBonus(claimed as RewardInput).xp - exactReward({ ...(forgone as RewardInput), oneShot: 'none' }).xp;
    },
  },
});

const candidate = (questId: string, preAbsenceStreakDays: number, createdOrder: number, shields = 0) => ({ questId, preAbsenceStreakDays, createdOrder, shields });
const candidateLists: Json[] = [
  [candidate('a', 3, 1), candidate('b', 12, 2), candidate('c', 9, 3)],
  [candidate('older', 12, 1), candidate('newer', 12, 5), candidate('newest-but-shorter', 11, 9)],
  [candidate('a', 0, 1)],
  [],
  [candidate('a', 12, 1, 1)],
  [candidate('a', 12, 1, 2)],
  [candidate('a', 12, 1, 2), candidate('b', 4, 2, 0)],
  [candidate('a', 5, 3, 3)],
  ...runs(83, 40).map(next =>
    Array.from({ length: 1 + integer(next, 4) }, (_value, index) => candidate(`q${index}`, integer(next, 6), integer(next, 9), integer(next, 3))),
  ),
];

const returnerGrid = product<unknown>(range(0, 30), [null, 1, 3, 7, 14, 21]).map(([daysSinceLastActivity, thresholdDays]) => ({
  daysSinceLastActivity,
  thresholdDays,
})) as unknown as Json[];

fixture('returner.json', {
  returnerThresholdFor: { cases: cases('returnerThresholdFor', [null, 21, 0, 3, 7], threshold => rules.returnerThresholdFor(ruleset, threshold)) },
  returnerFires: {
    cases: [
      ...cases('spec', [
        [0, null],
        [6, null],
        [7, null],
        [30, null],
        [7, 14],
        [14, 14],
        [3, 3],
      ].map(([daysSinceLastActivity, thresholdDays]) => ({ daysSinceLastActivity, thresholdDays })) as unknown as Json[], input => rules.returnerFires(ruleset, input)),
      ...cases('grid', returnerGrid, input =>
        rules.returnerFires(ruleset, input),
      ),
    ],
  },
  returnerShieldTarget: { cases: cases('returnerShieldTarget', candidateLists, list => rules.returnerShieldTarget(list)) },
  planReturnerShieldGrant: { cases: cases('planReturnerShieldGrant', candidateLists, list => rules.planReturnerShieldGrant(ruleset, list)) },
});

const exactMedian = (values: readonly number[]): Q => {
  if (values.length === 0) return ZERO;
  const sorted = [...values].sort((left, right) => left - right);
  const middle = Math.floor(sorted.length / 2);
  if (sorted.length % 2 === 1) return int(sorted[middle] as number);
  return div(add(int(sorted[middle - 1] as number), int(sorted[middle] as number)), int(2));
};
const exactTrailing = (values: readonly number[], windowDays: number) => exactMedian(values.slice(0, Math.max(0, windowDays)));
const exactMomentum = (input: { recentCompletions: number[]; trailingCompletions: number[] }) => {
  const rulesOf = ruleset.momentum;
  const weighted = (rulesOf.recentDayWeights as number[]).reduce<Q>(
    (total, weight, index) => add(total, mul(decimal(weight), int(Math.max(0, input.recentCompletions[index] ?? 0)))),
    ZERO,
  );
  const median = exactTrailing(input.trailingCompletions, rulesOf.medianWindowDays);
  if (cmp(median, ZERO) === 0) return { weighted, median, ratio: null, bucket: cmp(weighted, ZERO) > 0 ? 'warm' : 'cold' };
  const ratio = div(weighted, median);
  if (cmp(ratio, decimal(rulesOf.coldBelowRatio)) < 0) return { weighted, median, ratio, bucket: 'cold' };
  if (cmp(ratio, decimal(rulesOf.warmAboveRatio)) > 0) return { weighted, median, ratio, bucket: 'warm' };
  return { weighted, median, ratio, bucket: 'steady' };
};

const flat = (value: number, days = 14) => Array.from({ length: days }, () => value);
const halvesTrailing = (doubled: number) => [Math.floor(doubled / 2), Math.ceil(doubled / 2)];
const medianInputs: Json[] = [
  [],
  [4],
  [3, 1, 2],
  [4, 1, 3, 2],
  [0, 0, 0, 9],
  [-3, 5],
  [-4, -1],
  ...runs(89, 60).map(next => Array.from({ length: integer(next, 9) }, () => integer(next, 20) - 4)),
];
const momentumSpec = [
  { recentCompletions: [2, 1, 4], trailingCompletions: flat(3) },
  { recentCompletions: [-5, 0, 0], trailingCompletions: flat(3) },
  ...(
    [
      [[0, 0, 0], 4],
      [[1, 0, 0], 4],
      [[2, 0, 0], 10],
      [[3, 0, 0], 10],
      [[4, 0, 0], 4],
      [[11, 0, 0], 10],
      [[12, 0, 0], 10],
      [[10, 0, 0], 4],
    ] as const
  ).map(([recent, median]) => ({ recentCompletions: [...recent], trailingCompletions: flat(median) })),
  { recentCompletions: [0, 0, 0], trailingCompletions: [] },
  { recentCompletions: [3, 0, 0], trailingCompletions: flat(0) },
  { recentCompletions: [1, 0, 0], trailingCompletions: [...flat(1, 14), ...flat(50, 30)] },
  { recentCompletions: [0, 3, 0], trailingCompletions: flat(7) },
  { recentCompletions: [2, 0, 0], trailingCompletions: [-4, 0] },
  { recentCompletions: [0, 0, 0], trailingCompletions: [-4, 0] },
  { recentCompletions: [0, -2, 9], trailingCompletions: [5] },
];
const momentumGrid = product<unknown>(range(0, 6), range(0, 6), range(0, 6), range(0, 20)).map(([c0, c1, c2, doubled]) => ({
  recentCompletions: [c0, c1, c2],
  trailingCompletions: halvesTrailing(doubled as number),
}));

fixture('momentum.json', {
  medianOf: { cases: cases('medianOf', medianInputs, values => rules.medianOf(values)), exact: input => exactMedian(input as number[]) },
  trailingMedian: {
    cases: cases(
      'trailingMedian',
      [
        { values: [4, 4, 4, 100, 100, 100], windowDays: 3 },
        { values: [2, 4], windowDays: 14 },
        { values: [5, 5], windowDays: 0 },
        { values: [5, 7, 1], windowDays: -2 },
        { values: [9, 1, 4, 6], windowDays: 2 },
      ],
      input => rules.trailingMedian((input as Record<string, Json>).values, numberAt(input, 'windowDays')),
    ),
    exact: input => exactTrailing((input as Record<string, number[]>).values as number[], numberAt(input, 'windowDays')),
  },
  computeMomentum: {
    cases: [
      ...cases('spec', momentumSpec, input => rules.computeMomentum(ruleset, input)),
      ...cases('grid', momentumGrid as unknown as Json[], input => rules.computeMomentum(ruleset, input)),
    ],
    exact: input => exactMomentum(input as unknown as { recentCompletions: number[]; trailingCompletions: number[] }),
  },
});

const exactCapacity = (input: { trailingCompletions: number[]; momentum: string; priorDayHeavyMiss: boolean }) => {
  const rulesOf = ruleset.capacity;
  const baseline =
    input.trailingCompletions.length === 0
      ? int(rulesOf.newUserBaselineCap)
      : mul(exactTrailing(input.trailingCompletions, rulesOf.medianWindowDays), decimal(rulesOf.ratchetFactor));
  const cold = input.momentum === 'cold' ? decimal(rulesOf.coldMomentumFactor) : ONE;
  const heavyMiss = input.priorDayHeavyMiss ? decimal(rulesOf.heavyMissDayFactor) : ONE;
  return { baseline, capacity: toNumber(max(ONE, roundHalfUp(mul(mul(baseline, cold), heavyMiss)))) };
};
const exactWarning = (input: { plannedLoad: number; capacity: number; onLockAttempt: boolean; daysSinceLastSoftWarning: number | null }) => {
  const rulesOf = ruleset.capacity;
  const above = (threshold: number) => input.capacity <= 0 || cmp(q(BigInt(input.plannedLoad), BigInt(input.capacity)), decimal(threshold)) > 0;
  if (input.onLockAttempt && above(rulesOf.modalWarningRatio)) return 'modal';
  const throttled = input.daysSinceLastSoftWarning !== null && input.daysSinceLastSoftWarning < rulesOf.softWarningThrottleDays;
  return above(rulesOf.softWarningRatio) && !throttled ? 'soft' : 'none';
};

const capacityTrailing: number[][] = [
  [],
  ...[1, 2, 4, 10, 20].map(median => flat(median)),
  ...range(0, 40).map(median => flat(median)),
  ...range(0, 60).map(halvesTrailing),
  [...flat(2, 14), ...flat(40, 20)],
  [-4, 2],
  [-9],
  [7, 3, 9, 1, 12, 5, 6, 8, 2, 4, 11, 10, 13, 14, 99],
];
const capacityInputs = product<unknown>(capacityTrailing, MOMENTUM, [false, true]).map(([trailingCompletions, momentum, priorDayHeavyMiss]) => ({
  trailingCompletions,
  momentum,
  priorDayHeavyMiss,
}));
const warningSpec = (
  [
    [8, 10, false, null],
    [10, 10, false, null],
    [11, 10, false, null],
    [11, 10, false, 7],
    [11, 10, false, 6],
    [11, 10, false, 0],
    [13, 10, false, null],
    [14, 10, false, null],
    [13, 10, true, null],
    [14, 10, true, null],
    [14, 10, true, 0],
    [1, 0, false, null],
  ] as const
).map(([plannedLoad, capacity, onLockAttempt, daysSinceLastSoftWarning]) => ({ plannedLoad, capacity, onLockAttempt, daysSinceLastSoftWarning }));
const warningGrid = product<unknown>(range(0, 30), range(-1, 20), [false, true], [null, 0, 6, 7, 8]).map(([plannedLoad, capacity, onLockAttempt, daysSinceLastSoftWarning]) => ({
  plannedLoad,
  capacity,
  onLockAttempt,
  daysSinceLastSoftWarning,
}));

fixture('capacity.json', {
  computeCapacity: {
    cases: cases('computeCapacity', capacityInputs as unknown as Json[], input => rules.computeCapacity(ruleset, input)),
    exact: input => exactCapacity(input as unknown as { trailingCompletions: number[]; momentum: string; priorDayHeavyMiss: boolean }),
  },
  capacityWarningFor: {
    cases: [
      ...cases('spec', warningSpec as unknown as Json[], input => rules.capacityWarningFor(ruleset, input)),
      ...cases('grid', warningGrid as unknown as Json[], input => rules.capacityWarningFor(ruleset, input)),
    ],
    exact: input => exactWarning(input as unknown as { plannedLoad: number; capacity: number; onLockAttempt: boolean; daysSinceLastSoftWarning: number | null }),
  },
  anchorSoftCapWarned: { cases: cases('anchorSoftCapWarned', range(0, 10), count => rules.anchorSoftCapWarned(ruleset, count)) },
});

type Counters = Record<string, unknown>;
const EMPTY = rules.EMPTY_PROGRESS_COUNTERS as Counters;
const counters = (patch: Record<string, unknown> = {}): Counters => ({
  ...EMPTY,
  ...patch,
  stats: { ...(EMPTY.stats as object), ...((patch.stats as object) ?? {}) },
  completionsByStrictness: { ...(EMPTY.completionsByStrictness as object), ...((patch.completionsByStrictness as object) ?? {}) },
});
const ALL_STATS_TOUCHED = { stats: { discipline: 1, body: 1, wealth: 1, mind: 1 } };
const ALL_STATS_AT_30 = { stats: { discipline: 30, body: 30, wealth: 30, mind: 30 } };

const thresholdPatches: Record<string, unknown>[] = [
  ...(
    [
      ['questsCompleted', 1],
      ['level', 2],
      ['longestStreakDays', 3],
      ['longestStreakDays', 7],
      ['longestStreakDays', 30],
      ['longestStreakDays', 100],
      ['totalXp', 100],
      ['totalXp', 500],
      ['subscriptionsConfirmed', 1],
      ['receiptsScanned', 1],
      ['fullHpDays', 1],
      ['crownsBanked', 1],
      ['lockedDaysCleared', 1],
      ['lockedDaysCleared', 10],
      ['comebackBonusesClaimed', 1],
      ['comebackBonusesClaimed', 10],
      ['returnerRitualsCompleted', 1],
      ['longestAnchorStreakDays', 30],
      ['questsReachingSilverStreak', 3],
      ['reschedulesWithReasonIn90Days', 10],
      ['reasonTaggedEvents', 20],
      ['completionsAfterReturner', 1],
      ['activeDays', 365],
    ] as const
  ).flatMap(([field, threshold]) => [-1, 0, 1].map(delta => ({ [field]: threshold + delta }))),
  ...(
    [
      ['recovery', 1],
      ['recovery', 5],
      ['goal', 30],
      ['routine', 100],
      ['optional', 30],
    ] as const
  ).flatMap(([strictness, threshold]) => [-1, 0, 1].map(delta => ({ completionsByStrictness: { [strictness]: threshold + delta } }))),
  ...(['discipline', 'body', 'wealth', 'mind'] as const).flatMap(stat => [59, 60, 61].map(value => ({ stats: { [stat]: value } }))),
  ...[0, 1, 2, 29, 30, 31].flatMap(value => [
    { stats: { discipline: value, body: value, wealth: value, mind: value } },
    { stats: { discipline: 90, body: 90, wealth: 90, mind: value } },
  ]),
  {},
  ALL_STATS_TOUCHED,
  ALL_STATS_AT_30,
  { stats: { discipline: 40, body: 40, wealth: 40 } },
  { stats: { discipline: 90, body: 90, wealth: 90, mind: 29 } },
  { level: 0 },
  { totalXp: -5 },
];
const thresholdCounters = thresholdPatches.map(patch => counters(patch)) as unknown as Json[];
const recomputeHistories: Json[] = [
  [
    counters({ questsCompleted: 1, totalXp: 12, level: 1 }),
    counters({ questsCompleted: 9, totalXp: 104, level: 2, longestStreakDays: 7, ...ALL_STATS_TOUCHED }),
    counters({ questsCompleted: 40, totalXp: 520, level: 4, longestStreakDays: 31, crownsBanked: 2, ...ALL_STATS_TOUCHED }),
  ],
  [counters({ reschedulesWithReasonIn90Days: 10 }), counters({ reschedulesWithReasonIn90Days: 0 })],
  [counters({ crownsBanked: 1 }), counters({ questsCompleted: 1 })],
  [],
] as unknown as Json[];
const unlockedInputs: Json[] = [
  { counters: counters({ questsCompleted: 4, totalXp: 120, level: 3 }), earned: [] },
  { counters: counters({ questsCompleted: 4, totalXp: 120, level: 3 }), earned: ['first_quest_completed', 'xp_100'] },
  { counters: counters({ questsCompleted: 4, totalXp: 120, level: 3 }), earned: ['first_quest_completed', 'first_level_up', 'xp_100'] },
  { counters: counters({ stats: { discipline: 60 }, activeDays: 365 }), earned: [] },
  { counters: counters({ stats: { discipline: 60 }, activeDays: 365 }), earned: ['steady_builder'] },
  { counters: counters({ stats: { discipline: 60 }, activeDays: 365 }), earned: ['quiet_year', 'steady_builder', 'first_quest_completed'] },
] as unknown as Json[];

fixture('catalogue.json', {
  achievementIds: { cases: cases('achievementIds', [null], () => rules.ACHIEVEMENTS.map((achievement: { id: string }) => achievement.id)) },
  titleIds: { cases: cases('titleIds', [null], () => rules.TITLES.map((title: { id: string }) => title.id)) },
  satisfiedAchievements: { cases: cases('satisfiedAchievements', thresholdCounters, input => rules.satisfiedAchievements(ruleset, input)) },
  satisfiedTitles: { cases: cases('satisfiedTitles', thresholdCounters, input => rules.satisfiedTitles(ruleset, input)) },
  unlockedAchievements: {
    cases: cases('unlockedAchievements', unlockedInputs, input =>
      rules.unlockedAchievements(ruleset, (input as Record<string, Json>).counters, (input as Record<string, Json>).earned),
    ),
  },
  unlockedTitles: {
    cases: cases('unlockedTitles', unlockedInputs, input => rules.unlockedTitles(ruleset, (input as Record<string, Json>).counters, (input as Record<string, Json>).earned)),
  },
  recomputeAchievements: { cases: cases('recomputeAchievements', recomputeHistories, history => rules.recomputeAchievements(ruleset, history)) },
  recomputeTitles: { cases: cases('recomputeTitles', recomputeHistories, history => rules.recomputeTitles(ruleset, history)) },
});

// properties.spec.ts: the same seeds, runs and draw order, so every generated input is one the reference test checks.

const PUNISHABLE = ['anchor', 'routine'] as const;

const netNegative = runs(11).map(next => {
  const forgone = { strictness: pick(next, PUNISHABLE), band: 'on_time', completion: 'full', streakDays: 0, lockActive: false, oneShot: 'none' };
  const claimed = {
    strictness: pick(next, PUNISHABLE),
    band: pick(next, BANDS),
    completion: pick(next, COMPLETIONS),
    streakDays: integer(next, 400),
    lockActive: next() < 0.5,
    oneShot: 'comeback',
  };
  return { forgone, claimed };
});
const bonusCoins = runs(23).map(next => ({
  strictness: pick(next, PUNISHABLE),
  band: pick(next, BANDS),
  completion: pick(next, COMPLETIONS),
  streakDays: integer(next, 400),
  lockActive: next() < 0.5,
  oneShot: 'comeback',
}));
const recoveryNeutral = runs(37).map(next => {
  const intensityMode = pick(next, MODES);
  const state = pick(next, STATES);
  const streakDaysBefore = integer(next, 400);
  const streak = { ...EMPTY_STREAK, currentDays: streakDaysBefore, longestDays: streakDaysBefore, shields: integer(next, 2) };
  const event = { state, strictness: 'recovery', intensityMode, streakOptIn: next() < 0.5, onTime: next() < 0.5 };
  return { intensityMode, hpBreak: { occurrenceKey: 'r', strictness: 'recovery', state, shielded: false, streakDaysBefore }, streak, event };
});
const missesOf = (seed: number, strictness: string) =>
  runs(seed).map(next => {
    const recentMisses = Array.from({ length: integer(next, 5) }, () => ({ daysAgo: integer(next, 3), strictness }));
    return { intensityMode: pick(next, MODES), momentum: pick(next, MOMENTUM), returnerFired: false, recentMisses };
  });
const optionalNeutral = runs(53).map(next => {
  const state = pick(next, STATES);
  const streakDaysBefore = integer(next, 400);
  return { mode: pick(next, MODES), event: { occurrenceKey: 'o', strictness: 'optional', state, shielded: false, streakDaysBefore } };
});
const optionalStreak = runs(59).map(next => {
  const streak = { ...EMPTY_STREAK, currentDays: integer(next, 400), shields: integer(next, 2) };
  const event = { state: pick(next, STATES), strictness: 'optional', intensityMode: pick(next, MODES), streakOptIn: false, onTime: next() < 0.5 };
  return { state: streak, event };
});
const streakSequences = runs(67).map(next =>
  Array.from({ length: 40 }, () => [pick(next, STATES), pick(next, ['anchor', 'routine', 'goal'] as const), pick(next, MODES), next() < 0.5]),
);
const hpDays = runs(71).map(next => {
  const mode = pick(next, MODES);
  const breaks = Array.from({ length: integer(next, 6) }, (_value, index) => ({
    occurrenceKey: `quest-${index}`,
    strictness: pick(next, ['anchor', 'routine', 'goal', 'optional'] as const),
    state: pick(next, STATES),
    shielded: next() < 0.5,
    streakDaysBefore: integer(next, 400),
  }));
  return { mode, previousHpEnd: integer(next, 8), breaks };
});
const PROGRESS_STEPS = [
  ['totalXp', 80],
  ['level', 1],
  ['questsCompleted', 4],
  ['longestStreakDays', 12],
  ['longestAnchorStreakDays', 6],
  ['questsReachingSilverStreak', 1],
  ['crownsBanked', 2],
  ['activeDays', 40],
] as const;
const STAT_STEPS = ['discipline', 'body', 'wealth', 'mind'] as const;
const progressions = runs(73).map(next =>
  Array.from({ length: 12 }, () => [...PROGRESS_STEPS.map(([, upper]) => integer(next, upper)), ...STAT_STEPS.map(() => integer(next, 9))]),
);
const replayProgression = (steps: number[][]) => {
  let current = EMPTY as Record<string, any>;
  return steps.map(step => {
    current = {
      ...current,
      ...Object.fromEntries(PROGRESS_STEPS.map(([field], index) => [field, current[field] + (step[index] as number)])),
      stats: Object.fromEntries(STAT_STEPS.map((stat, index) => [stat, current.stats[stat] + (step[PROGRESS_STEPS.length + index] as number)])),
    };
    return { achievements: rules.satisfiedAchievements(ruleset, current), titles: rules.satisfiedTitles(ruleset, current) };
  });
};

const STREAK_FIELDS = ['currentDays', 'longestDays', 'shields', 'completionsTowardShield', 'pendingShieldGrant'] as const;
const streakFold = (events: [string, string, string, boolean][]) => {
  let state: Record<string, number> = EMPTY_STREAK;
  return events.map(([logState, strictness, intensityMode, onTime]) => {
    const transition = rules.applyStreakEvent(ruleset, state, { state: logState, strictness, intensityMode, streakOptIn: false, onTime });
    state = transition.state;
    return [transition.outcome, ...STREAK_FIELDS.map(field => state[field] as number)];
  });
};

fixture('properties.json', {
  comebackNetNegative: {
    cases: cases('comebackNetNegative', netNegative as unknown as Json[], input => rules.comebackNetXp(ruleset, input)),
    exact: input => {
      const { forgone, claimed } = input as unknown as Record<string, RewardInput>;
      return exactBonus(claimed as RewardInput).xp - exactReward({ ...(forgone as RewardInput), oneShot: 'none' }).xp;
    },
  },
  comebackBonusCoins: {
    cases: cases('comebackBonusCoins', bonusCoins as unknown as Json[], input => rules.comebackBonus(ruleset, input)),
    exact: input => exactBonus(input as unknown as RewardInput),
  },
  recoveryNeutral: {
    cases: cases('recoveryNeutral', recoveryNeutral as unknown as Json[], input => {
      const { intensityMode, hpBreak: event, streak, event: streakEventInput } = input as Record<string, Json>;
      return { hpCost: rules.hpCostFor(ruleset, intensityMode, event), transition: rules.applyStreakEvent(ruleset, streak, streakEventInput) };
    }),
  },
  recoveryMissesNeverArm: { cases: cases('recoveryMissesNeverArm', missesOf(41, 'recovery') as unknown as Json[], input => rules.evaluateComebackArming(ruleset, input)) },
  optionalNeutralHp: {
    cases: cases('optionalNeutralHp', optionalNeutral as unknown as Json[], input =>
      rules.hpCostFor(ruleset, (input as Record<string, Json>).mode, (input as Record<string, Json>).event),
    ),
  },
  optionalNeutralStreak: {
    cases: cases('optionalNeutralStreak', optionalStreak as unknown as Json[], input =>
      rules.applyStreakEvent(ruleset, (input as Record<string, Json>).state, (input as Record<string, Json>).event),
    ),
  },
  optionalMissesNeverArm: { cases: cases('optionalMissesNeverArm', missesOf(61, 'optional') as unknown as Json[], input => rules.evaluateComebackArming(ruleset, input)) },
  streakSequences: { cases: cases('streakSequences', streakSequences as unknown as Json[], events => streakFold(events as unknown as [string, string, string, boolean][])) },
  dayHp: { cases: cases('dayHp', hpDays as unknown as Json[], dayHp) },
  progressions: {
    cases: cases('progressions', progressions as unknown as Json[], steps => replayProgression(steps as number[][])),
  },
});

writeFileSync(
  join(outDir, 'divergences.json'),
  `{\n"count": ${divergences.length},\n"cases": [\n${divergences.map(entry => JSON.stringify(entry)).join(',\n')}\n]\n}\n`,
);

if (divergences.some(entry => entry.file === 'level.json')) throw new Error('the reference level curve differs from the exact model; the table cannot be taken from it');

const levelLines: string[] = [];
const swiftInteger = (value: number): string => (value >= 1_000_000 ? value.toLocaleString('en-US').replace(/,/g, '_') : String(value));
let line = '     ';
for (const cost of levelCosts) {
  const piece = ` ${swiftInteger(cost)},`;
  if (line.length + piece.length > 179) {
    levelLines.push(line);
    line = '     ';
  }
  line += piece;
}
levelLines.push(line);
writeFileSync(
  levelTableSwift,
  [
    '// Generated by Packages/MemoirKit/Fixtures/rules/generate.ts from the reference xpToAdvance; regenerate, never edit.',
    'extension LevelCurve {',
    `  static let v1 = LevelCurve(`,
    `    maxLevel: ${ruleset.level.maxLevel},`,
    '    xpToAdvance: [',
    ...levelLines,
    '    ]',
    '  )',
    '}',
    '',
  ].join('\n'),
);

const byRule = new Map<string, number>();
for (const entry of divergences) {
  const rule = `${entry.file.replace('.json', '')}.${entry.function} [${entry.fields.join(', ')}]`;
  byRule.set(rule, (byRule.get(rule) ?? 0) + 1);
}
process.stdout.write(`${divergences.length} divergent cases\n${[...byRule].map(([rule, count]) => `  ${rule}: ${count}`).join('\n')}\n`);
