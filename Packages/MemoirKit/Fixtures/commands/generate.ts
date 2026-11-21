import { mock } from 'bun:test';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');
const outDir = dirname(fileURLToPath(import.meta.url));
const src = join(platformRepo, 'apps/memoir-server/src');

/** The handlers read the wall clock for "today"; pinning it keeps the verdicts deterministic. */
const FIXED_NOW = Date.UTC(2026, 10, 20, 12, 0, 0);
const TODAY = '2026-11-20';
Date.now = () => FIXED_NOW;

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
type JsonObject = { [key: string]: Json };
type Verdict = { accepted: true } | { refused: { field?: string; code?: string } } | { crashed: string };

class ValidationError extends Error {
  fields: { field: string; msg: string }[] = [];
  constructor(field?: string, msg?: string) {
    super(msg ?? 'validation');
    if (field && msg) this.fields.push({ field, msg });
  }
  addFieldError(field: string, msg: string): ValidationError {
    this.fields.push({ field, msg });
    return this;
  }
}
class AppError extends Error {
  static internal(message: string): AppError {
    return new AppError(message);
  }
  static is(error: unknown): boolean {
    return error instanceof AppError;
  }
}
class CodedError extends Error {
  constructor(readonly code: string) {
    super(code);
  }
}
/** Thrown by every store call the stubs do not answer: validation has passed by the time a handler reaches the store. */
class Reached extends Error {}

const codes = new Proxy({} as Record<string, unknown>, {
  get: (_, code) => ({
    create: () => new CodedError(String(code)),
    throw: () => {
      throw new CodedError(String(code));
    },
  }),
});
const anything: unknown = new Proxy(() => anything, { get: () => anything, apply: () => anything });
const currencyCodes = JSON.parse(
  (/export const CURRENCY_CODES = (\[[^\]]*\])/.exec(readFileSync(join(src, 'classes/enum.dto.ts'), 'utf8'))?.[1] ?? 'null').replaceAll("'", '"'),
) as string[] | null;
if (!currencyCodes) throw new Error('CURRENCY_CODES not found in classes/enum.dto.ts');

/** A package is mocked under its bare name and under the path it resolves to from the reference, which is what the reference's files import. */
const mockPackage = (name: string, exports: Record<string, unknown>): void => {
  mock.module(name, () => exports);
  try {
    mock.module(Bun.resolveSync(name, join(src, 'modules')), () => exports);
  } catch {
    return;
  }
};
mockPackage('drizzle-orm', { eq: (...a: unknown[]) => ({ eq: a }), and: (...a: unknown[]) => ({ and: a }), inArray: (_: unknown, values: unknown[]) => ({ inArray: values }) });
mockPackage('@shadow-library/app', { Injectable: () => () => undefined });
mockPackage('@shadow-library/common', { AppError, ValidationError, Config: { get: () => 0 }, Logger: { getLogger: () => ({}) } });
mockPackage('@shadow-library/modules', { DatabaseService: class {} });
const rules = await import(join(src, 'modules/rules/index.ts'));
mock.module('@modules/rules', () => rules);
mock.module('@modules/commands', () => ({ CommandBus: class {}, HeroLedger: class {}, applyStreakTransition: async () => undefined }));
mock.module('@modules/progression', () => ({ ProgressionService: class {}, HeroStandingService: class {} }));
mock.module('@modules/rollover', () => ({ RolloverRepository: class {}, RolloverService: class {} }));
mock.module('@modules/sync', () => ({ DeltaRepository: class {}, DeltaSourceRegistry: class {}, serializeDeltaRow: (row: unknown) => row }));
mock.module('@modules/receipts', () => ({ ReceiptService: class {} }));
mock.module('@modules/auth', () => ({ AccountContext: class {}, AccountRepository: class {} }));
mock.module('@server/classes', () => ({ AppErrorCode: codes, CURRENCY_CODES: currencyCodes }));
mock.module('@server/database', () => ({ schema: anything }));
mock.module('@server/telemetry', () => ({ pseudoAccountId: () => 'stub', TelemetryService: class {} }));
const stubModules: Record<string, Record<string, unknown>> = {
  'modules/commands/command-log.repository.ts': { CommandLogRepository: class {} },
  'modules/commands/rollover-gate.ts': { RolloverGate: class {} },
  'modules/quests/quest-log.repository.ts': { QuestLogRepository: class {} },
  'modules/quests/quest.repository.ts': { QuestRepository: class {} },
  'modules/quests/quest-streak.repository.ts': { QuestStreakRepository: class {} },
  'modules/metrics/metric-entry.repository.ts': { MetricEntryRepository: class {} },
  'modules/metrics/metric.repository.ts': { MetricRepository: class {} },
  'modules/metrics/threshold-offer.ts': { findThresholdOffers: () => [], serializeOffer: () => ({}) },
  'modules/finance/expense-audit.repository.ts': { ExpenseAuditRepository: class {} },
  'modules/finance/expense-category.repository.ts': { ExpenseCategoryRepository: class {} },
  'modules/finance/expense.repository.ts': { ExpenseRepository: class {} },
  'modules/finance/fx-rate.repository.ts': { FxRateRepository: class {} },
  'modules/finance/subscription-cycle.ts': { advanceDueDate: () => null },
  'modules/finance/subscription.repository.ts': { SubscriptionRepository: class {} },
  'modules/progression/grants.repository.ts': { GrantsRepository: class {} },
  'modules/progression/progress-counters.repository.ts': { ProgressCountersRepository: class {} },
  'modules/quick-logs/entry-cap.ts': { deriveCapAdvisory: () => ({}), serializeCapAdvisory: () => ({}) },
  'modules/quick-logs/journal.repository.ts': { JournalRepository: class {} },
  'modules/quick-logs/meal.repository.ts': { MealRepository: class {} },
  'modules/quick-logs/meal-preset.repository.ts': { MealPresetRepository: class {} },
  'modules/quick-logs/quest-linkage.ts': { findLinkageMatch: () => null, serializeLinkageMatch: () => ({}) },
  'modules/quick-logs/side-quest.repository.ts': { SideQuestRepository: class {} },
  'modules/quick-logs/weight.repository.ts': { WeightRepository: class {} },
  'modules/account/account.dto.ts': {},
};
for (const [path, exports] of Object.entries(stubModules)) mock.module(join(src, path), () => exports);

const { CommandBus } = await import(join(src, 'modules/commands/command-bus.service.ts'));
const { QuestCommandsService } = await import(join(src, 'modules/quests/quest-commands.service.ts'));
const { CompassionCommandsService } = await import(join(src, 'modules/quests/compassion-commands.service.ts'));
const { MetricsCommandsService } = await import(join(src, 'modules/metrics/metrics-commands.service.ts'));
const { FinanceCommandsService } = await import(join(src, 'modules/finance/finance-commands.service.ts'));
const { ProgressionCommandsService } = await import(join(src, 'modules/progression/progression-commands.service.ts'));
const { QuickLogsCommandsService } = await import(join(src, 'modules/quick-logs/quick-logs-commands.service.ts'));
const { AccountService } = await import(join(src, 'modules/account/account.service.ts'));

/** Answers the store reads a handler makes before it has finished validating; every other call rejects with `Reached`. */
type World = Record<string, unknown>;
const handlers = new Map<string, (context: unknown) => Promise<unknown>>();
const dependency = (world: World): unknown =>
  new Proxy(
    {},
    {
      get: (_, name) => {
        if (name === 'registerHandler') return (type: string, handler: (context: unknown) => Promise<unknown>) => handlers.set(type, handler);
        if (name === 'register') return () => undefined;
        return (...args: unknown[]) => {
          if (typeof name === 'string' && name in world) {
            const value = world[name];
            return typeof value === 'function' ? value(...args) : Promise.resolve(value);
          }
          return Promise.reject(new Reached(String(name)));
        };
      },
    },
  );
const transaction = (world: World): unknown => {
  const select = () => {
    let where: unknown;
    const chain: Record<string, unknown> = {
      from: () => chain,
      for: () => chain,
      where: (condition: unknown) => {
        where = condition;
        return chain;
      },
      then: (resolve: (rows: unknown) => void, reject: (error: unknown) => void) => {
        const rows = world['select'];
        if (typeof rows === 'function') resolve(rows(where));
        else if (rows !== undefined) resolve(rows);
        else reject(new Reached('select'));
      },
    };
    return chain;
  };
  const write = () => {
    throw new Reached('write');
  };
  return { select, insert: write, update: write, delete: write };
};
const distinctInArray = (where: unknown): unknown[] => {
  const ids = new Set<unknown>();
  const visit = (node: unknown): void => {
    if (!node || typeof node !== 'object') return;
    const record = node as Record<string, unknown>;
    if (Array.isArray(record['inArray'])) for (const id of record['inArray']) ids.add(id);
    for (const value of Object.values(record)) if (Array.isArray(value)) value.forEach(visit);
  };
  visit(where);
  return [...ids].map(id => ({ id }));
};

const SERVICES = [QuestCommandsService, CompassionCommandsService, MetricsCommandsService, FinanceCommandsService, ProgressionCommandsService, QuickLogsCommandsService];
const register = (world: World): void => {
  handlers.clear();
  for (const Service of SERVICES) {
    const service = new Service(...Array.from({ length: 12 }, () => dependency(world)));
    service.onModuleInit();
  }
};

const verdictOf = async (run: () => Promise<unknown>, stripPrefix = ''): Promise<Verdict> => {
  try {
    await run();
    return { accepted: true };
  } catch (error) {
    if (error instanceof Reached) return { accepted: true };
    if (error instanceof ValidationError) {
      const field = error.fields[0]?.field ?? '';
      return { refused: { field: field.startsWith(stripPrefix) ? field.slice(stripPrefix.length) : field } };
    }
    if (error instanceof CodedError) return { refused: { code: error.code } };
    return { crashed: (error as Error).constructor.name };
  }
};

const Q1 = '0190f3a0-0000-7000-8000-0000000000a1';
const Q2 = '0190f3a0-0000-7000-8000-0000000000a2';
const M1 = '0190f3a0-0000-7000-8000-0000000000b1';
const E1 = '0190f3a0-0000-7000-8000-0000000000c1';
const S1 = '0190f3a0-0000-7000-8000-0000000000d1';
const P1 = '0190f3a0-0000-7000-8000-0000000000e1';
const J1 = '0190f3a0-0000-7000-8000-0000000000f1';
const R1 = '0190f3a0-0000-7000-8000-0000000000f2';
/** The reference's quest, metric, subscription and preset ids are bigints written as digit strings. */
const NUMERIC_IDS: Record<string, string> = { [Q1]: '101', [Q2]: '102', [M1]: '201', [S1]: '301', [P1]: '401' };
const num = (value: Json | undefined): Json | undefined => (typeof value === 'string' && NUMERIC_IDS[value] ? NUMERIC_IDS[value] : value);
const OCC = { quest: Q1, date: '2026-11-19' };
const NOTE = 'Felt tired after work';
const REFLECTION = 'Rested and ready again';

const isObject = (value: Json | undefined): value is JsonObject => typeof value === 'object' && value !== null && !Array.isArray(value);
const without = (object: JsonObject, ...keys: string[]): JsonObject => Object.fromEntries(Object.entries(object).filter(([key]) => !keys.includes(key)));
const texts = (object: JsonObject): JsonObject => ({
  ...object,
  ...(object['note'] === true ? { note: NOTE } : {}),
  ...(object['reflectionText'] === true ? { reflectionText: REFLECTION } : {}),
});
const draftWith = (payload: JsonObject, defaults: JsonObject, content: JsonObject): JsonObject =>
  isObject(payload['draft']) ? { ...payload, draft: { ...defaults, ...payload['draft'], ...content } } : payload;

/** The native payload as the reference's wire payload: digit-string ids, the occurrence as `occurrenceId`, texts and content put back. */
const toReference = (type: string, payload: JsonObject, content: JsonObject, occurrence: typeof OCC | undefined): JsonObject => {
  const occurrenceId = occurrence ? { occurrenceId: `${num(occurrence.quest)}:${occurrence.date}` } : {};
  switch (type) {
    case 'quest.create':
      return { name: 'Morning run', ...without(payload, 'questId'), ...content };
    case 'quest.update': {
      const patch = payload['patch'];
      const merged = patch === undefined && Object.keys(content).length === 0 ? {} : { patch: isObject(patch) || patch === undefined ? { ...(patch ?? {}), ...content } : patch };
      return { ...payload, questId: num(payload['questId']) ?? null, ...merged };
    }
    case 'quest.delete':
      return { ...payload, questId: num(payload['questId']) ?? null };
    case 'recovery.complete':
      return { ...texts(payload), ...content };
    case 'plan.setLock':
      return Array.isArray(payload['questIds']) ? { ...payload, questIds: payload['questIds'].map(id => num(id) ?? null) } : payload;
    case 'metric.create':
      return { name: 'Steps', valueType: 'count', direction: 'higher', ...without(payload, 'id', 'metricClass'), ...content };
    case 'metric.update':
    case 'metric.delete':
      return { ...without(payload, 'metricClass'), id: num(payload['id']) ?? null, ...content };
    case 'metric.register':
      return {
        ...without(payload, 'metricClass'),
        metricId: num(payload['metricId']) ?? null,
        value: 72,
        ...(occurrence ? { questLogId: num(occurrence.quest) ?? null } : {}),
        ...content,
      };
    case 'expense.create':
      return { currency: 'EUR', occurredOn: TODAY, categoryId: 'food', amountText: '12.50', amountMinor: 1250, ...content, ...payload };
    case 'subscription.create':
      return {
        name: 'Music',
        amountMinor: 999,
        amountText: '9.99',
        currency: 'EUR',
        frequency: 'monthly',
        billingDay: 5,
        nextDueDate: '2026-12-05',
        categoryId: 'subs',
        ...content,
        ...without(payload, 'id'),
      };
    case 'subscription.update':
    case 'subscription.delete':
    case 'subscription.confirmCycle':
    case 'meal.preset.delete':
      return { ...payload, id: num(payload['id']) ?? null };
    case 'meal.preset.update':
      return { ...payload, id: num(payload['id']) ?? null, patch: content };
    case 'journal.save':
      return draftWith(payload, { text: 'A good day' }, content);
    case 'meal.log':
      return draftWith(payload, { name: 'Oats', calories: 300, mealType: 'cooked' }, content);
    case 'meal.logPreset':
      return { ...payload, presetId: num(payload['presetId']) ?? null };
    case 'meal.savePreset':
      return { ...without(payload, 'id'), preset: { name: 'Oats', calories: 300, mealType: 'cooked', ...content } };
    case 'weight.save':
      return { kg: 72.5, ...Object.fromEntries(Object.entries(content).map(([key, value]) => [key, key === 'kg' ? Number(value) : value])), ...payload };
    case 'sidequest.log':
      return draftWith(payload, { name: 'Helped a neighbour' }, content);
    default:
      return { ...texts(payload), ...occurrenceId, ...content };
  }
};

const QUEST_ROW = {
  id: 101n,
  active: true,
  strictness: 'routine',
  startTimeMin: 480,
  durationMin: 30,
  statAffinity: 'body',
  optionalStreakOptIn: false,
  recurrence: { frequency: 'daily', interval: 1, startDate: rules.parseLocalDate('2026-01-01'), end: { kind: 'never' }, exceptions: [] },
};
const WORLD: World = {
  findByIdForUpdate: QUEST_ROW,
  lockAccount: { timezone: 'UTC', lastHpDate: null },
  lockDailyState: { rolloverAt: null, committedAt: null, lockBrokenAt: null, momentumBucket: 'steady', lockedQuestIds: [] },
  findByIdInTx: { id: 401n, builtin: false, isHealth: false, currency: 'EUR', fxRate: null, name: 'Oats', calories: 300, mealType: 'cooked', note: null },
  findById: { id: 301n, frequency: 'monthly', customIntervalDays: null, amountMinor: 999n },
  listEarnedTitleIds: rules.TITLES.map((title: { id: string }) => title.id),
  getAccountId: () => 1n,
};
/** The reference has only its built-in categories; read from its repository so the stub finds exactly those. */
const builtInCategories = [...readFileSync(join(src, 'modules/finance/expense-category.repository.ts'), 'utf8').matchAll(/\{ key: '(\w+)', label: /g)].map(match => match[1]);
if (builtInCategories.length === 0) throw new Error('no built-in categories in expense-category.repository.ts');
const TYPE_WORLD: Record<string, World> = {
  'plan.setLock': { select: distinctInArray },
  'metric.delete': { select: [] },
  'category.setArchived': {
    ensureSeeded: () => Promise.resolve(),
    setArchivedInTx: (_: unknown, key: string) => (builtInCategories.includes(key) ? Promise.reject(new Reached('setArchivedInTx')) : Promise.resolve(null)),
  },
};

const reference = async (type: string, payload: JsonObject): Promise<Verdict> => {
  if (type === 'account.setTimeZone') {
    const account = new AccountService(dependency(WORLD), dependency({ ...WORLD, findById: { id: 1n, scheduleStartMin: 360, scheduleEndMin: 1380 } }), dependency(WORLD), dependency(WORLD));
    return verdictOf(() => account.patch(payload), 'body.');
  }
  const world = { ...WORLD, select: [{ timezone: 'UTC', intensityMode: 'standard', lastHpDate: null }], ...TYPE_WORLD[type] };
  register(world);
  const bus = new CommandBus(dependency(world), dependency(world), dependency(world));
  for (const [name, handler] of handlers) bus.registerHandler(name, handler);
  return verdictOf(() => {
    const handler = handlers.get(type);
    if (!handler) return bus.execute(1n, { commandId: J1, type, payload, localDate: TODAY });
    return handler({ accountId: 1n, envelope: { commandId: J1, type, payload, localDate: TODAY }, tx: transaction(world) });
  });
};

/** The reference's account patch checks these through its route schema (`account.dto.ts`), which a generator cannot run, so they are read from it. */
const dto = readFileSync(join(src, 'modules/account/account.dto.ts'), 'utf8');
const returnerBounds = /minimum: (\d+), maximum: (\d+), errorMessage: 'returnerThresholdDays/.exec(dto);
if (!returnerBounds) throw new Error('returnerThresholdDays bounds not found in account.dto.ts');
const [returnerMinimum, returnerMaximum] = [Number(returnerBounds[1]), Number(returnerBounds[2])];
const intensityModes = Object.keys(rules.currentRuleset().intensityModes);
const schemaVerdict = (type: string, payload: JsonObject): Verdict => {
  if (type === 'account.setIntensityMode') return intensityModes.includes(payload['intensityMode'] as string) ? { accepted: true } : { refused: { field: 'intensityMode' } };
  const days = payload['returnerThresholdDays'];
  return typeof days === 'number' && Number.isInteger(days) && days >= returnerMinimum && days <= returnerMaximum
    ? { accepted: true }
    : { refused: { field: 'returnerThresholdDays' } };
};

interface Input {
  id: string;
  payload: JsonObject;
  occurrence?: typeof OCC;
  content?: JsonObject;
  /** What the native code does where it deliberately differs from the reference, with why. */
  native?: Verdict;
  reason?: string;
}
interface Group {
  type: string;
  source: 'handler' | 'schema' | 'native';
  inputs: Input[];
}

const REC = { frequency: 'daily', interval: 1, startDate: '2026-01-01', end: { kind: 'never' } };
const WEEKLY = { ...REC, frequency: 'weekly', daysOfWeek: [1, 3, 5] };
const MONTHLY = { ...REC, frequency: 'monthly', pattern: { kind: 'day_of_month', dayOfMonth: 15 } };
const NTH = { ...REC, frequency: 'monthly', pattern: { kind: 'nth_weekday', weekday: 1, ordinal: 'last' } };
const QUEST = { questId: Q1, strictness: 'routine', startTimeMinutes: 480, durationMinutes: 30, statAffinity: 'body', recurrence: REC };
const quest = (changes: JsonObject, drop: string[] = []): JsonObject => without({ ...QUEST, ...changes }, ...drop);
const rec = (base: JsonObject, changes: JsonObject, drop: string[] = []): JsonObject => quest({ recurrence: without({ ...base, ...changes }, ...drop) });
const refused = (field: string): Verdict => ({ refused: { field } });
const nativeCode = (code: string): Verdict => ({ refused: { code } });
const CONTENT = 'content stays in the record the command names, so the payload refuses it';
const STRICT_FLAG = 'a flag the reference reads as false unless it is true must be a boolean here';
const STRICT_DATE = 'the reference only requires a non-empty string; a native date must be a real date';
const NATIVE_ID = 'the native command names the record it creates by id, where the reference returns a server id';
const UUID_ID = 'native ids are UUIDs';
const CANONICAL_ZONE =
  'a zone is UTC, GMT or a canonical Area/Location name, so token-shaped text cannot pass as one; ICU also accepts other spellings, offsets and one-word legacy zones';
const occurrenceCases: Input[] = [
  { id: 'base', payload: {}, occurrence: OCC },
  { id: 'no-occurrence', payload: {}, native: nativeCode('memoir_command.occurrence_required'), reason: 'the occurrence is the command record’s own field' },
  { id: 'stray-field', payload: { performedAt: 'now' }, occurrence: OCC, native: refused('performedAt'), reason: 'the instant is the command’s own; the payload has no performedAt' },
];

const groups: Group[] = [
  {
    type: 'quest.create',
    source: 'handler',
    inputs: [
      { id: 'base', payload: QUEST },
      { id: 'anchor-with-start', payload: quest({ strictness: 'anchor' }) },
      { id: 'anchor-without-start', payload: quest({ strictness: 'anchor' }, ['startTimeMinutes']) },
      { id: 'anchor-null-start', payload: quest({ strictness: 'anchor', startTimeMinutes: null }) },
      { id: 'every-strictness-optional', payload: quest({ strictness: 'optional', optionalStreakOptIn: true }) },
      { id: 'strictness-missing', payload: quest({}, ['strictness']) },
      { id: 'strictness-unknown', payload: quest({ strictness: 'strict' }) },
      { id: 'start-null', payload: quest({ startTimeMinutes: null }) },
      { id: 'start-zero', payload: quest({ startTimeMinutes: 0 }) },
      { id: 'start-last-minute', payload: quest({ startTimeMinutes: 1439 }) },
      { id: 'start-negative', payload: quest({ startTimeMinutes: -1 }) },
      { id: 'start-1440', payload: quest({ startTimeMinutes: 1440 }) },
      { id: 'start-string', payload: quest({ startTimeMinutes: 'noon' }) },
      { id: 'duration-missing', payload: quest({}, ['durationMinutes']) },
      { id: 'duration-null', payload: quest({ durationMinutes: null }) },
      { id: 'duration-negative', payload: quest({ durationMinutes: -5 }) },
      { id: 'duration-string', payload: quest({ durationMinutes: 'half' }) },
      { id: 'stat-missing', payload: quest({}, ['statAffinity']) },
      { id: 'stat-unknown', payload: quest({ statAffinity: 'strength' }) },
      { id: 'streak-opt-in-string', payload: quest({ optionalStreakOptIn: 'yes' }) },
      { id: 'streak-opt-in-null', payload: quest({ optionalStreakOptIn: null }) },
      { id: 'recurrence-missing', payload: quest({}, ['recurrence']) },
      { id: 'recurrence-string', payload: quest({ recurrence: 'daily' }) },
      { id: 'frequency-unknown', payload: rec(REC, { frequency: 'hourly' }) },
      { id: 'interval-missing', payload: rec(REC, {}, ['interval']) },
      { id: 'interval-zero', payload: rec(REC, { interval: 0 }) },
      { id: 'interval-negative', payload: rec(REC, { interval: -3 }) },
      { id: 'interval-string', payload: rec(REC, { interval: 'two' }) },
      { id: 'start-date-missing', payload: rec(REC, {}, ['startDate']) },
      { id: 'start-date-invalid', payload: rec(REC, { startDate: '2026-02-30' }) },
      { id: 'start-date-slashes', payload: rec(REC, { startDate: '2026/01/01' }) },
      { id: 'start-date-year-zero', payload: rec(REC, { startDate: '0000-01-01' }) },
      { id: 'end-missing', payload: rec(REC, {}, ['end']) },
      { id: 'end-kind-unknown', payload: rec(REC, { end: { kind: 'sometimes' } }) },
      { id: 'end-count', payload: rec(REC, { end: { kind: 'count', count: 3 } }) },
      { id: 'end-count-zero', payload: rec(REC, { end: { kind: 'count', count: 0 } }) },
      { id: 'end-count-missing', payload: rec(REC, { end: { kind: 'count' } }) },
      { id: 'end-count-string', payload: rec(REC, { end: { kind: 'count', count: 'three' } }) },
      { id: 'end-until', payload: rec(REC, { end: { kind: 'until', date: '2026-12-31' } }) },
      { id: 'end-until-invalid', payload: rec(REC, { end: { kind: 'until', date: '2026-12-32' } }) },
      { id: 'end-until-missing', payload: rec(REC, { end: { kind: 'until' } }) },
      { id: 'exceptions', payload: rec(REC, { exceptions: ['2026-01-05', '2026-01-03'] }) },
      { id: 'exceptions-empty', payload: rec(REC, { exceptions: [] }) },
      { id: 'exceptions-duplicate', payload: rec(REC, { exceptions: ['2026-01-05', '2026-01-05'] }) },
      { id: 'exceptions-not-array', payload: rec(REC, { exceptions: '2026-01-05' }) },
      { id: 'exceptions-null', payload: rec(REC, { exceptions: null }) },
      { id: 'exceptions-empty-string', payload: rec(REC, { exceptions: [''] }) },
      { id: 'exceptions-second-invalid', payload: rec(REC, { exceptions: ['2026-01-05', '2026-13-01'] }) },
      { id: 'weekly', payload: rec(WEEKLY, {}) },
      { id: 'weekly-duplicate-days', payload: rec(WEEKLY, { daysOfWeek: [1, 1, 7] }) },
      { id: 'weekly-empty', payload: rec(WEEKLY, { daysOfWeek: [] }) },
      { id: 'weekly-missing', payload: rec(WEEKLY, {}, ['daysOfWeek']) },
      { id: 'weekly-zero', payload: rec(WEEKLY, { daysOfWeek: [0] }) },
      { id: 'weekly-eight', payload: rec(WEEKLY, { daysOfWeek: [1, 8] }) },
      { id: 'weekly-string-day', payload: rec(WEEKLY, { daysOfWeek: ['monday'] }) },
      { id: 'monthly-day', payload: rec(MONTHLY, {}) },
      { id: 'monthly-day-31', payload: rec(MONTHLY, { pattern: { kind: 'day_of_month', dayOfMonth: 31 } }) },
      { id: 'monthly-day-99', payload: rec(MONTHLY, { pattern: { kind: 'day_of_month', dayOfMonth: 99 } }) },
      {
        id: 'monthly-day-zero',
        payload: rec(MONTHLY, { pattern: { kind: 'day_of_month', dayOfMonth: 0 } }),
        native: refused('recurrence.pattern.dayOfMonth'),
        reason: 'the reference turns a day below 1 into dates that do not exist; RecurrenceRule refuses it',
      },
      {
        id: 'monthly-day-negative',
        payload: rec(MONTHLY, { pattern: { kind: 'day_of_month', dayOfMonth: -1 } }),
        native: refused('recurrence.pattern.dayOfMonth'),
        reason: 'the reference turns a day below 1 into dates that do not exist; RecurrenceRule refuses it',
      },
      { id: 'monthly-day-string', payload: rec(MONTHLY, { pattern: { kind: 'day_of_month', dayOfMonth: 'mid' } }) },
      { id: 'monthly-pattern-missing', payload: rec(MONTHLY, {}, ['pattern']) },
      { id: 'monthly-pattern-kind-unknown', payload: rec(MONTHLY, { pattern: { kind: 'weekly' } }) },
      { id: 'monthly-nth', payload: rec(NTH, {}) },
      { id: 'monthly-nth-first', payload: rec(NTH, { pattern: { kind: 'nth_weekday', weekday: 7, ordinal: 1 } }) },
      { id: 'monthly-nth-ordinal-five', payload: rec(NTH, { pattern: { kind: 'nth_weekday', weekday: 1, ordinal: 5 } }) },
      { id: 'monthly-nth-ordinal-word', payload: rec(NTH, { pattern: { kind: 'nth_weekday', weekday: 1, ordinal: 'first' } }) },
      { id: 'monthly-nth-weekday-zero', payload: rec(NTH, { pattern: { kind: 'nth_weekday', weekday: 0, ordinal: 1 } }) },
      { id: 'yearly', payload: rec(REC, { frequency: 'yearly' }) },
      { id: 'module-link', payload: quest({ moduleLink: 'journal' }) },
      { id: 'module-link-null', payload: quest({ moduleLink: null }) },
      { id: 'module-link-unknown', payload: quest({ moduleLink: 'diary' }) },
      { id: 'inactive', payload: quest({ active: false }) },
      { id: 'active-string', payload: quest({ active: 'no' }) },
      {
        id: 'health-threshold',
        payload: quest({ healthThreshold: { metric: M1 } }),
        native: refused('healthThreshold'),
        reason: 'quest health thresholds need a record kind of their own; until then they are refused',
      },
      {
        id: 'health-threshold-null',
        payload: quest({ healthThreshold: null }),
        native: refused('healthThreshold'),
        reason: 'quest health thresholds need a record kind of their own; until then they are refused',
      },
      { id: 'quest-id-missing', payload: quest({}, ['questId']), native: refused('questId'), reason: NATIVE_ID },
      { id: 'quest-id-not-uuid', payload: quest({ questId: 'quest-1' }), native: refused('questId'), reason: NATIVE_ID },
      { id: 'name-in-payload', payload: quest({ name: 'Morning run' }), native: refused('name'), reason: CONTENT },
      { id: 'notification-in-payload', payload: quest({ notification: { enabled: true } }), native: refused('notification'), reason: CONTENT },
      {
        id: 'daily-with-weekdays',
        payload: rec(REC, { daysOfWeek: [1] }),
        native: refused('recurrence.daysOfWeek'),
        reason: 'a field the frequency does not use is refused where the reference ignores it',
      },
    ],
  },
  {
    type: 'quest.update',
    source: 'handler',
    inputs: [
      { id: 'base', payload: { questId: Q1, patch: { durationMinutes: 45 } } },
      { id: 'empty-patch', payload: { questId: Q1, patch: {} } },
      { id: 'no-patch', payload: { questId: Q1 } },
      { id: 'null-patch', payload: { questId: Q1, patch: null } },
      { id: 'quest-id-missing', payload: { patch: {} } },
      { id: 'quest-id-not-uuid', payload: { questId: 'abc', patch: {} } },
      { id: 'clear-start', payload: { questId: Q1, patch: { startTimeMinutes: null } } },
      { id: 'anchor-clearing-start', payload: { questId: Q1, patch: { strictness: 'anchor', startTimeMinutes: null } } },
      { id: 'anchor-keeping-start', payload: { questId: Q1, patch: { strictness: 'anchor' } } },
      { id: 'start-out-of-range', payload: { questId: Q1, patch: { startTimeMinutes: 2000 } } },
      { id: 'duration-null', payload: { questId: Q1, patch: { durationMinutes: null } } },
      { id: 'stat', payload: { questId: Q1, patch: { statAffinity: 'mind' } } },
      { id: 'stat-unknown', payload: { questId: Q1, patch: { statAffinity: 'luck' } } },
      { id: 'strictness-unknown', payload: { questId: Q1, patch: { strictness: 'loose' } } },
      { id: 'streak-opt-in-null', payload: { questId: Q1, patch: { optionalStreakOptIn: null } } },
      { id: 'recurrence', payload: { questId: Q1, patch: { recurrence: WEEKLY } } },
      { id: 'recurrence-empty-week', payload: { questId: Q1, patch: { recurrence: { ...WEEKLY, daysOfWeek: [] } } } },
      { id: 'module-link-clear', payload: { questId: Q1, patch: { moduleLink: null } } },
      { id: 'module-link-unknown', payload: { questId: Q1, patch: { moduleLink: 'x' } } },
      { id: 'deactivate', payload: { questId: Q1, patch: { active: false } } },
      { id: 'patch-string', payload: { questId: Q1, patch: 'x' }, native: refused('patch'), reason: 'the reference reads a non-object patch as an empty one; it is refused here' },
      { id: 'health-threshold-null', payload: { questId: Q1, patch: { healthThreshold: null } }, native: refused('healthThreshold'), reason: 'quest health thresholds are refused for now' },
      { id: 'name-in-patch', payload: { questId: Q1, patch: { name: 'Evening run' } }, native: refused('name'), reason: CONTENT },
    ],
  },
  {
    type: 'quest.delete',
    source: 'handler',
    inputs: [
      { id: 'base', payload: { questId: Q1 } },
      { id: 'missing', payload: {} },
      { id: 'number', payload: { questId: 5 } },
      { id: 'not-uuid', payload: { questId: 'abc' } },
    ],
  },
  { type: 'quest.complete', source: 'handler', inputs: occurrenceCases },
  { type: 'quest.partial', source: 'handler', inputs: occurrenceCases },
  {
    type: 'quest.skip',
    source: 'handler',
    inputs: [
      ...occurrenceCases,
      { id: 'reason', payload: { reasonTag: 'forgot' }, occurrence: OCC },
      { id: 'reason-null', payload: { reasonTag: null }, occurrence: OCC },
      { id: 'reason-unknown', payload: { reasonTag: 'lazy' }, occurrence: OCC },
      { id: 'note', payload: { reasonTag: 'too_tired', note: true }, occurrence: OCC },
      { id: 'note-null', payload: { note: null }, occurrence: OCC },
      { id: 'note-text', payload: { note: 'tired' }, occurrence: OCC, native: refused('note'), reason: 'the note’s text is the command’s note record; the payload says only that one is attached' },
    ],
  },
  {
    type: 'quest.postpone',
    source: 'handler',
    inputs: [...occurrenceCases, { id: 'reason', payload: { reasonTag: 'travel', note: true }, occurrence: OCC }, { id: 'reason-unknown', payload: { reasonTag: 'x' }, occurrence: OCC }],
  },
  {
    type: 'quest.reschedule',
    source: 'handler',
    inputs: [
      { id: 'base', payload: { toMin: 600 }, occurrence: OCC },
      { id: 'missing', payload: {}, occurrence: OCC },
      { id: 'zero', payload: { toMin: 0 }, occurrence: OCC },
      { id: 'too-late', payload: { toMin: 1440 }, occurrence: OCC },
      { id: 'negative', payload: { toMin: -1 }, occurrence: OCC },
      { id: 'string', payload: { toMin: 'ten' }, occurrence: OCC },
      { id: 'beyond-cap', payload: { toMin: 600, acceptBeyondCap: true }, occurrence: OCC },
      { id: 'beyond-cap-string', payload: { toMin: 600, acceptBeyondCap: 'yes' }, occurrence: OCC, native: refused('acceptBeyondCap'), reason: STRICT_FLAG },
      { id: 'reason', payload: { toMin: 600, reasonTag: 'schedule_conflict', note: true }, occurrence: OCC },
      { id: 'reason-unknown', payload: { toMin: 600, reasonTag: 'busy' }, occurrence: OCC },
      { id: 'no-occurrence', payload: { toMin: 600 }, native: nativeCode('memoir_command.occurrence_required'), reason: 'the occurrence is the command record’s own field' },
    ],
  },
  {
    type: 'quest.attachReason',
    source: 'handler',
    inputs: [
      { id: 'neither', payload: {}, occurrence: OCC },
      { id: 'tag', payload: { reasonTag: 'health' }, occurrence: OCC },
      { id: 'note', payload: { note: true }, occurrence: OCC },
      { id: 'both', payload: { reasonTag: 'other', note: true }, occurrence: OCC },
      { id: 'tag-unknown', payload: { reasonTag: 'x' }, occurrence: OCC },
      { id: 'tag-null', payload: { reasonTag: null }, occurrence: OCC },
    ],
  },
  {
    type: 'quest.editLog',
    source: 'handler',
    inputs: [
      { id: 'empty', payload: {}, occurrence: OCC },
      { id: 'tag', payload: { reasonTag: 'other' }, occurrence: OCC },
      { id: 'tag-clear', payload: { reasonTag: null }, occurrence: OCC },
      { id: 'tag-unknown', payload: { reasonTag: 'x' }, occurrence: OCC },
      { id: 'note', payload: { note: true }, occurrence: OCC },
      { id: 'note-clear', payload: { note: null }, occurrence: OCC },
      { id: 'reflection', payload: { reflectionText: true }, occurrence: OCC },
      { id: 'reflection-clear', payload: { reflectionText: null }, occurrence: OCC },
      {
        id: 'note-and-reflection',
        payload: { note: true, reflectionText: true },
        occurrence: OCC,
        native: nativeCode('memoir_command.one_text_per_command'),
        reason: 'a command keeps one text in its note record',
      },
    ],
  },
  { type: 'quest.deleteLog', source: 'handler', inputs: occurrenceCases },
  {
    type: 'recovery.complete',
    source: 'handler',
    inputs: [
      { id: 'base', payload: {} },
      { id: 'reflection', payload: { reflectionText: true } },
      { id: 'reflection-null', payload: { reflectionText: null } },
      { id: 'reflection-number', payload: { reflectionText: 5 } },
      { id: 'occurrence', payload: {}, occurrence: OCC, native: nativeCode('memoir_command.occurrence_unexpected'), reason: 'recovery acts on the day, not an occurrence' },
    ],
  },
  {
    type: 'plan.setLock',
    source: 'handler',
    inputs: [
      { id: 'unlock', payload: { locked: false } },
      { id: 'unlock-by-default', payload: {} },
      { id: 'lock', payload: { locked: true, questIds: [Q1, Q2] } },
      { id: 'lock-without-ids', payload: { locked: true } },
      { id: 'lock-empty-ids', payload: { locked: true, questIds: [] } },
      { id: 'lock-ids-not-array', payload: { locked: true, questIds: Q1 } },
      { id: 'lock-bad-id', payload: { locked: true, questIds: ['abc'] } },
      { id: 'lock-duplicate-id', payload: { locked: true, questIds: [Q1, Q1] } },
      { id: 'locked-string', payload: { locked: 'true' }, native: refused('locked'), reason: STRICT_FLAG },
      { id: 'unlock-with-ids', payload: { locked: false, questIds: [Q1] }, native: refused('questIds'), reason: 'an unlock names no quests; the reference ignores them' },
    ],
  },
  {
    type: 'metric.create',
    source: 'handler',
    inputs: [
      { id: 'base', payload: { id: M1, metricClass: 'general' } },
      { id: 'health', payload: { id: M1, metricClass: 'health' } },
      { id: 'class-unknown', payload: { id: M1, metricClass: 'secret' }, native: refused('metricClass'), reason: 'a metric’s class is part of its kind; the command names it' },
      { id: 'id-missing', payload: { metricClass: 'general' }, native: refused('id'), reason: NATIVE_ID },
      { id: 'value-in-payload', payload: { id: M1, metricClass: 'general', defaultValue: 5 }, native: refused('defaultValue'), reason: CONTENT },
    ],
  },
  {
    type: 'metric.update',
    source: 'handler',
    inputs: [
      { id: 'base', payload: { id: M1, metricClass: 'activity' } },
      { id: 'id-missing', payload: { metricClass: 'activity' } },
      { id: 'id-not-number', payload: { id: 'abc', metricClass: 'activity' } },
      { id: 'name-in-payload', payload: { id: M1, metricClass: 'activity', name: 'Steps' }, native: refused('name'), reason: CONTENT },
    ],
  },
  {
    type: 'metric.delete',
    source: 'handler',
    inputs: [
      { id: 'base', payload: { id: M1, metricClass: 'general' } },
      { id: 'detach', payload: { id: M1, metricClass: 'general', detach: true } },
      { id: 'detach-string', payload: { id: M1, metricClass: 'general', detach: 'yes' }, native: refused('detach'), reason: STRICT_FLAG },
      { id: 'id-missing', payload: { metricClass: 'general' } },
    ],
  },
  {
    type: 'metric.register',
    source: 'handler',
    inputs: [
      { id: 'base', payload: { metricId: M1, metricClass: 'health', date: '2026-11-19' } },
      { id: 'food', payload: { metricId: M1, metricClass: 'general', date: '2026-11-19', source: 'food' } },
      { id: 'quest-log', payload: { metricId: M1, metricClass: 'activity', date: '2026-11-19', source: 'quest_log' }, occurrence: OCC },
      { id: 'source-unknown', payload: { metricId: M1, metricClass: 'health', date: '2026-11-19', source: 'health' } },
      { id: 'source-null', payload: { metricId: M1, metricClass: 'health', date: '2026-11-19', source: null } },
      { id: 'date-missing', payload: { metricId: M1, metricClass: 'health' } },
      { id: 'date-word', payload: { metricId: M1, metricClass: 'health', date: 'yesterday' }, native: refused('date'), reason: STRICT_DATE },
      { id: 'metric-missing', payload: { metricClass: 'health', date: '2026-11-19' } },
      { id: 'value-in-payload', payload: { metricId: M1, metricClass: 'health', date: '2026-11-19', value: 72 }, native: refused('value'), reason: CONTENT },
    ],
  },
  {
    type: 'expense.create',
    source: 'handler',
    inputs: [
      { id: 'base', payload: { id: E1 } },
      { id: 'ocr', payload: { id: E1, source: 'ocr' } },
      { id: 'source-unknown', payload: { id: E1, source: 'scan' } },
      { id: 'id-missing', payload: {} },
      { id: 'id-not-uuid', payload: { id: 'expense-1' }, native: refused('id'), reason: UUID_ID },
      { id: 'amount-in-payload', payload: { id: E1, amountMinor: 1250 }, native: refused('amountMinor'), reason: CONTENT },
    ],
  },
  { type: 'expense.update', source: 'handler', inputs: [{ id: 'base', payload: { id: E1 } }, { id: 'id-missing', payload: {} }] },
  { type: 'expense.delete', source: 'handler', inputs: [{ id: 'base', payload: { id: E1 } }, { id: 'id-missing', payload: {} }] },
  {
    type: 'subscription.create',
    source: 'handler',
    inputs: [
      { id: 'base', payload: { id: S1 } },
      { id: 'id-missing', payload: {}, native: refused('id'), reason: NATIVE_ID },
    ],
  },
  {
    type: 'subscription.update',
    source: 'handler',
    inputs: [
      { id: 'base', payload: { id: S1 } },
      { id: 'id-missing', payload: {} },
      { id: 'id-not-number', payload: { id: 'abc' } },
    ],
  },
  { type: 'subscription.delete', source: 'handler', inputs: [{ id: 'base', payload: { id: S1 } }, { id: 'id-missing', payload: {} }] },
  {
    type: 'subscription.confirmCycle',
    source: 'handler',
    inputs: [
      { id: 'base', payload: { id: S1, billingDate: '2026-11-05' } },
      { id: 'billing-date-missing', payload: { id: S1 } },
      { id: 'billing-date-word', payload: { id: S1, billingDate: 'soon' }, native: refused('billingDate'), reason: STRICT_DATE },
      { id: 'id-missing', payload: { billingDate: '2026-11-05' } },
      { id: 'expense-id', payload: { id: S1, billingDate: '2026-11-05', expenseId: E1 }, native: refused('expenseId'), reason: 'the cycle’s expense id is derived from the subscription and the billing date' },
    ],
  },
  {
    type: 'category.setArchived',
    source: 'handler',
    inputs: [
      { id: 'archive', payload: { categoryId: 'food', archived: true } },
      { id: 'unarchive', payload: { categoryId: 'food', archived: false } },
      { id: 'archive-uncategorised', payload: { categoryId: 'uncat', archived: true } },
      { id: 'archive-subscriptions', payload: { categoryId: 'subs', archived: true } },
      { id: 'unarchive-subscriptions', payload: { categoryId: 'subs', archived: false } },
      { id: 'archived-missing', payload: { categoryId: 'food' } },
      { id: 'archived-string', payload: { categoryId: 'food', archived: 'yes' } },
      { id: 'category-missing', payload: { archived: true } },
      { id: 'category-not-key', payload: { categoryId: 'Food-Drink', archived: true } },
      { id: 'category-unknown', payload: { categoryId: 'rent', archived: false } },
      { id: 'every-built-in', payload: { categoryId: 'groceries', archived: true } },
    ],
  },
  {
    type: 'title.display',
    source: 'handler',
    inputs: [
      { id: 'title', payload: { titleId: 'steady_builder' } },
      { id: 'none', payload: { titleId: null } },
      { id: 'missing', payload: {} },
      { id: 'unknown', payload: { titleId: 'champion' } },
      { id: 'number', payload: { titleId: 5 } },
    ],
  },
  {
    type: 'cosmetic.purchase',
    source: 'handler',
    inputs: [
      { id: 'for-sale', payload: { cosmeticId: 'badge_bronze' } },
      { id: 'theme', payload: { cosmeticId: 'theme_midnight' } },
      { id: 'achievement-only', payload: { cosmeticId: 'badge_gold_streak' } },
      { id: 'unknown', payload: { cosmeticId: 'crown' } },
      { id: 'missing', payload: {} },
    ],
  },
  {
    type: 'cosmetic.equip',
    source: 'handler',
    inputs: [
      { id: 'achievement-only', payload: { cosmeticId: 'accent_aurora_platinum' } },
      { id: 'unknown', payload: { cosmeticId: 'crown' } },
      { id: 'missing', payload: {} },
    ],
  },
  {
    type: 'journal.save',
    source: 'handler',
    inputs: [
      { id: 'base', payload: { id: J1, draft: { date: TODAY } } },
      { id: 'backdated', payload: { id: J1, draft: { date: '2026-11-01' } } },
      { id: 'draft-missing', payload: { id: J1 } },
      { id: 'id-missing', payload: { draft: { date: TODAY } } },
      { id: 'date-missing', payload: { id: J1, draft: {} } },
      { id: 'date-word', payload: { id: J1, draft: { date: 'today' } }, native: refused('date'), reason: STRICT_DATE },
      { id: 'text-in-payload', payload: { id: J1, draft: { date: TODAY, text: 'A good day' } }, native: refused('text'), reason: CONTENT },
    ],
  },
  {
    type: 'meal.log',
    source: 'handler',
    inputs: [
      { id: 'base', payload: { id: J1, draft: { date: TODAY } } },
      { id: 'draft-missing', payload: { id: J1 } },
      { id: 'date-missing', payload: { id: J1, draft: {} } },
      { id: 'calories-in-payload', payload: { id: J1, draft: { date: TODAY, calories: 300 } }, native: refused('calories'), reason: CONTENT },
    ],
  },
  {
    type: 'meal.logPreset',
    source: 'handler',
    inputs: [
      { id: 'base', payload: { id: J1, presetId: P1, date: TODAY } },
      { id: 'preset-missing', payload: { id: J1, date: TODAY } },
      { id: 'date-missing', payload: { id: J1, presetId: P1 } },
      { id: 'id-missing', payload: { presetId: P1, date: TODAY } },
    ],
  },
  {
    type: 'meal.savePreset',
    source: 'handler',
    inputs: [
      { id: 'base', payload: { id: P1 } },
      { id: 'id-missing', payload: {}, native: refused('id'), reason: NATIVE_ID },
    ],
  },
  { type: 'meal.preset.update', source: 'handler', inputs: [{ id: 'base', payload: { id: P1 } }, { id: 'id-missing', payload: {} }] },
  { type: 'meal.preset.delete', source: 'handler', inputs: [{ id: 'base', payload: { id: P1 } }, { id: 'id-missing', payload: {} }] },
  {
    type: 'weight.save',
    source: 'handler',
    inputs: [
      { id: 'base', payload: { date: TODAY } },
      { id: 'replacement', payload: { date: TODAY, confirmedReplacement: true } },
      { id: 'replacement-string', payload: { date: TODAY, confirmedReplacement: 'yes' }, native: refused('confirmedReplacement'), reason: STRICT_FLAG },
      { id: 'date-missing', payload: {} },
      { id: 'kg-in-payload', payload: { date: TODAY, kg: 72 }, native: refused('kg'), reason: CONTENT },
    ],
  },
  {
    type: 'sidequest.log',
    source: 'handler',
    inputs: [
      { id: 'base', payload: { id: J1, draft: { date: TODAY } } },
      { id: 'stat', payload: { id: J1, draft: { date: TODAY, statAffinity: 'mind' } } },
      { id: 'stat-unknown', payload: { id: J1, draft: { date: TODAY, statAffinity: 'luck' } } },
      { id: 'stat-null', payload: { id: J1, draft: { date: TODAY, statAffinity: null } } },
      { id: 'draft-missing', payload: { id: J1 } },
      { id: 'date-missing', payload: { id: J1, draft: {} } },
    ],
  },
  {
    type: 'account.setTimeZone',
    source: 'handler',
    inputs: [
      { id: 'berlin', payload: { timezone: 'Europe/Berlin' } },
      { id: 'buenos-aires', payload: { timezone: 'America/Argentina/Buenos_Aires' } },
      { id: 'utc', payload: { timezone: 'UTC' } },
      { id: 'offset-zone', payload: { timezone: 'Etc/GMT+5' } },
      {
        id: 'unknown-zone',
        payload: { timezone: 'Mars/Olympus' },
        native: { accepted: true },
        reason: 'decoding checks only the identifier’s shape so that older zone data replays it alike; TimeZoneChange(identifier:) refuses it when issuing',
      },
      { id: 'number', payload: { timezone: 5 } },
      { id: 'gmt', payload: { timezone: 'GMT' } },
      { id: 'etc-utc', payload: { timezone: 'Etc/UTC' } },
      { id: 'gmt-offset', payload: { timezone: 'GMT+5' } },
      { id: 'gmt-offset-minutes', payload: { timezone: 'GMT+0530' } },
      { id: 'utc-offset', payload: { timezone: 'UTC+3' } },
      { id: 'lower-case', payload: { timezone: 'europe/berlin' }, native: refused('timezone'), reason: CANONICAL_ZONE },
      { id: 'iso-offset', payload: { timezone: '+05:00' }, native: refused('timezone'), reason: CANONICAL_ZONE },
      { id: 'legacy-one-word', payload: { timezone: 'CET' }, native: refused('timezone'), reason: CANONICAL_ZONE },
      { id: 'token-text', payload: { timezone: 'Morning_run' } },
      { id: 'empty', payload: { timezone: '' } },
    ],
  },
  {
    type: 'account.setIntensityMode',
    source: 'schema',
    inputs: [
      { id: 'standard', payload: { intensityMode: 'standard' } },
      { id: 'low', payload: { intensityMode: 'low_intensity' } },
      { id: 'high', payload: { intensityMode: 'high_intensity' } },
      { id: 'unknown', payload: { intensityMode: 'extreme' } },
      { id: 'missing', payload: {} },
    ],
  },
  {
    type: 'account.setReturnerThreshold',
    source: 'schema',
    inputs: [
      { id: 'lowest', payload: { returnerThresholdDays: returnerMinimum } },
      { id: 'highest', payload: { returnerThresholdDays: returnerMaximum } },
      { id: 'below', payload: { returnerThresholdDays: returnerMinimum - 1 } },
      { id: 'above', payload: { returnerThresholdDays: returnerMaximum + 1 } },
      { id: 'string', payload: { returnerThresholdDays: 'week' } },
      { id: 'missing', payload: {} },
    ],
  },
  {
    type: 'receipt.scan',
    source: 'native',
    inputs: [
      { id: 'bare', payload: {}, native: { accepted: true }, reason: 'the reference counts a scan in its OCR endpoint, not a command' },
      { id: 'receipt', payload: { receiptId: R1 }, native: { accepted: true }, reason: 'the reference counts a scan in its OCR endpoint, not a command' },
      { id: 'receipt-not-uuid', payload: { receiptId: 'r/1/x.jpg' }, native: refused('receiptId'), reason: UUID_ID },
      { id: 'text-in-payload', payload: { extractedText: 'TOTAL' }, native: refused('extractedText'), reason: CONTENT },
    ],
  },
  {
    type: 'quest.fly',
    source: 'handler',
    inputs: [{ id: 'unknown-type', payload: {} }],
  },
];

/** Content the reference validates inside its payload, which is a record here; each case is checked against the record's own validation. */
interface ContentInput {
  id: string;
  type: string;
  payload: JsonObject;
  occurrence?: typeof OCC;
  content: JsonObject;
  native?: Verdict;
  reason?: string;
}
const NOTE_120 = 'n'.repeat(120);
const contentInputs: ContentInput[] = [
  { id: 'quest-name-empty', type: 'quest.create', payload: QUEST, content: { name: '' } },
  { id: 'quest-name-blank', type: 'quest.create', payload: QUEST, content: { name: ' ' } },
  { id: 'note-empty', type: 'quest.skip', payload: {}, occurrence: OCC, content: { note: '' } },
  { id: 'note-120', type: 'quest.skip', payload: {}, occurrence: OCC, content: { note: NOTE_120 } },
  { id: 'note-121', type: 'quest.skip', payload: {}, occurrence: OCC, content: { note: `${NOTE_120}n` } },
  { id: 'note-emoji-120-units', type: 'quest.skip', payload: {}, occurrence: OCC, content: { note: `${'n'.repeat(118)}\u{1F600}` } },
  { id: 'note-emoji-121-units', type: 'quest.skip', payload: {}, occurrence: OCC, content: { note: `${'n'.repeat(119)}\u{1F600}` } },
  { id: 'reschedule-note-121', type: 'quest.reschedule', payload: { toMin: 600 }, occurrence: OCC, content: { note: `${NOTE_120}n` } },
  { id: 'attach-note-121', type: 'quest.attachReason', payload: {}, occurrence: OCC, content: { note: `${NOTE_120}n` } },
  {
    id: 'reflection-empty',
    type: 'recovery.complete',
    payload: {},
    content: { reflectionText: '' },
    native: refused('reflectionText'),
    reason: 'a note record holds text, so an empty reflection is refused where the reference keeps an empty string',
  },
  { id: 'journal-text-empty', type: 'journal.save', payload: { id: J1, draft: { date: TODAY } }, content: { text: '' } },
  { id: 'journal-mood-zero', type: 'journal.save', payload: { id: J1, draft: { date: TODAY } }, content: { mood: 0 } },
  { id: 'journal-mood-one', type: 'journal.save', payload: { id: J1, draft: { date: TODAY } }, content: { mood: 1 } },
  { id: 'journal-mood-five', type: 'journal.save', payload: { id: J1, draft: { date: TODAY } }, content: { mood: 5 } },
  { id: 'journal-mood-six', type: 'journal.save', payload: { id: J1, draft: { date: TODAY } }, content: { mood: 6 } },
  { id: 'meal-name-empty', type: 'meal.log', payload: { id: J1, draft: { date: TODAY } }, content: { name: '' } },
  { id: 'meal-calories-zero', type: 'meal.log', payload: { id: J1, draft: { date: TODAY } }, content: { calories: 0 } },
  { id: 'meal-calories-negative', type: 'meal.log', payload: { id: J1, draft: { date: TODAY } }, content: { calories: -1 } },
  { id: 'preset-name-empty', type: 'meal.savePreset', payload: { id: P1 }, content: { name: '' } },
  { id: 'preset-calories-negative', type: 'meal.savePreset', payload: { id: P1 }, content: { calories: -1 } },
  { id: 'side-quest-name-empty', type: 'sidequest.log', payload: { id: J1, draft: { date: TODAY } }, content: { name: '' } },
  { id: 'weight-zero', type: 'weight.save', payload: { date: TODAY }, content: { kg: '0' } },
  { id: 'weight-negative', type: 'weight.save', payload: { date: TODAY }, content: { kg: '-1' } },
  { id: 'weight-small', type: 'weight.save', payload: { date: TODAY }, content: { kg: '0.5' } },
  { id: 'metric-name-empty', type: 'metric.create', payload: { id: M1, metricClass: 'general' }, content: { name: '' } },
  { id: 'subscription-name-empty', type: 'subscription.create', payload: { id: S1 }, content: { name: '' } },
  { id: 'subscription-billing-day-one', type: 'subscription.create', payload: { id: S1 }, content: { billingDay: 1 } },
  { id: 'subscription-billing-day-31', type: 'subscription.create', payload: { id: S1 }, content: { billingDay: 31 } },
  {
    id: 'subscription-billing-day-zero',
    type: 'subscription.create',
    payload: { id: S1 },
    content: { billingDay: 0 },
    native: refused('billingDay'),
    reason: 'the reference leaves the billing day to its database check; SubscriptionCycle refuses it',
  },
  {
    id: 'subscription-billing-day-32',
    type: 'subscription.create',
    payload: { id: S1 },
    content: { billingDay: 32 },
    native: refused('billingDay'),
    reason: 'the reference leaves the billing day to its database check; SubscriptionCycle refuses it',
  },
];

const output: Record<string, unknown[]> = {};
for (const group of groups) {
  const ids = new Set<string>();
  const cases: unknown[] = [];
  for (const input of group.inputs) {
    if (ids.has(input.id)) throw new Error(`duplicate case id ${group.type}/${input.id}`);
    ids.add(input.id);
    const wire = toReference(group.type, input.payload, {}, input.occurrence);
    const verdict =
      group.source === 'native' ? null : group.source === 'schema' ? schemaVerdict(group.type, wire) : await reference(group.type, JSON.parse(JSON.stringify(wire)) as JsonObject);
    if (group.source !== 'native' && !input.native && 'crashed' in (verdict ?? {})) process.stderr.write(`note: ${group.type}/${input.id} crashes the reference\n`);
    cases.push({ id: input.id, payload: input.payload, occurrence: input.occurrence ?? null, reference: verdict, native: input.native ?? null, reason: input.reason ?? null });
  }
  output[group.type] = cases;
}
const content: unknown[] = [];
for (const input of contentInputs) {
  const wire = toReference(input.type, input.payload, input.content, input.occurrence);
  const verdict = await reference(input.type, JSON.parse(JSON.stringify(wire)) as JsonObject);
  content.push({ ...input, occurrence: input.occurrence ?? null, reference: verdict, native: input.native ?? null, reason: input.reason ?? null });
}

const lines = (items: unknown[]): string => items.map(item => JSON.stringify(item)).join(',\n');
const body = Object.entries(output)
  .map(([type, items]) => `${JSON.stringify(type)}: [\n${lines(items)}\n]`)
  .join(',\n');
writeFileSync(join(outDir, 'commands.json'), `{\n${body}\n}\n`);
writeFileSync(join(outDir, 'content.json'), `[\n${lines(content)}\n]\n`);
