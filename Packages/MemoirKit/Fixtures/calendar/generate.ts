import { mock } from 'bun:test';
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');
const outDir = dirname(fileURLToPath(import.meta.url));
const src = join(platformRepo, 'apps/memoir-server/src');

const rules = await import(join(src, 'modules/rules/index.ts'));
mock.module('@modules/rules', () => rules);
mock.module('@shadow-library/common', () => ({
  AppError: {
    internal: (message: string) => new Error(message),
  },
}));
mock.module('@server/database', () => ({}));
const { advanceDueDate } = await import(join(src, 'modules/finance/subscription-cycle.ts'));

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
interface Case {
  id: string;
  input: Json;
  output: Json;
}
interface RefDate {
  year: number;
  month: number;
  day: number;
}

const writeJson = (name: string, groups: Record<string, readonly unknown[]>): void => {
  const body = Object.entries(groups)
    .map(([key, items]) => `${JSON.stringify(key)}: [\n${items.map(item => JSON.stringify(item)).join(',\n')}\n]`)
    .join(',\n');
  writeFileSync(join(outDir, name), `{\n${body}\n}\n`);
};

const clean = (value: unknown): Json => JSON.parse(JSON.stringify(value)) as Json;

const fixture = (file: string, groups: Record<string, Case[]>): void => {
  for (const [name, entries] of Object.entries(groups)) {
    const ids = new Set<string>();
    for (const entry of entries) {
      if (ids.has(entry.id)) throw new Error(`duplicate case id ${name}/${entry.id}`);
      ids.add(entry.id);
    }
  }
  writeJson(file, groups);
};

const cases = <T>(name: string, inputs: readonly T[], call: (input: T) => unknown, id?: (input: T) => string): Case[] =>
  inputs.map((input, index) => ({ id: id ? id(input) : `${name}#${index}`, input: clean(input), output: clean(call(input)) }));

const lcg = (seed: number) => {
  let state = seed >>> 0;
  return () => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state / 0x1_0000_0000;
  };
};
const pick = <T>(next: () => number, values: readonly T[]): T => values[Math.floor(next() * values.length)] ?? (values[0] as T);
const between = (next: () => number, lower: number, upper: number): number => lower + Math.floor(next() * (upper - lower + 1));
const range = (from: number, to: number, step = 1): number[] => {
  const values: number[] = [];
  for (let value = from; value <= to; value += step) values.push(value);
  return values;
};

const iso = (date: RefDate): string => rules.formatLocalDate(date);
const date = (text: string): RefDate => {
  const parsed = rules.parseLocalDate(text);
  if (!parsed) throw new Error(`not an ISO date: ${text}`);
  return parsed;
};
const isoOrNull = (value: RefDate | null): string | null => (value === null ? null : iso(value));

const EPOCH_1900 = rules.epochDayOf(date('1900-01-01')) as number;
const EPOCH_2100 = rules.epochDayOf(date('2100-12-31')) as number;
const civilDay = (next: () => number, from = EPOCH_1900, to = EPOCH_2100): string => iso(rules.localDateFromEpochDay(between(next, from, to)));

// Civil-date arithmetic: the spec literals, then seeded grids over 1900 to 2100.

const civil = lcg(0x1900_2100);
const civilDays = Array.from({ length: 600 }, () => civilDay(civil));
const boundaryDays = ['1900-01-01', '1900-02-28', '1900-03-01', '1999-12-31', '2000-02-29', '2000-03-01', '2024-02-29', '2100-02-28', '2100-03-01', '2100-12-31'];

const isoDates = [...['1970-01-01', '2024-02-29', '2024-12-31', '2100-03-01', '1999-12-31'], ...boundaryDays, ...civilDays];

fixture('time.json', {
  isLeapYear: cases('isLeapYear', [2023, 2024, 1900, 2000, 2100, 2400, ...range(1900, 2100)], year => rules.isLeapYear(year)),
  daysInMonth: cases(
    'daysInMonth',
    [
      [2024, 1],
      [2024, 2],
      [2023, 2],
      [1900, 2],
      [2000, 2],
      [2024, 4],
      [2024, 12],
      ...range(1900, 2100, 4).flatMap(year => range(1, 12).map(month => [year, month])),
      ...range(1901, 2100, 4).flatMap(year => [[year, 2]]),
    ],
    ([year, month]) => rules.daysInMonth(year, month),
  ),
  clampToMonthEnd: cases(
    'clampToMonthEnd',
    [
      [2024, 4, 31],
      [2024, 2, 31],
      [2023, 2, 31],
      [2025, 2, 29],
      [2024, 6, 15],
      ...Array.from({ length: 600 }, () => [between(civil, 1900, 2100), between(civil, 1, 12), between(civil, 1, 40)]),
    ],
    ([year, month, day]) => iso(rules.clampToMonthEnd(year, month, day)),
  ),
  parseLocalDate: cases(
    'parseLocalDate',
    [
      '2024-02-29',
      '2024-2-29',
      '2023-02-29',
      '2024-13-01',
      '2024-00-10',
      '2024-04-31',
      'not-a-date',
      '',
      '1900-02-29',
      '2000-02-29',
      '2100-02-29',
      '0000-01-01',
      '9999-12-31',
      '2024-01-00',
      '2024-01-32',
      ' 2024-01-01',
      '2024-01-01T00:00',
      ...civilDays.slice(0, 100),
    ],
    text => isoOrNull(rules.parseLocalDate(text)),
  ),
  epochDayOf: cases('epochDayOf', isoDates, text => rules.epochDayOf(date(text))),
  localDateFromEpochDay: cases('localDateFromEpochDay', [0, -1, 19_782, EPOCH_1900, EPOCH_2100, ...Array.from({ length: 300 }, () => between(civil, EPOCH_1900, EPOCH_2100))], day =>
    iso(rules.localDateFromEpochDay(day)),
  ),
  addDays: cases(
    'addDays',
    [
      ['2024-02-28', 1],
      ['2023-02-28', 1],
      ['2024-12-31', 1],
      ['2024-01-01', -1],
      ['2024-03-09', 366],
      ...Array.from({ length: 400 }, () => [civilDay(civil, EPOCH_1900 + 1000, EPOCH_2100 - 1000), between(civil, -1000, 1000)] as const),
    ],
    ([from, days]) => iso(rules.addDays(date(from as string), days as number)),
  ),
  daysBetween: cases(
    'daysBetween',
    [
      ['2024-02-28', '2024-02-29'],
      ['2023-02-28', '2023-03-01'],
      ['2024-12-31', '2025-01-01'],
      ['2024-01-01', '2023-12-31'],
      ['2024-03-09', '2025-03-10'],
      ...Array.from({ length: 300 }, () => [civilDay(civil), civilDay(civil)]),
    ],
    ([from, to]) => rules.daysBetween(date(from as string), date(to as string)),
  ),
  addMonths: cases(
    'addMonths',
    [
      ['2024-01-31', 1],
      ['2023-01-31', 1],
      ['2024-01-31', 3],
      ['2024-12-15', 1],
      ['2024-01-15', -1],
      ['2024-01-15', -13],
      ...Array.from({ length: 600 }, () => [civilDay(civil, EPOCH_1900 + 1000, EPOCH_2100 - 1000), between(civil, -36, 36)] as const),
      ...['2024-01-29', '2024-01-30', '2024-01-31', '2023-03-31', '2000-01-31', '1900-01-31'].flatMap(from => range(-14, 14).map(months => [from, months] as const)),
    ],
    ([from, months]) => iso(rules.addMonths(date(from as string), months as number)),
  ),
  compareLocalDates: cases(
    'compareLocalDates',
    [
      ['2024-01-01', '2024-01-02'],
      ['2024-01-02', '2024-01-01'],
      ['2024-01-01', '2024-01-01'],
      ...Array.from({ length: 200 }, () => [civilDay(civil), civilDay(civil)]),
    ],
    ([left, right]) => Math.sign(rules.compareLocalDates(date(left as string), date(right as string))),
  ),
  monthIndexOf: cases('monthIndexOf', ['2025-01-01', '2024-12-01', ...civilDays.slice(0, 200)], text => rules.monthIndexOf(date(text))),
  weekdayOf: cases('weekdayOf', ['2024-01-01', '2024-01-04', '2024-01-07', '1970-01-01', '1969-12-29', ...isoDates], text => rules.weekdayOf(date(text))),
  mondayWeekIndexOf: cases(
    'mondayWeekIndexOf',
    [...range(0, 119).map(offset => iso(rules.addDays(date('2024-11-01'), offset))), ...civilDays.slice(0, 200)],
    text => rules.mondayWeekIndexOf(date(text)),
  ),
  startOfMondayWeek: cases(
    'startOfMondayWeek',
    ['2024-01-01', '2024-01-07', '2025-01-01', '2021-01-03', ...range(0, 119).map(offset => iso(rules.addDays(date('2024-11-01'), offset))), ...civilDays.slice(0, 300)],
    text => iso(rules.startOfMondayWeek(date(text))),
  ),
  weeksBetween: cases(
    'weeksBetween',
    [
      ['2024-12-29', '2024-12-30'],
      ['2024-12-30', '2025-01-05'],
      ['2025-01-05', '2025-01-06'],
      ['2024-01-01', '2024-12-30'],
      ['2025-01-06', '2024-12-30'],
      ...Array.from({ length: 300 }, () => [civilDay(civil), civilDay(civil)]),
    ],
    ([from, to]) => rules.weeksBetween(date(from as string), date(to as string)),
  ),
  nthWeekdayOfMonth: cases(
    'nthWeekdayOfMonth',
    [
      [2024, 3, 1, 1],
      [2024, 3, 1, 3],
      [2024, 3, 5, 4],
      [2024, 3, 5, 'last'],
      [2024, 2, 4, 'last'],
      [2023, 2, 4, 'last'],
      [2024, 9, 7, 1],
      [2024, 9, 7, 'last'],
      [2024, 12, 2, 'last'],
      ...range(1, 12).flatMap(month => range(1, 7).flatMap(weekday => [4, 'last'].map(ordinal => [2024, month, weekday, ordinal]))),
      ...Array.from({ length: 800 }, () => [between(civil, 1900, 2100), between(civil, 1, 12), between(civil, 1, 7), pick(civil, [1, 2, 3, 4, 'last'])]),
    ],
    ([year, month, weekday, ordinal]) => iso(rules.nthWeekdayOfMonth(year, month, weekday, ordinal)),
  ),
});

// The reference's epochDayOf goes through Date.UTC, which reads years 0 to 99 as 1900 to 1999; the native civil arithmetic does not.

const exactEpochDay = (year: number, month: number, day: number): number => {
  const shiftedYear = month <= 2 ? year - 1 : year;
  const era = Math.floor(shiftedYear / 400);
  const yearOfEra = shiftedYear - era * 400;
  const dayOfYear = Math.floor((153 * (month > 2 ? month - 3 : month + 9) + 2) / 5) + day - 1;
  const dayOfEra = yearOfEra * 365 + Math.floor(yearOfEra / 4) - Math.floor(yearOfEra / 100) + dayOfYear;
  return era * 146_097 + dayOfEra - 719_468;
};
for (const text of isoDates) {
  const parsed = date(text);
  if (exactEpochDay(parsed.year, parsed.month, parsed.day) !== rules.epochDayOf(parsed)) throw new Error(`exact epoch day model disagrees on ${text}`);
}
const earlyYears = ['0000-01-01', '0000-03-01', '0001-01-01', '0050-06-15', '0099-12-31', '0100-01-01', '0400-02-29', '1000-01-01'];
const divergences = earlyYears.flatMap(text => {
  const parsed = date(text);
  const reference = rules.epochDayOf(parsed) as number;
  const exact = exactEpochDay(parsed.year, parsed.month, parsed.day);
  return reference === exact ? [] : [{ function: 'epochDayOf', input: text, reference, exact, reason: 'Date.UTC reads a year from 0 to 99 as 1900 to 1999' }];
});
writeFileSync(join(outDir, 'divergences.json'), `{\n"count": ${divergences.length},\n"cases": [\n${divergences.map(entry => JSON.stringify(entry)).join(',\n')}\n]\n}\n`);

// Recurrence: the spec's literal rules and windows, the windows its cursor loops visit, then seeded rules.

type Rule = Record<string, Json>;
const NEVER = { kind: 'never' };
const daily = (startDate: string, interval = 1, end: Json = NEVER, exceptions?: string[]): Rule => ({
  frequency: 'daily',
  interval,
  startDate,
  end,
  ...(exceptions ? { exceptions } : {}),
});
const weekly = (startDate: string, daysOfWeek: number[], interval = 1, end: Json = NEVER): Rule => ({ frequency: 'weekly', interval, startDate, end, daysOfWeek });
const monthly = (startDate: string, pattern: Json, interval = 1, end: Json = NEVER): Rule => ({ frequency: 'monthly', interval, startDate, end, pattern });
const yearly = (startDate: string, interval = 1, end: Json = NEVER): Rule => ({ frequency: 'yearly', interval, startDate, end });
const until = (text: string) => ({ kind: 'until', date: text });
const count = (value: number) => ({ kind: 'count', count: value });
const dom = (dayOfMonth: number) => ({ kind: 'day_of_month', dayOfMonth });
const nth = (weekday: number, ordinal: number | 'last') => ({ kind: 'nth_weekday', weekday, ordinal });

const refEnd = (end: Json): unknown => {
  const body = end as Record<string, Json>;
  return body['kind'] === 'until' ? { kind: 'until', date: date(body['date'] as string) } : body;
};
const refRule = (rule: Rule): unknown => ({
  ...rule,
  startDate: date(rule['startDate'] as string),
  end: refEnd(rule['end'] as Json),
  ...(rule['exceptions'] ? { exceptions: (rule['exceptions'] as string[]).map(date) } : {}),
});
interface Cursor {
  date: string;
  index: number;
}
const refCursor = (cursor: Cursor | null | undefined): unknown => (cursor ? { date: date(cursor.date), index: cursor.index } : cursor);
const outOccurrence = (occurrence: { date: RefDate; index: number } | null): Json => (occurrence ? { date: iso(occurrence.date), index: occurrence.index } : null);

interface ExpandInput {
  rule: Rule;
  from: string;
  to: string;
  cursor?: Cursor | null;
}
const expand = (input: ExpandInput) => {
  const expansion = rules.expandRecurrence(refRule(input.rule), { from: date(input.from), to: date(input.to) }, refCursor(input.cursor));
  return { occurrences: expansion.occurrences.map(outOccurrence), cursor: outOccurrence(expansion.cursor) };
};
const span = (rule: Rule, from: string, to: string, cursor?: Cursor | null): ExpandInput => ({ rule, from, to, ...(cursor === undefined ? {} : { cursor }) });

const specExpansions: ExpandInput[] = [
  span(daily('2024-01-01'), '2024-01-01', '2024-01-05'),
  span(daily('2024-01-01', 3), '2024-01-01', '2024-01-10'),
  span(daily('2024-01-01', 3), '2024-01-05', '2024-01-11'),
  span(daily('2024-06-01'), '2024-01-01', '2024-05-31'),
  span(daily('2024-01-01', 0), '2024-01-01', '2024-01-03'),
  span(daily('2024-02-27'), '2024-02-27', '2024-03-01'),
  span(daily('2023-02-27'), '2023-02-27', '2023-03-01'),
  span(weekly('2024-01-01', [3]), '2024-01-01', '2024-01-31'),
  span(weekly('2024-01-01', [5, 1, 3]), '2024-01-01', '2024-01-08'),
  span(weekly('2024-01-01', [1, 1, 3]), '2024-01-01', '2024-01-04'),
  span(weekly('2024-01-04', [1, 4]), '2024-01-01', '2024-01-15'),
  span(weekly('2024-01-04', [1, 4], 2), '2024-01-01', '2024-02-05'),
  span(weekly('2024-01-01', [7]), '2024-01-01', '2024-01-22'),
  span(weekly('2024-12-26', [1, 4], 2), '2024-12-23', '2025-01-31'),
  span(weekly('2024-12-26', [1, 4], 2), '2024-12-30', '2025-01-05'),
  span(weekly('2024-12-29', [7, 1], 2), '2024-12-23', '2025-01-20'),
  span(monthly('2024-01-31', dom(31)), '2024-01-01', '2024-06-30'),
  span(monthly('2023-01-30', dom(30)), '2023-01-01', '2023-04-30'),
  span(monthly('2024-01-15', dom(15), 3), '2024-01-01', '2024-12-31'),
  span(monthly('2024-01-20', dom(5)), '2024-01-01', '2024-03-31'),
  span(monthly('2024-01-01', dom(31), 12), '2024-01-01', '2026-12-31'),
  span(monthly('2024-01-01', nth(2, 2)), '2024-01-01', '2024-04-30'),
  span(monthly('2024-01-01', nth(5, 'last')), '2024-01-01', '2024-04-30'),
  span(monthly('2024-02-01', nth(4, 'last')), '2024-02-01', '2024-02-29'),
  span(monthly('2024-01-01', nth(7, 4), 2), '2024-01-01', '2024-08-31'),
  span(monthly('2024-11-01', nth(1, 1)), '2024-11-01', '2025-02-28'),
  span(yearly('2024-07-04'), '2024-01-01', '2027-12-31'),
  span(yearly('2024-02-29'), '2024-01-01', '2028-12-31'),
  span(yearly('2024-02-29', 4), '2024-01-01', '2036-12-31'),
  span(yearly('2096-02-29', 4), '2096-01-01', '2104-12-31'),
  span(yearly('2024-03-01', 2), '2024-01-01', '2030-12-31'),
  span(daily('2024-01-01'), '2124-01-01', '2124-01-03'),
  span(daily('2024-01-01', 2, count(4)), '2024-01-01', '2024-12-31'),
  span(daily('2024-01-01', 1, count(0)), '2024-01-01', '2024-12-31'),
  span(weekly('2024-01-01', [1, 3, 5], 1, count(5)), '2024-01-01', '2024-12-31'),
  span(daily('2024-01-01', 1, until('2024-01-04')), '2024-01-01', '2024-12-31'),
  span(daily('2024-06-01', 1, until('2024-05-31')), '2024-01-01', '2024-12-31'),
  span(monthly('2024-01-31', dom(31), 1, until('2024-02-29')), '2024-01-01', '2024-12-31'),
  span(daily('2024-01-01', 1, NEVER, ['2024-01-02', '2024-01-04']), '2024-01-01', '2024-01-05'),
  span(daily('2024-01-01', 2, NEVER, ['2024-01-02']), '2024-01-01', '2024-01-05'),
  span(daily('2024-01-01', 1, count(4), ['2024-01-02']), '2024-01-01', '2024-12-31'),
  span(daily('2024-01-01', 1, NEVER, ['2024-01-03']), '2024-01-01', '2024-01-05'),
  span(daily('2024-01-01'), '2024-01-05', '2024-01-01'),
  span(daily('2024-01-01', 2), '2024-01-03', '2024-01-03'),
  span(daily('2024-01-01', 2), '2024-01-04', '2024-01-04'),
  span(daily('2024-01-01'), '2024-01-11', '2024-01-13'),
];

const counted = daily('2024-01-01', 3, count(40), ['2024-01-07', '2024-02-06']);
specExpansions.push(span(counted, '2024-01-01', '2024-01-10'), span(counted, '2024-01-01', '2024-01-08'));

const cursorLoop = (rule: Rule, from: string, to: string, boundaries: string[]): ExpandInput[] => [
  span(rule, from, to),
  ...boundaries.flatMap(boundary => {
    const prefix = expand(span(rule, from, boundary));
    return [span(rule, from, boundary), span(rule, iso(rules.addDays(date(boundary), 1)), to, prefix.cursor as Cursor | null)];
  }),
];
const boundariesFrom = (start: string, count: number, step: number): string[] => range(0, count - 1).map(offset => iso(rules.addDays(date(start), offset * step)));
specExpansions.push(
  ...cursorLoop(counted, '2024-01-01', '2025-01-01', boundariesFrom('2024-01-01', 200, 1)),
  ...cursorLoop(weekly('2024-12-26', [1, 3, 5], 2, count(25)), '2024-12-01', '2026-01-01', boundariesFrom('2024-12-01', 120, 1)),
  ...cursorLoop(monthly('2024-01-31', dom(31), 1, count(30)), '2024-01-01', '2027-01-01', boundariesFrom('2024-01-01', 24, 30)),
);
const rejecting = daily('2024-01-01', 1, count(20));
for (const cursor of [
  { date: '2024-01-06', index: 5 },
  { date: '2023-12-25', index: 0 },
  { date: '2024-01-03', index: -1 },
  { date: '2024-01-05', index: 4 },
]) {
  specExpansions.push(span(rejecting, '2024-01-05', '2024-01-08', cursor));
}
const occursSpecRule = weekly('2024-01-01', [2, 6], 3, count(12));
const occursSpecCursor = expand(span(occursSpecRule, '2024-01-01', '2024-03-01')).cursor as Cursor | null;
specExpansions.push(span(occursSpecRule, '2024-01-01', '2024-03-01'));
const nextSpecRule = monthly('2024-01-15', dom(15), 2, count(18));
const nextSpecCursor = expand(span(nextSpecRule, '2024-01-01', '2024-12-31')).cursor as Cursor | null;
specExpansions.push(span(nextSpecRule, '2024-01-01', '2024-12-31'));

interface PointInput {
  rule: Rule;
  date: string;
  cursor?: Cursor | null;
}
const point = (rule: Rule, text: string, cursor?: Cursor | null): PointInput => ({ rule, date: text, ...(cursor === undefined ? {} : { cursor }) });
const specOccurs: PointInput[] = [
  point(daily('2024-01-01', 5), '2024-01-11'),
  point(daily('2024-01-01', 5), '2024-01-12'),
  point(monthly('2024-01-31', dom(31)), '2024-02-29'),
  point(monthly('2024-01-31', dom(31)), '2024-02-28'),
  point(yearly('2024-02-29'), '2025-02-28'),
  point(daily('2024-01-01', 1, count(3)), '2024-01-04'),
  point(daily('2024-01-01', 1, until('2024-01-03')), '2024-01-04'),
  point(daily('2024-01-01', 1, NEVER, ['2024-01-03']), '2024-01-03'),
  point(daily('2024-06-01'), '2024-05-31'),
  ...boundariesFrom('2024-03-02', 200, 1).flatMap(text => [point(occursSpecRule, text, occursSpecCursor), point(occursSpecRule, text)]),
];
const specNext: PointInput[] = [
  point(daily('2024-01-01', 4), '2024-01-05'),
  point(daily('2024-01-01', 4), '2024-01-06'),
  point(daily('2024-06-01'), '2024-01-01'),
  point(daily('2024-01-01', 1, NEVER, ['2024-01-05']), '2024-01-05'),
  point(daily('2024-01-01', 1, count(3)), '2024-01-04'),
  point(daily('2024-01-01', 1, until('2024-01-03')), '2024-01-04'),
  point(monthly('2024-01-01', nth(5, 'last')), '2024-01-27'),
  point(yearly('2024-02-29'), '2024-03-01'),
  point(daily('2024-01-01', 2), '2024-01-06'),
  point(nextSpecRule, '2025-02-01', nextSpecCursor),
  point(nextSpecRule, '2025-02-01'),
];

const seeded = lcg(0x0bad_cafe);
const seededStart = (): string => {
  const roll = seeded();
  if (roll < 0.15) return pick(seeded, ['2024-02-29', '2000-02-29', '2096-02-29', '2024-01-31', '2023-01-30', '2024-12-29', '2099-12-31']);
  return civilDay(seeded, EPOCH_1900, EPOCH_2100 - 800);
};
const seededRule = (): Rule => {
  const startDate = seededStart();
  const interval = seeded() < 0.08 ? pick(seeded, [0, -1, -3]) : between(seeded, 1, 4);
  const endRoll = seeded();
  const end =
    endRoll < 0.4 ? NEVER : endRoll < 0.75 ? count(seeded() < 0.1 ? pick(seeded, [-2, 0]) : between(seeded, 1, 40)) : until(iso(rules.addDays(date(startDate), between(seeded, -20, 700))));
  const exceptions = seeded() < 0.4 ? range(1, between(seeded, 1, 4)).map(() => iso(rules.addDays(date(startDate), between(seeded, -3, 120)))) : undefined;
  const base = { interval, startDate, end, ...(exceptions ? { exceptions } : {}) };
  switch (pick(seeded, ['daily', 'weekly', 'monthly', 'yearly'] as const)) {
    case 'daily':
      return { frequency: 'daily', ...base };
    case 'weekly':
      return { frequency: 'weekly', ...base, daysOfWeek: range(1, between(seeded, 1, 5)).map(() => between(seeded, 1, 7)) };
    case 'monthly':
      return {
        frequency: 'monthly',
        ...base,
        pattern: seeded() < 0.6 ? dom(seeded() < 0.3 ? pick(seeded, [28, 29, 30, 31, 35]) : between(seeded, 1, 31)) : nth(between(seeded, 1, 7), pick(seeded, [1, 2, 3, 4, 'last'])),
      };
    default:
      return { frequency: 'yearly', ...base };
  }
};
const seededExpansions: ExpandInput[] = [];
const seededOccurs: PointInput[] = [];
const seededNext: PointInput[] = [];
for (let run = 0; run < 700; run++) {
  const rule = seededRule();
  const start = date(rule['startDate'] as string);
  const from = iso(rules.addDays(start, between(seeded, -40, 500)));
  const to = iso(rules.addDays(date(from), between(seeded, -2, 400)));
  seededExpansions.push(span(rule, from, to));
  const boundary = iso(rules.addDays(date(from), between(seeded, 0, 300)));
  const prefix = expand(span(rule, from, boundary));
  seededExpansions.push(span(rule, iso(rules.addDays(date(boundary), 1)), to, prefix.cursor as Cursor | null));
  const fabricated = { date: iso(rules.addDays(start, between(seeded, -5, 200))), index: between(seeded, -1, 30) };
  seededExpansions.push(span(rule, from, to, fabricated));
  const probe = iso(rules.addDays(start, between(seeded, -10, 600)));
  seededOccurs.push(point(rule, probe), point(rule, probe, prefix.cursor as Cursor | null));
  seededNext.push(point(rule, probe), point(rule, probe, prefix.cursor as Cursor | null), point(rule, probe, fabricated));
}

const occursOn = (input: PointInput): boolean => rules.occursOn(refRule(input.rule), date(input.date), refCursor(input.cursor));
const nextOccurrence = (input: PointInput): Json => outOccurrence(rules.nextOccurrenceOnOrAfter(refRule(input.rule), date(input.date), refCursor(input.cursor)));

fixture('recurrence.json', {
  expandRecurrence: [...cases('spec', specExpansions, expand), ...cases('seeded', seededExpansions, expand)],
  occursOn: [...cases('spec', specOccurs, occursOn), ...cases('seeded', seededOccurs, occursOn)],
  nextOccurrenceOnOrAfter: [...cases('spec', specNext, nextOccurrence), ...cases('seeded', seededNext, nextOccurrence)],
});

// Subscription cycles: the spec literals, then every frequency and billing day over seeded due dates.

interface CycleInput {
  frequency: string;
  billingDay: number;
  customIntervalDays: number | null;
  from: string;
}
const cycle = (frequency: string, billingDay: number, customIntervalDays: number | null, from: string): CycleInput => ({ frequency, billingDay, customIntervalDays, from });
const cycles = lcg(0x5ab5);
const cycleGrid: CycleInput[] = [];
for (const frequency of ['weekly', 'monthly', 'quarterly', 'yearly', 'custom']) {
  for (const billingDay of range(1, 31)) {
    for (let draw = 0; draw < 6; draw++) {
      const from = draw === 0 ? pick(cycles, ['2024-01-31', '2024-02-29', '2023-02-28', '2024-11-30', '2099-12-31']) : civilDay(cycles, EPOCH_1900, EPOCH_2100 - 400);
      const customIntervalDays = frequency === 'custom' ? pick(cycles, [null, 1, 7, 10, 45, 365, 0, -3]) : null;
      cycleGrid.push(cycle(frequency, billingDay, customIntervalDays, from));
    }
  }
}
const advance = (input: CycleInput): string =>
  advanceDueDate({ frequency: input.frequency, billingDay: input.billingDay, customIntervalDays: input.customIntervalDays }, input.from);
fixture('subscription.json', {
  advanceDueDate: [
    ...cases(
      'spec',
      [
        cycle('weekly', 1, null, '2026-08-10'),
        cycle('monthly', 31, null, '2026-01-31'),
        cycle('monthly', 31, null, '2026-02-28'),
        cycle('quarterly', 31, null, '2025-11-30'),
        cycle('yearly', 29, null, '2024-02-29'),
        cycle('custom', 1, 10, '2026-08-10'),
        cycle('custom', 1, null, '2026-08-10'),
      ],
      advance,
    ),
    ...cases('grid', cycleGrid, advance),
  ],
});

// Zone-dependent cases: the spec literals, then a fixed list of zones over 2015 to 2030, so Node ICU and Apple tz data share their rules.

const NEW_YORK = 'America/New_York';
const BERLIN = 'Europe/Berlin';
const LORD_HOWE = 'Australia/Lord_Howe';
const KOLKATA = 'Asia/Kolkata';
const ZONES = [
  'UTC',
  NEW_YORK,
  'America/Los_Angeles',
  'America/St_Johns',
  'America/Santiago',
  'America/Havana',
  'America/Sao_Paulo',
  BERLIN,
  'Europe/London',
  'Europe/Dublin',
  KOLKATA,
  'Asia/Kathmandu',
  'Asia/Tehran',
  LORD_HOWE,
  'Australia/Adelaide',
  'Pacific/Chatham',
  'Pacific/Kiritimati',
  'Pacific/Apia',
  'Africa/Casablanca',
  'America/Asuncion',
];
const ZONE_FROM = Date.UTC(2015, 0, 1);
const ZONE_TO = Date.UTC(2030, 11, 31);
const MINUTE = 60_000;
const HOUR = 3_600_000;
const DAY = 86_400_000;

const zonedFields = (instant: number, zone: string): Json => {
  const fields = rules.zonedFieldsAt(instant, zone);
  return { date: iso(fields.date), minuteOfDay: fields.minuteOfDay, second: fields.second };
};
const transitionsOf = (zone: string): number[] => {
  const found: number[] = [];
  let previous = rules.offsetMinutesAt(ZONE_FROM, zone);
  for (let instant = ZONE_FROM + 6 * HOUR; instant <= ZONE_TO; instant += 6 * HOUR) {
    const offset = rules.offsetMinutesAt(instant, zone);
    if (offset !== previous) {
      let low = instant - 6 * HOUR;
      let high = instant;
      while (high - low > 1) {
        const middle = Math.floor((low + high) / 2);
        if (rules.offsetMinutesAt(middle, zone) === previous) low = middle;
        else high = middle;
      }
      found.push(high);
    }
    previous = offset;
  }
  return found;
};

interface FieldsInput {
  zone: string;
  instant: number;
}
interface MinuteInput {
  zone: string;
  date: string;
  minuteOfDay: number;
}
interface DayInput {
  zone: string;
  date: string;
}
const fieldsInputs: FieldsInput[] = [];
const minuteInputs: MinuteInput[] = [];
const dayInputs: DayInput[] = [];
const addFields = (zone: string, instant: number) => fieldsInputs.push({ zone, instant });
const addMinute = (zone: string, text: string, minuteOfDay: number) => minuteInputs.push({ zone, date: text, minuteOfDay });
const addDay = (zone: string, text: string) => dayInputs.push({ zone, date: text });

const minutes = (hour: number, minute = 0): number => hour * 60 + minute;
for (const [zone, instant] of [
  [NEW_YORK, Date.UTC(2024, 0, 1, 0, 0)],
  [BERLIN, Date.UTC(2024, 0, 1, 0, 0)],
  [KOLKATA, Date.UTC(2024, 0, 1, 0, 0)],
  [LORD_HOWE, Date.UTC(2024, 5, 1, 0, 0)],
  [NEW_YORK, Date.UTC(2024, 6, 2, 3, 59)],
  [NEW_YORK, Date.UTC(2024, 0, 15)],
  [NEW_YORK, Date.UTC(2024, 6, 15)],
  [BERLIN, Date.UTC(2024, 0, 15)],
  [BERLIN, Date.UTC(2024, 6, 15)],
  [LORD_HOWE, Date.UTC(2024, 5, 15)],
  [LORD_HOWE, Date.UTC(2024, 11, 15)],
  [KOLKATA, Date.UTC(2024, 5, 15)],
] as const) {
  addFields(zone, instant);
}
for (const [zone, text] of [
  [NEW_YORK, '2024-03-09'],
  [NEW_YORK, '2024-03-10'],
  [NEW_YORK, '2024-03-11'],
  [NEW_YORK, '2024-11-03'],
  [BERLIN, '2024-03-31'],
  [BERLIN, '2024-10-27'],
  [BERLIN, '2024-06-01'],
  [LORD_HOWE, '2024-10-06'],
  [LORD_HOWE, '2024-04-07'],
  [LORD_HOWE, '2024-06-01'],
  [KOLKATA, '2024-03-10'],
  [KOLKATA, '2024-11-03'],
] as const) {
  addDay(zone, text);
}
for (const zone of [NEW_YORK, BERLIN, LORD_HOWE, KOLKATA]) {
  for (let offset = 0; offset < 400; offset += 7) {
    const day = iso(rules.addDays(date('2024-01-01'), offset));
    addDay(zone, day);
    addFields(zone, rules.startOfLocalDay(date(day), zone) - 1);
  }
}
for (const [zone, text, minuteOfDay] of [
  [NEW_YORK, '2024-03-10', minutes(1, 30)],
  [NEW_YORK, '2024-03-10', minutes(2)],
  [NEW_YORK, '2024-03-10', minutes(2, 30)],
  [NEW_YORK, '2024-03-10', minutes(3)],
  [NEW_YORK, '2024-11-03', minutes(1, 30)],
  [BERLIN, '2024-03-31', minutes(2, 30)],
  [BERLIN, '2024-10-27', minutes(2, 30)],
  [LORD_HOWE, '2024-10-06', minutes(2, 15)],
  [LORD_HOWE, '2024-04-07', minutes(1, 45)],
  [KOLKATA, '2024-03-10', minutes(2, 30)],
  ['America/Santiago', '2024-09-08', 0],
] as const) {
  addMinute(zone, text, minuteOfDay);
}
for (const [zone, text] of [
  [NEW_YORK, '2024-03-10'],
  [NEW_YORK, '2024-11-03'],
  [BERLIN, '2024-03-31'],
  [LORD_HOWE, '2024-10-06'],
] as const) {
  for (let minuteOfDay = 0; minuteOfDay < 1440; minuteOfDay++) addMinute(zone, text, minuteOfDay);
}
const foldInstant = rules.instantAtLocalMinute(date('2024-11-03'), minutes(1, 30), NEW_YORK).instant as number;
addFields(NEW_YORK, foldInstant);
addFields(NEW_YORK, foldInstant + HOUR);
addFields(NEW_YORK, (rules.instantAtLocalMinute(date('2024-03-10'), minutes(2, 30), NEW_YORK).instant as number) - 1);

const zoned = lcg(0x7a0e);
const transitionCounts: Record<string, number> = {};
for (const zone of ZONES) {
  const transitions = transitionsOf(zone);
  transitionCounts[zone] = transitions.length;
  for (let draw = 0; draw < 60; draw++) addFields(zone, between(zoned, ZONE_FROM / 1000, ZONE_TO / 1000) * 1000 + between(zoned, 0, 999));
  for (let draw = 0; draw < 12; draw++) addDay(zone, civilDay(zoned, rules.epochDayOf(date('2015-01-02')), rules.epochDayOf(date('2030-12-30'))));
  for (const transition of transitions) {
    for (const delta of [-HOUR, -1000, -1, 0, 1, 999, 1000, HOUR]) addFields(zone, transition + delta);
    const before = rules.zonedFieldsAt(transition - 1000, zone);
    const after = rules.zonedFieldsAt(transition, zone);
    const days = [...new Set([iso(before.date), iso(after.date)])];
    const walls = [before.minuteOfDay + 1, after.minuteOfDay];
    const [low, high] = [Math.min(...walls), Math.max(...walls)];
    const interesting = [low - 30, low - 1, low, low + 1, Math.floor((low + high) / 2), high - 1, high, high + 1, high + 30, ...range(1, 4).map(() => between(zoned, 0, 1439))];
    for (const day of days) {
      addDay(zone, day);
      for (const minuteOfDay of new Set(interesting.filter(minute => minute >= 0 && minute < 1440))) addMinute(zone, day, minuteOfDay);
    }
    addDay(zone, iso(rules.addDays(date(days[0] as string), -1)));
  }
}

const dedupe = <T>(inputs: T[], key: (input: T) => string): T[] => [...new Map(inputs.map(input => [key(input), input])).values()];
const fieldsKey = (input: FieldsInput) => `${input.zone}@${input.instant}`;
const minuteKey = (input: MinuteInput) => `${input.zone}@${input.date}+${input.minuteOfDay}`;
const dayKey = (input: DayInput) => `${input.zone}@${input.date}`;
const fieldsCases = dedupe(fieldsInputs, fieldsKey);
const minuteCases = dedupe(minuteInputs, minuteKey);
const dayCases = dedupe(dayInputs, dayKey);

interface ClampInput {
  zone: string;
  performedAt: number;
  serverNow: number;
  lastAckedSyncAt: number | null;
  occurrenceDate: string;
}
const occurrenceDate = '2024-06-10';
const dayStart = rules.startOfLocalDay(date(occurrenceDate), NEW_YORK) as number;
const serverNow = dayStart + minutes(20) * MINUTE;
const clampInputs: ClampInput[] = [
  ...(
    [
      [dayStart + minutes(9) * MINUTE, null],
      [dayStart - MINUTE, null],
      [dayStart + minutes(1) * MINUTE, dayStart + minutes(8) * MINUTE],
      [serverNow + MINUTE, null],
      [dayStart + MINUTE, dayStart - minutes(600) * MINUTE],
      [dayStart + minutes(30) * MINUTE, serverNow + minutes(60) * MINUTE],
      [dayStart, null],
      [serverNow, null],
      [dayStart - DAY, null],
      [serverNow + DAY, null],
      [0, null],
    ] as const
  ).map(([performedAt, lastAckedSyncAt]) => ({ zone: NEW_YORK, performedAt, serverNow, lastAckedSyncAt, occurrenceDate })),
];
const laterDay = (rules.startOfLocalDay(date('2024-06-12'), NEW_YORK) as number) + minutes(7, 15) * MINUTE;
clampInputs.push({ zone: NEW_YORK, performedAt: laterDay, serverNow: laterDay, lastAckedSyncAt: null, occurrenceDate });
clampInputs.push({ zone: BERLIN, performedAt: (rules.startOfLocalDay(date(occurrenceDate), BERLIN) as number) - MINUTE, serverNow, lastAckedSyncAt: null, occurrenceDate });
for (const zone of ZONES) {
  for (let draw = 0; draw < 25; draw++) {
    const day = civilDay(zoned, rules.epochDayOf(date('2015-01-02')), rules.epochDayOf(date('2030-12-28')));
    const start = rules.startOfLocalDay(date(day), zone) as number;
    const now = start + between(zoned, -6 * 60, 3 * 24 * 60) * MINUTE + between(zoned, 0, 59_999);
    const performedAt = now + between(zoned, -4 * 24 * 60, 120) * MINUTE + between(zoned, 0, 999);
    const lastAckedSyncAt = zoned() < 0.5 ? null : start + between(zoned, -24 * 60, 2 * 24 * 60) * MINUTE;
    clampInputs.push({ zone, performedAt, serverNow: now, lastAckedSyncAt, occurrenceDate: day });
  }
}
const clamp = (input: ClampInput): Json => {
  const clamped = rules.clampPerformedAt({ ...input, timeZone: input.zone, occurrenceDate: date(input.occurrenceDate) });
  return { instant: clamped.instant, date: iso(clamped.date), minuteOfDay: clamped.minuteOfDay, daysElapsed: clamped.daysElapsed, outcome: clamped.outcome };
};

interface TodayInput {
  zone: string;
  instant: number;
  lastHpDate: string | null;
}
const NOW = Date.parse('2026-03-10T11:00:00Z');
const todayInputs: TodayInput[] = [
  { zone: 'Pacific/Kiritimati', instant: NOW, lastHpDate: '2026-03-10' },
  { zone: 'America/Los_Angeles', instant: NOW, lastHpDate: null },
  { zone: 'UTC', instant: NOW, lastHpDate: '2026-03-11' },
];
for (const zone of ZONES) {
  for (let draw = 0; draw < 10; draw++) {
    const instant = between(zoned, ZONE_FROM / 1000, ZONE_TO / 1000) * 1000;
    const zoneDay = rules.localDateAt(instant, zone);
    const lastHpDate = zoned() < 0.25 ? null : iso(rules.addDays(zoneDay, between(zoned, -2, 2)));
    todayInputs.push({ zone, instant, lastHpDate });
  }
}

fixture('zones.json', {
  zonedFieldsAt: cases('zonedFieldsAt', fieldsCases, input => zonedFields(input.instant, input.zone), fieldsKey),
  offsetMinutesAt: cases('offsetMinutesAt', fieldsCases, input => rules.offsetMinutesAt(input.instant, input.zone), fieldsKey),
  instantAtLocalMinute: cases(
    'instantAtLocalMinute',
    minuteCases,
    input => {
      const resolved = rules.instantAtLocalMinute(date(input.date), input.minuteOfDay, input.zone);
      return { instant: resolved.instant, date: iso(resolved.date), minuteOfDay: resolved.minuteOfDay, resolution: resolved.resolution };
    },
    minuteKey,
  ),
  startOfLocalDay: cases('startOfLocalDay', dayCases, input => rules.startOfLocalDay(date(input.date), input.zone), dayKey),
  localDayLengthMinutes: cases('localDayLengthMinutes', dayCases, input => rules.localDayLengthMinutes(date(input.date), input.zone), dayKey),
  clampPerformedAt: cases('clampPerformedAt', clampInputs, clamp),
  accountToday: cases('accountToday', todayInputs, input => iso(rules.accountToday(input.instant, input.zone, input.lastHpDate))),
});

const icu = (process.versions as Record<string, string | undefined>)['icu'] ?? 'unknown';
console.log(`ICU ${icu}; transitions in 2015-2030: ${JSON.stringify(transitionCounts)}`);
console.log(`divergences: ${divergences.length}; zone cases: ${fieldsCases.length} fields, ${minuteCases.length} minutes, ${dayCases.length} days, ${clampInputs.length} clamps`);
