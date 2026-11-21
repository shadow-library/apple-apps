import { mock } from 'bun:test';
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');
const outDir = dirname(fileURLToPath(import.meta.url));
const src = join(platformRepo, 'apps/memoir-server/src');

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
type JsonObject = { [key: string]: Json };
type Row = Record<string, unknown>;

let now = 0;
Date.now = () => now;

class ValidationError extends Error {
  fields: { field: string; msg: string }[] = [];
  constructor(field?: string, msg?: string) {
    super(msg ?? 'validation');
    if (field && msg) this.fields.push({ field, msg });
  }
}
class AppError extends Error {
  static internal(message: string): AppError {
    return new AppError(message);
  }
  static is(error: unknown): boolean {
    return error instanceof AppError || error instanceof CodedError;
  }
}
class CodedError extends Error {
  constructor(readonly code: string) {
    super(code);
  }
}
const codes = new Proxy({} as Record<string, unknown>, {
  get: (_, code) => ({
    create: () => new CodedError(String(code)),
    throw: () => {
      throw new CodedError(String(code));
    },
  }),
});

/** An in-memory stand-in for drizzle: tables are row arrays, columns are `{ table, column }`, and `where` takes the predicates the mocked operators build. */
const TABLE = Symbol('table');
type Column = { table: string; column: string };
type Predicate = (row: Row) => boolean;
const tableRef = (name: string): unknown => new Proxy({ [TABLE]: name }, { get: (target, key) => (key === TABLE ? name : ({ table: name, column: String(key) } as Column)) });
const schema = new Proxy({}, { get: (_, name) => tableRef(String(name)) });
const tableName = (table: unknown): string => (table as Record<symbol, string>)[TABLE];
const COUNT = { count: true };
const column = (value: unknown): string => (value as Column).column;
const drizzle = {
  eq: (left: Column, right: unknown): Predicate => row => row[left.column] === right,
  and: (...predicates: (Predicate | undefined)[]): Predicate => row => predicates.every(predicate => !predicate || predicate(row)),
  or: (...predicates: Predicate[]): Predicate => row => predicates.some(predicate => predicate(row)),
  inArray: (left: Column, values: unknown[]): Predicate => row => values.includes(row[left.column]),
  between: (left: Column, low: string, high: string): Predicate => row => (row[left.column] as string) >= low && (row[left.column] as string) <= high,
  isNull: (left: Column): Predicate => row => row[left.column] === null,
  isNotNull: (left: Column): Predicate => row => row[left.column] !== null && row[left.column] !== undefined,
  lte: (left: Column, right: string): Predicate => row => (row[left.column] as string) <= right,
  gte: (left: Column, right: string): Predicate => row => (row[left.column] as string) >= right,
  gt: (left: Column, right: unknown): Predicate => row => (row[left.column] as bigint) > (right as bigint),
  count: () => COUNT,
  min: (value: unknown) => value,
  asc: (value: unknown) => value,
  sql: () => COUNT,
  getTableColumns: () => ({}),
};

class Database {
  tables = new Map<string, Row[]>();
  private serial = new Map<string, bigint>();

  rows(name: string): Row[] {
    const existing = this.tables.get(name);
    if (existing) return existing;
    const created: Row[] = [];
    this.tables.set(name, created);
    return created;
  }

  nextId(name: string): bigint {
    const next = (this.serial.get(name) ?? 0n) + 1n;
    this.serial.set(name, next);
    return next;
  }

  insertRow(name: string, values: Row): Row {
    const row = { id: values['id'] ?? this.nextId(name), ...values };
    this.rows(name).push(row);
    return row;
  }

  tx(): unknown {
    const project = (rows: Row[], projection?: Record<string, unknown>): Row[] => {
      if (!projection) return rows.map(row => ({ ...row }));
      const entries = Object.entries(projection);
      if (entries.some(([, value]) => value === COUNT)) return [Object.fromEntries(entries.map(([key]) => [key, rows.length]))];
      return rows.map(row => Object.fromEntries(entries.map(([key, value]) => [key, row[column(value)]])));
    };
    const select = (projection?: Record<string, unknown>) => {
      let name = '';
      let predicate: Predicate = () => true;
      const chain: Record<string, unknown> = {
        from: (table: unknown) => ((name = tableName(table)), chain),
        where: (condition: Predicate) => ((predicate = condition ?? predicate), chain),
        for: () => chain,
        orderBy: () => chain,
        limit: () => chain,
        then: (resolve: (rows: Row[]) => void) => resolve(project(this.rows(name).filter(predicate), projection)),
      };
      return chain;
    };
    const insert = (table: unknown) => {
      const name = tableName(table);
      let values: Row[] = [];
      let target: string[] | null = null;
      const run = (): Row[] => {
        const landed: Row[] = [];
        for (const value of values) {
          if (target && this.rows(name).some(row => target!.every(key => row[key] === value[key]))) continue;
          landed.push(this.insertRow(name, value));
        }
        return landed;
      };
      const chain: Record<string, unknown> = {
        values: (value: Row | Row[]) => ((values = Array.isArray(value) ? value : [value]), chain),
        onConflictDoNothing: (options: { target: unknown[] }) => ((target = options.target.map(column)), chain),
        returning: (projection?: Record<string, unknown>) => Promise.resolve(project(run(), projection)),
        then: (resolve: (value: unknown) => void) => resolve((run(), undefined)),
      };
      return chain;
    };
    const update = (table: unknown) => {
      const name = tableName(table);
      let values: Row = {};
      let predicate: Predicate = () => true;
      const run = (): Row[] => {
        const matched = this.rows(name).filter(predicate);
        for (const row of matched) Object.assign(row, values);
        return matched;
      };
      const chain: Record<string, unknown> = {
        set: (value: Row) => ((values = value), chain),
        where: (condition: Predicate) => ((predicate = condition), chain),
        returning: (projection?: Record<string, unknown>) => Promise.resolve(project(run(), projection)),
        then: (resolve: (value: unknown) => void) => resolve((run(), undefined)),
      };
      return chain;
    };
    return { select, insert, update };
  }
}

const mockPackage = (name: string, exports: Record<string, unknown>): void => {
  mock.module(name, () => exports);
  try {
    mock.module(Bun.resolveSync(name, join(src, 'modules')), () => exports);
  } catch {
    return;
  }
};
mockPackage('drizzle-orm', drizzle);
mockPackage('@shadow-library/app', { Injectable: () => () => undefined });
mockPackage('@shadow-library/common', { AppError, ValidationError, Config: { get: () => 90 }, Logger: { getLogger: () => ({ error: () => undefined }) } });
mockPackage('@shadow-library/modules', { DatabaseService: class {} });
const rules = await import(join(src, 'modules/rules/index.ts'));
mock.module('@modules/rules', () => rules);
mock.module('@server/classes', () => ({ AppErrorCode: codes }));
mock.module('@server/database', () => ({ schema }));
mock.module('@server/telemetry', () => ({ pseudoAccountId: () => 'stub', TelemetryService: class {} }));
mock.module('@server/constants', () => ({ APP_NAME: 'memoir' }));
mock.module('@modules/auth', () => ({ AccountContext: class {}, OwnerScopedRepository: class {} }));
mock.module('@modules/sync', () => ({ DeltaRepository: class {}, DeltaSourceRegistry: class {}, serializeDeltaRow: (row: unknown) => row }));
mock.module('@modules/scheduler', () => ({ SchedulerService: class {} }));
const { applyStreakTransition } = await import(join(src, 'modules/commands/apply-streak-transition.ts'));
const { HeroLedger } = await import(join(src, 'modules/commands/hero-ledger.service.ts'));
mock.module('@modules/commands', () => ({ CommandBus: class {}, HeroLedger: class {}, RolloverGate: class {}, applyStreakTransition }));
const stubModules: Record<string, Record<string, unknown>> = {
  'modules/quests/quest-log.repository.ts': { QuestLogRepository: class {} },
  'modules/quests/quest.repository.ts': { QuestRepository: class {} },
  'modules/quests/quest-streak.repository.ts': { QuestStreakRepository: class {} },
  'modules/progression/grants.repository.ts': { GrantsRepository: class {} },
  'modules/progression/progress-counters.repository.ts': { ProgressCountersRepository: class {} },
  'modules/rollover/rollover.repository.ts': { RolloverRepository: class {} },
  'modules/quick-logs/entry-cap.ts': { deriveCapAdvisory: () => ({}), serializeCapAdvisory: () => ({}) },
  'modules/quick-logs/journal.repository.ts': { JournalRepository: class {} },
  'modules/quick-logs/meal.repository.ts': { MealRepository: class {} },
  'modules/quick-logs/meal-preset.repository.ts': { MealPresetRepository: class {} },
  'modules/quick-logs/side-quest.repository.ts': { SideQuestRepository: class {} },
  'modules/quick-logs/weight.repository.ts': { WeightRepository: class {} },
  'modules/metrics/metric.repository.ts': { MetricRepository: class {} },
  'modules/metrics/metric-entry.repository.ts': { MetricEntryRepository: class {} },
  'modules/metrics/threshold-offer.ts': { findThresholdOffers: async () => [], serializeOffer: () => ({}) },
};
for (const [path, exports] of Object.entries(stubModules)) mock.module(join(src, path), () => exports);
const { ProgressionService } = await import(join(src, 'modules/progression/progression.service.ts'));
mock.module('@modules/progression', () => ({ ProgressionService: class {} }));
const { RolloverService } = await import(join(src, 'modules/rollover/rollover.service.ts'));
mock.module('@modules/rollover', () => ({ RolloverRepository: class {}, RolloverService: class {} }));
const { QuestCommandsService } = await import(join(src, 'modules/quests/quest-commands.service.ts'));
const { CompassionCommandsService } = await import(join(src, 'modules/quests/compassion-commands.service.ts'));
const { ProgressionCommandsService } = await import(join(src, 'modules/progression/progression-commands.service.ts'));
const { QuickLogsCommandsService } = await import(join(src, 'modules/quick-logs/quick-logs-commands.service.ts'));
const { MetricsCommandsService } = await import(join(src, 'modules/metrics/metrics-commands.service.ts'));

const ACCOUNT_ID = 1n;
const YIELDING_STATES = ['missed', 'rescheduled'];
const EMPTY_COUNTERS = {
  counters: { ...rules.EMPTY_PROGRESS_COUNTERS },
  lastActiveCountedDate: null as string | null,
  returnerPending: false,
};

/**
 * The repositories the handlers reach, over the same tables the fake transaction reads. Each repeats only the SQL of its reference repository: the
 * convergence upserts (`quest-log.repository.ts`), the streak write's run-start rule (`quest-streak.repository.ts`) and the `rollover_at IS NULL` guard.
 */
const world = (db: Database) => {
  const rows = (name: string) => db.rows(name);
  const account = () => rows('accounts')[0] as Row;
  const logById = (id: unknown) => rows('questLogs').find(row => row['id'] === id);
  const quests = {
    create: async (_: unknown, draft: Row) =>
      db.insertRow('quests', {
        accountId: ACCOUNT_ID,
        name: draft['name'],
        startTimeMin: draft['startTimeMinutes'],
        durationMin: draft['durationMinutes'],
        statAffinity: draft['statAffinity'],
        strictness: draft['strictness'],
        optionalStreakOptIn: draft['optionalStreakOptIn'],
        recurrence: draft['recurrence'],
        moduleLink: draft['moduleLink'],
        active: draft['active'],
        createdAt: new Date(now),
      }),
    findByIdForUpdate: async (_: unknown, id: bigint) => rows('quests').find(row => row['id'] === id) ?? null,
    update: async (_: unknown, id: bigint, patch: Row) => {
      const quest = rows('quests').find(row => row['id'] === id);
      if (!quest) return null;
      const columns: Record<string, string> = { startTimeMinutes: 'startTimeMin', durationMinutes: 'durationMin' };
      for (const [key, value] of Object.entries(patch)) if (value !== undefined) quest[columns[key] ?? key] = value;
      return quest;
    },
    softDelete: async (_: unknown, id: bigint) => {
      const quest = rows('quests').find(row => row['id'] === id);
      if (quest) quest['active'] = false;
      return quest ?? null;
    },
  };
  const upsert = (write: Row, yields: (state: unknown) => boolean, conflictSet: (write: Row) => Row) => {
    const existing = rows('questLogs').find(row => row['questId'] === write['questId'] && row['date'] === write['date']);
    if (!existing) {
      return db.insertRow('questLogs', {
        accountId: ACCOUNT_ID,
        reasonTag: null,
        reasonNote: null,
        reflectionText: null,
        rescheduledToMin: null,
        postponedToDate: null,
        performedAt: null,
        createdAt: new Date(now),
        ...write,
      });
    }
    if (!yields(existing['state'])) return null;
    return Object.assign(existing, conflictSet(write));
  };
  const questLogs = {
    findByOccurrence: async (questId: bigint, date: string) => rows('questLogs').find(row => row['questId'] === questId && row['date'] === date) ?? null,
    upsertTerminal: async (_: unknown, write: Row) =>
      upsert(
        write,
        state => YIELDING_STATES.includes(state as string),
        value => ({
          ...value,
          reasonTag: value['reasonTag'] ?? null,
          reasonNote: value['reasonNote'] ?? null,
          rescheduledToMin: value['rescheduledToMin'] ?? null,
          postponedToDate: value['postponedToDate'] ?? null,
          performedAt: value['performedAt'] ?? null,
        }),
      ),
    upsertReschedule: async (_: unknown, write: Row) =>
      upsert(
        { ...write, state: 'rescheduled', xpAwarded: 0, coinsAwarded: 0, reasonTag: null, reasonNote: null },
        state => state === 'missed',
        value => ({ state: 'rescheduled', rescheduledToMin: value['rescheduledToMin'] ?? null }),
      ),
    attachReason: async (_: unknown, id: bigint, fields: Row) => {
      const log = logById(id);
      if (!log) return null;
      for (const [key, value] of Object.entries(fields)) if (value !== undefined) log[key] = value;
      return log;
    },
    remove: async (_: unknown, id: bigint) => {
      const table = rows('questLogs');
      const index = table.findIndex(row => row['id'] === id);
      if (index < 0) return false;
      table.splice(index, 1);
      return true;
    },
    rescheduleCountInWindow: async (_: unknown, questId: bigint, from: string, to: string) =>
      rows('rescheduleEvents').filter(row => row['questId'] === questId && (row['date'] as string) >= from && (row['date'] as string) <= to).length,
    insertRescheduleEvent: async (_: unknown, values: Row) => {
      if (rows('rescheduleEvents').some(row => row['questId'] === values['questId'] && row['date'] === values['date'])) throw new CodedError('QST_001');
      db.insertRow('rescheduleEvents', { accountId: ACCOUNT_ID, reasonTag: null, reasonNote: null, ...values });
    },
  };
  const streakRow = (questId: bigint) => rows('questStreaks').find(row => row['questId'] === questId);
  const streaks = {
    readForUpdate: async (_: unknown, questId: bigint) => {
      const row = streakRow(questId);
      if (!row) return rules.EMPTY_STREAK_STATE;
      return {
        currentDays: row['currentRunDays'],
        longestDays: row['bestRunDays'],
        shields: row['shieldsAvailable'],
        completionsTowardShield: row['completionsTowardShield'],
        pendingShieldGrant: row['pendingShieldGrant'],
      };
    },
    insertShieldConsumption: async (_: unknown, questId: bigint, date: string) => {
      if (!rows('shieldConsumptions').some(row => row['questId'] === questId && row['date'] === date)) db.insertRow('shieldConsumptions', { questId, date });
    },
    write: async (_: unknown, questId: bigint, date: string, state: Row) => {
      const values = {
        currentRunDays: state['currentDays'],
        bestRunDays: state['longestDays'],
        shieldsAvailable: state['shields'],
        completionsTowardShield: state['completionsTowardShield'],
        pendingShieldGrant: state['pendingShieldGrant'],
        lastCountedDate: date,
      };
      const row = streakRow(questId);
      if (!row) {
        db.insertRow('questStreaks', { questId, ...values, runStartDate: (state['currentDays'] as number) > 0 ? date : null });
        return;
      }
      Object.assign(row, values);
      if (state['currentDays'] === 0) row['runStartDate'] = null;
      if (state['currentDays'] === 1) row['runStartDate'] = date;
    },
  };
  const dailyState = (date: string) => rows('dailyStates').find(row => row['date'] === date) ?? null;
  const dailyDefaults = (date: string): Row => ({
    accountId: ACCOUNT_ID,
    date,
    committedAt: null,
    lockedQuestIds: [],
    lockBrokenAt: null,
    comebackArmed: false,
    comebackFired: false,
    comebackFiredAt: null,
    comebackArmedViaRecovery: false,
    comebackReFired: false,
    returnerActive: false,
    returnerFired: false,
    momentumBucket: 'steady',
    missedCount: 0,
    crownXpGranted: 0,
    crownXpRemaining: 0,
    crownCoinsGranted: 0,
    crownCoinsRemaining: 0,
    crownBankedXp: null,
    crownBankedCoins: null,
    rolloverAt: null,
  });
  const rollover = {
    runSerialized: async (_: bigint, operation: (tx: unknown) => Promise<unknown>) => operation(db.tx()),
    readCurrency: async () => ({ timezone: account()['timezone'], lastHpDate: account()['lastHpDate'], deletionState: 'none' }),
    updateAccount: async (_: unknown, __: bigint, values: Row) => void Object.assign(account(), values),
    listDailyStates: async (_: unknown, __: bigint, from: string, to: string) =>
      byKeys(
        rows('dailyStates').filter(row => (row['date'] as string) >= from && (row['date'] as string) <= to),
        'date',
      ),
    upsertDailyState: async (_: unknown, values: Row) => {
      const existing = dailyState(values['date'] as string);
      if (!existing) return void db.insertRow('dailyStates', { ...dailyDefaults(values['date'] as string), ...values });
      if (existing['rolloverAt'] !== null) return;
      Object.assign(existing, values);
    },
    insertMisses: async (_: unknown, values: Row[]) =>
      values.flatMap(value =>
        rows('questLogs').some(row => row['questId'] === value['questId'] && row['date'] === value['date'])
          ? []
          : [
              db.insertRow('questLogs', {
                xpAwarded: 0,
                coinsAwarded: 0,
                reasonTag: null,
                reasonNote: null,
                reflectionText: null,
                rescheduledToMin: null,
                postponedToDate: null,
                performedAt: null,
                createdAt: new Date(now),
                ...value,
              }),
            ],
      ),
    lockStreak: async (_: unknown, __: bigint, questId: bigint) => streaks.readForUpdate(_, questId),
    lockStreaks: async (_: unknown, __: bigint, questIds: bigint[]) =>
      new Map(await Promise.all(questIds.filter(questId => streakRow(questId)).map(async questId => [questId, await streaks.readForUpdate(_, questId)] as const))),
    writeStreak: async (_: unknown, __: bigint, questId: bigint, date: string, state: Row) => streaks.write(_, questId, date, state),
    insertShieldConsumption: async (_: unknown, __: bigint, questId: bigint, date: string) => streaks.insertShieldConsumption(_, questId, date),
    listShieldedQuests: async (_: unknown, __: bigint, date: string) => new Set(rows('shieldConsumptions').filter(row => row['date'] === date).map(row => row['questId'])),
    expirePendingRecovery: async (_: unknown, __: bigint, date: string) => {
      const expired = rows('recoveryQuests').filter(row => (row['date'] as string) <= date && row['state'] === 'pending');
      for (const row of expired) row['state'] = 'expired';
      return expired;
    },
    insertRecoveryQuest: async (_: unknown, __: bigint, draft: Row) =>
      rows('recoveryQuests').some(row => row['date'] === draft['date'])
        ? null
        : db.insertRow('recoveryQuests', { accountId: ACCOUNT_ID, state: 'pending', reflectionText: null, completedAt: null, ...draft }),
    insertReturnerEvent: async (_: unknown, __: bigint, draft: Row) =>
      rows('returnerEvents').some(row => row['date'] === draft['date']) ? null : db.insertRow('returnerEvents', { ...draft }),
    lockAccount: async () => account(),
    lockDailyState: async (_: unknown, __: bigint, date: string) => dailyState(date),
    findDailyState: async (_: unknown, __: bigint, date: string) => dailyState(date),
    updateDailyStateIfOpen: async (_: unknown, __: bigint, date: string, values: Row) => {
      const state = dailyState(date);
      if (!state || state['rolloverAt'] !== null) return false;
      Object.assign(state, values);
      return true;
    },
    updateOpenDayCrownMirror: async () => undefined,
    insertComebackEvent: async (_: unknown, __: bigint, date: string, draft: Row) => {
      if (rows('comebackEvents').some(row => row['date'] === date && row['kind'] === draft['kind'])) return false;
      db.insertRow('comebackEvents', { date, xpBonus: 0, coinBonus: 0, ...draft });
      return true;
    },
    findRecoveryForDate: async (_: unknown, __: bigint, date: string) => rows('recoveryQuests').find(row => row['date'] === date) ?? null,
    completeRecoveryQuest: async (_: unknown, __: bigint, date: string, reflectionText: string | null) => {
      const recovery = rows('recoveryQuests').find(row => row['date'] === date && row['state'] === 'pending');
      if (!recovery) return null;
      return Object.assign(recovery, { state: 'completed', reflectionText, completedAt: new Date(now) });
    },
    findActivityStart: async () => {
      const dates = rows('questLogs').map(row => row['date'] as string).sort();
      const created = rows('quests').map(row => (row['createdAt'] as Date).getTime()).sort((left, right) => left - right);
      return { firstLogDate: dates[0] ?? null, firstQuestAt: created.length > 0 ? new Date(created[0]!) : null };
    },
    listQuestLogs: async (_: unknown, __: bigint, from: string, to: string) => rows('questLogs').filter(row => (row['date'] as string) >= from && (row['date'] as string) <= to),
    listActiveQuests: async () => rows('quests').filter(row => row['active'] === true),
  };
  const grants = {
    listEarnedAchievementIds: async () => rows('achievements').map(row => row['achievementId']),
    listEarnedTitleIds: async () => rows('titles').map(row => row['titleId']),
    grantAchievement: async (_: unknown, __: bigint, achievementId: string) => {
      if (rows('achievements').some(row => row['achievementId'] === achievementId)) return false;
      db.insertRow('achievements', { achievementId });
      return true;
    },
    grantTitle: async (_: unknown, __: bigint, titleId: string) => {
      if (rows('titles').some(row => row['titleId'] === titleId)) return false;
      db.insertRow('titles', { titleId });
      return true;
    },
    findUnlockedCosmetic: async (_: unknown, __: bigint, cosmeticId: string) => rows('cosmetics').find(row => row['cosmeticId'] === cosmeticId) ?? null,
    unlockCosmetic: async (_: unknown, __: bigint, cosmeticId: string, kind: string, source: string) => {
      if (rows('cosmetics').some(row => row['cosmeticId'] === cosmeticId)) return false;
      db.insertRow('cosmetics', { cosmeticId, kind, source, equipped: false });
      return true;
    },
    equipCosmetic: async (_: unknown, __: bigint, cosmeticId: string, kind: string) => {
      for (const row of rows('cosmetics')) if (row['kind'] === kind) row['equipped'] = row['cosmeticId'] === cosmeticId;
    },
  };
  let envelope = structuredClone(EMPTY_COUNTERS);
  const counters = {
    readForUpdate: async () => structuredClone(envelope),
    write: async (_: unknown, __: bigint, next: typeof EMPTY_COUNTERS) => {
      envelope = structuredClone(next);
    },
    transaction: (operation: (tx: unknown) => Promise<unknown>) => operation(db.tx()),
    snapshot: () => envelope,
  };
  const entries = (name: string) => ({
    create: async (_: unknown, draft: Row, rewarded: boolean) => db.insertRow(name, { ...draft, rewarded }),
    countInRange: async () => 0,
  });
  const presets = {
    create: async () => db.insertRow('mealPresets', { removed: false }),
    findByIdInTx: async (_: unknown, id: bigint) => {
      const preset = rows('mealPresets').find(row => row['id'] === id && row['removed'] === false);
      return preset ? { id, name: 'Oats', calories: 300, mealType: 'cooked', note: null } : null;
    },
    update: async (_: unknown, id: bigint) => rows('mealPresets').find(row => row['id'] === id && row['removed'] === false) ?? null,
    remove: async (_: unknown, id: bigint) => {
      const preset = rows('mealPresets').find(row => row['id'] === id && row['removed'] === false);
      if (preset) preset['removed'] = true;
      return preset ?? null;
    },
  };
  const weights = {
    findForDate: async (_: unknown, date: string) => rows('weights').find(row => row['date'] === date) ?? null,
    replace: async (_: unknown, date: string, kg: string) => Object.assign(rows('weights').find(row => row['date'] === date) ?? {}, { kg }),
    create: async (_: unknown, date: string, kg: string, rewarded: boolean) => db.insertRow('weights', { date, kg, rewarded, loggedAt: new Date(now) }),
    countInRange: async () => 0,
  };
  const sideQuests = {
    create: async (_: unknown, draft: Row, reward: Row) => db.insertRow('sideQuests', { ...draft, ...reward, id: draft['id'] }),
    countRewardedOn: async (_: unknown, date: string) => rows('sideQuests').filter(row => row['date'] === date && row['rewarded'] === true).length,
    countInRange: async () => 0,
  };
  const metricRow = (id: bigint) => rows('metrics').find(row => row['id'] === id) ?? null;
  const metrics = {
    ensureBuiltinsSeeded: async () => undefined,
    findByIdInTx: async (_: unknown, id: bigint) => metricRow(id),
    create: async (_: unknown, values: Row) => db.insertRow('metrics', { ...values, builtin: false, isHealth: false, active: true }),
    update: async (_: unknown, id: bigint, values: Row) => {
      const metric = metricRow(id);
      return metric ? Object.assign(metric, values) : null;
    },
    deactivate: async (_: unknown, id: bigint) => {
      const metric = metricRow(id);
      return metric ? Object.assign(metric, { active: false }) : null;
    },
  };
  const metricEntries = { register: async (_: unknown, __: bigint, entry: Row) => db.insertRow('metricEntries', entry) };
  return { quests, questLogs, streaks, rollover, grants, counters, entries, presets, weights, sideQuests, metrics, metricEntries };
};

type Handler = (context: unknown) => Promise<{ status: string; result: Row }>;
const services = (db: Database) => {
  const store = world(db);
  const handlers = new Map<string, Handler>();
  const bus = { registerHandler: (type: string, handler: Handler) => handlers.set(type, handler) };
  const registry = { register: () => undefined };
  const telemetry = { emit: () => undefined };
  const heroLedger = new HeroLedger(telemetry);
  const progression = new ProgressionService(store.counters, store.grants, heroLedger);
  const rolloverService = new RolloverService(store.rollover, heroLedger, progression, {}, registry, {}, {});
  new QuestCommandsService(
    bus,
    heroLedger,
    progression,
    store.quests,
    store.questLogs,
    store.streaks,
    store.rollover,
    rolloverService,
    registry,
    {},
  ).onModuleInit();
  new CompassionCommandsService(bus, heroLedger, store.rollover, progression).onModuleInit();
  new ProgressionCommandsService(bus, heroLedger, store.grants, store.counters, { getAccountId: () => ACCOUNT_ID }, registry, {}).onModuleInit();
  new QuickLogsCommandsService(
    bus,
    heroLedger,
    store.entries('journals'),
    store.entries('meals'),
    store.presets,
    store.weights,
    store.sideQuests,
    telemetry,
  ).onModuleInit();
  new MetricsCommandsService(bus, store.metrics, store.metricEntries, telemetry).onModuleInit();
  return { handlers, store, rolloverService };
};

/** A step as both sides read it: the native payload with `@name` standing for an id, the occurrence, and the instant it is issued at. */
interface Step {
  at: string;
  /** The offset the native command is stamped with, when it is not the scenario's. */
  offsetMinutes?: number;
  /** A command that reaches the reference late: its server handles it at `processedAt`, and the issuing device stamped it with the open day it knew. */
  processedAt?: string;
  issuerOpenDay?: string | null;
  type: string;
  occurrence?: { quest: string; date: string };
  payload?: JsonObject;
}
interface Scenario {
  id: string;
  source: string;
  timeZone: string;
  offsetMinutes: number;
  /** The reference's rollover gate runs before every step, as `RolloverGate` runs it before every command, and native replay walks the days. */
  walk?: boolean;
  steps: Step[];
}

/** The reference sets these through `PATCH /account`, staging the zone and intensity (`account.service.ts:137-139`); native replay has them as commands. */
const SETTINGS: Record<string, { key: string; column: string }> = {
  'account.setTimeZone': { key: 'timezone', column: 'pendingTimezone' },
  'account.setIntensityMode': { key: 'intensityMode', column: 'pendingIntensityMode' },
  'account.setReturnerThreshold': { key: 'returnerThresholdDays', column: 'returnerThresholdDays' },
};
const BUILTIN_METRICS = ['steps', 'active_energy', 'workout_minutes', 'weight', 'resting_heart_rate', 'sleep', 'waist_circumference', 'water'];

/** A quest or preset no step created, as the reference's digit-string id. */
const UNKNOWN_ID = '999';
const NOTE = 'Felt tired after work';
const REFLECTION = 'Rested and ready again';

/** The native payload as the reference's wire payload: digit-string ids, the occurrence as `occurrenceId`, and the texts and content put back. */
const toReference = (step: Step, ids: Map<string, bigint>, builtins: Map<string, bigint>): JsonObject => {
  const id = (value: Json | undefined): Json => {
    if (typeof value !== 'string' || !value.startsWith('@')) return value ?? null;
    const known = ids.get(value) ?? builtins.get(value);
    return known === undefined ? UNKNOWN_ID : String(known);
  };
  const payload = step.payload ?? {};
  const texts = (object: JsonObject): JsonObject => ({
    ...object,
    ...(object['note'] === true ? { note: NOTE } : {}),
    ...(object['reflectionText'] === true ? { reflectionText: REFLECTION } : {}),
  });
  const occurrenceId = step.occurrence ? { occurrenceId: `${id(`@${step.occurrence.quest}`)}:${step.occurrence.date}` } : {};
  switch (step.type) {
    case 'quest.create': {
      const { questId: _questId, ...draft } = payload;
      return { name: 'A quest', ...draft };
    }
    case 'quest.update':
    case 'quest.delete':
      return { ...payload, questId: id(payload['questId']) };
    case 'plan.setLock':
      return Array.isArray(payload['questIds']) ? { ...payload, questIds: payload['questIds'].map(id) } : payload;
    case 'journal.save':
      return { ...payload, draft: { text: 'A good day', ...(payload['draft'] as JsonObject) } };
    case 'meal.log':
      return { ...payload, draft: { name: 'Oats', calories: 300, mealType: 'cooked', ...(payload['draft'] as JsonObject) } };
    case 'metric.create':
      return { name: `Metric ${payload['id']}`, valueType: 'count', direction: 'higher' };
    case 'metric.update':
      return { id: id(payload['id']), name: 'Renamed' };
    case 'metric.delete':
      return { id: id(payload['id']), ...(payload['detach'] === undefined ? {} : { detach: payload['detach'] }) };
    case 'metric.register':
      return { metricId: id(payload['metricId']), date: payload['date'] ?? null, value: 72 };
    case 'meal.savePreset':
      return { preset: { name: 'Oats', calories: 300, mealType: 'cooked' } };
    case 'meal.logPreset':
      return { ...payload, presetId: id(payload['presetId']) };
    case 'weight.save':
      return { kg: 72.5, ...payload };
    case 'sidequest.log':
      return { ...payload, draft: { name: 'Helped a neighbour', ...(payload['draft'] as JsonObject) } };
    default:
      return { ...texts(payload), ...occurrenceId };
  }
};

const symbolOf = (ids: Map<string, bigint>, value: unknown): string | null => {
  if (value === null || value === undefined) return null;
  for (const [name, id] of ids) if (id === value) return name.slice(1);
  return String(value);
};
const iso = (instant: string): number => {
  const millis = Date.parse(instant);
  if (Number.isNaN(millis)) throw new Error(`${instant} is not an instant`);
  return millis;
};

/** Seeds stand for what the day walk writes, which these scenarios do not run: open days, misses, Recovery quests, the open day and a coin balance. */
const seed = (db: Database, step: Step, ids: Map<string, bigint>, scenario: Scenario): void => {
  const payload = step.payload ?? {};
  switch (step.type) {
    case 'seed.day': {
      const date = payload['date'] as string;
      db.insertRow('dailyStates', {
        accountId: ACCOUNT_ID,
        date,
        intensityMode: payload['intensityMode'] ?? 'standard',
        rolloverAt: payload['closed'] === true ? new Date(now) : null,
        committedAt: null,
        lockedQuestIds: [],
        lockBrokenAt: null,
        comebackArmed: payload['comebackArmed'] === true,
        comebackFired: false,
        comebackFiredAt: null,
        comebackArmedViaRecovery: false,
        comebackReFired: false,
        momentumBucket: payload['momentum'] ?? 'steady',
        crownXpGranted: 0,
        crownXpRemaining: 0,
        crownCoinsGranted: 0,
        crownCoinsRemaining: 0,
        crownPeriodStart: date,
      });
      return;
    }
    case 'seed.recovery':
      db.insertRow('recoveryQuests', {
        date: payload['date'],
        state: 'pending',
        sourceQuestId: payload['sourceQuest'] ? (ids.get(payload['sourceQuest'] as string) ?? null) : null,
        triggerLogIds: [],
      });
      return;
    case 'seed.miss': {
      const questId = ids.get(`@${step.occurrence!.quest}`)!;
      const quest = db.rows('quests').find(row => row['id'] === questId)!;
      const ruleset = rules.currentRuleset();
      db.insertRow('questLogs', {
        accountId: ACCOUNT_ID,
        questId,
        date: step.occurrence!.date,
        state: 'missed',
        xpAwarded: 0,
        coinsAwarded: 0,
        statAffinity: quest['statAffinity'],
        strictness: quest['strictness'],
        intensityModeAtLog: 'standard',
        crownSliceWeight: ruleset.strictness[quest['strictness'] as string].crownWeight.toFixed(2),
        rulesetVersion: ruleset.version,
        reasonTag: null,
        reasonNote: null,
        reflectionText: null,
        rescheduledToMin: null,
        postponedToDate: null,
        performedAt: null,
        createdAt: new Date(now),
      });
      return;
    }
    case 'seed.openDay':
      (db.rows('accounts')[0] as Row)['lastHpDate'] = payload['date'];
      return;
    case 'seed.coins':
      (db.rows('accounts')[0] as Row)['coins'] = payload['coins'];
      return;
    case 'seed.returnerShields':
      (db.rows('accounts')[0] as Row)['pendingReturnerShields'] = payload['shields'];
      return;
    default:
      throw new Error(`${scenario.id}: unknown seed ${step.type}`);
  }
};

const run = async (scenario: Scenario): Promise<JsonObject> => {
  const db = new Database();
  db.insertRow('accounts', {
    id: ACCOUNT_ID,
    timezone: scenario.timeZone,
    intensityMode: 'standard',
    lastHpDate: null,
    level: 1,
    totalXp: 0n,
    coins: 0,
    statDiscipline: 0,
    statBody: 0,
    statWealth: 0,
    statMind: 0,
    pendingReturnerShields: 0,
    displayedTitleId: null,
    lastActiveDate: null,
    returnerThresholdDays: 7,
    pendingTimezone: null,
    pendingIntensityMode: null,
    deletionState: 'none',
  });
  const ids = new Map<string, bigint>();
  const builtins = new Map(BUILTIN_METRICS.map(name => [`@builtin-${name}`, db.insertRow('metrics', { builtin: true, isHealth: true, active: true, name })['id'] as bigint]));
  const { handlers, store, rolloverService } = services(db);
  const logOccurrences = new Map<bigint, string>();
  const recoveryDates = new Map<bigint, string>();
  const outcomes: Json[] = [];

  const remember = (): void => {
    for (const log of db.rows('questLogs')) logOccurrences.set(log['id'] as bigint, `${symbolOf(ids, log['questId'])}:${log['date']}`);
    for (const recovery of db.rows('recoveryQuests')) recoveryDates.set(recovery['id'] as bigint, recovery['date'] as string);
  };

  for (const [index, step] of scenario.steps.entries()) {
    now = iso(step.at);
    if (step.type.startsWith('seed.')) {
      seed(db, step, ids, scenario);
      outcomes.push({ status: 'seed' });
      continue;
    }
    if (scenario.walk) await rolloverService.catchUp(ACCOUNT_ID);
    remember();
    if (step.type === 'horizon') {
      outcomes.push({ status: 'horizon' });
      continue;
    }
    const setting = SETTINGS[step.type];
    if (setting) {
      (db.rows('accounts')[0] as Row)[setting.column] = step.payload?.[setting.key] ?? null;
      outcomes.push({ status: 'applied' });
      continue;
    }
    const handler = handlers.get(step.type);
    if (!handler) throw new Error(`${scenario.id}: no reference handler for ${step.type}`);
    const account = db.rows('accounts')[0] as Row;
    const issuerOpenDay = step.issuerOpenDay === undefined ? account['lastHpDate'] : step.issuerOpenDay;
    const localDate = rules.formatLocalDate(rules.accountToday(now, account['timezone'], issuerOpenDay));
    if (step.processedAt) now = iso(step.processedAt);
    const capacityBefore = step.type === 'plan.setLock' && step.payload?.['locked'] === true;
    try {
      const outcome = await handler({ accountId: ACCOUNT_ID, tx: db.tx(), envelope: { commandId: `c${index}`, type: step.type, payload: toReference(step, ids, builtins), localDate } });
      if (step.type === 'quest.create') ids.set(step.payload!['questId'] as string, BigInt(outcome.result['id'] as string));
      if (step.type === 'metric.create') ids.set(step.payload!['id'] as string, BigInt(outcome.result['id'] as string));
      if (step.type === 'meal.savePreset') ids.set(step.payload!['id'] as string, BigInt(outcome.result['id'] as string));
      const result: JsonObject = { status: outcome.status };
      if (outcome.status === 'rejected') result['rejection'] = outcome.result['kind'] as string;
      if (capacityBefore && outcome.status === 'applied') {
        result['capacity'] = outcome.result['capacity'] as number;
        result['capacityWarning'] = outcome.result['capacityWarning'] as string;
      }
      outcomes.push(result);
    } catch (error) {
      if (error instanceof CodedError) outcomes.push({ status: 'refused', code: error.code });
      else throw new Error(`${scenario.id} step ${index} (${step.type}) crashed: ${(error as Error).stack}`);
    }
    remember();
  }
  return { ...scenario, expected: { steps: outcomes, state: snapshot(db, store, ids, logOccurrences, recoveryDates) } } as unknown as JsonObject;
};

const byKeys = <T extends Row>(rows: T[], ...keys: string[]): T[] =>
  [...rows].sort((left, right) => {
    for (const key of keys) {
      const a = String(left[key]);
      const b = String(right[key]);
      if (a !== b) return a < b ? -1 : 1;
    }
    return 0;
  });

/** The reference's ledger keys name its serial log and Recovery ids; the snapshot names the occurrence or day instead, as the native keys can be read. */
const normalizedKey = (key: string, logOccurrences: Map<bigint, string>, recoveryDates: Map<bigint, string>): string => {
  const xp = /^(\d+)_xp$/.exec(key);
  if (xp) return `xp:${logOccurrences.get(BigInt(xp[1]!))}`;
  const recovery = /^recovery_(completed|expired)_(\d+)$/.exec(key);
  if (recovery) return `recovery_${recovery[1]}:${recoveryDates.get(BigInt(recovery[2]!))}`;
  const forfeit = /^crownforfeit_(\d+)$/.exec(key);
  if (forfeit) return `crownforfeit:${logOccurrences.get(BigInt(forfeit[1]!))}`;
  return key;
};

const snapshot = (db: Database, store: ReturnType<typeof world>, ids: Map<string, bigint>, logOccurrences: Map<bigint, string>, recoveryDates: Map<bigint, string>): Json => {
  const account = db.rows('accounts')[0] as Row;
  const envelope = store.counters.snapshot();
  const sym = (value: unknown) => symbolOf(ids, value);
  return {
    hero: {
      totalXP: Number(account['totalXp']),
      level: account['level'] as number,
      coins: account['coins'] as number,
      stats: { discipline: account['statDiscipline'], body: account['statBody'], wealth: account['statWealth'], mind: account['statMind'] } as JsonObject,
    },
    events: db.rows('heroEvents').map(event => ({
      key: normalizedKey(event['dedupeKey'] as string, logOccurrences, recoveryDates),
      type: event['type'] as string,
      date: event['date'] as string,
      xp: event['xpDelta'] as number,
      coins: event['coinsDelta'] as number,
      stat: (event['statAffinity'] as string | null) ?? null,
      statDelta: event['statDelta'] as number,
      quest: sym(event['questId']),
      state: (event['state'] as string | null) ?? null,
      levelAfter: event['levelAfter'] as number,
    })),
    logs: byKeys(db.rows('questLogs'), 'questId', 'date').map(log => ({
      quest: sym(log['questId']),
      date: log['date'] as string,
      state: log['state'] as string,
      xp: log['xpAwarded'] as number,
      coins: log['coinsAwarded'] as number,
      strictness: log['strictness'] as string,
      stat: log['statAffinity'] as string,
      intensityMode: log['intensityModeAtLog'] as string,
      crownHalves: Math.round(Number(log['crownSliceWeight']) * 2),
      reasonTag: (log['reasonTag'] as string | null) ?? null,
      hasNote: log['reasonNote'] !== null && log['reasonNote'] !== undefined,
      hasReflection: log['reflectionText'] !== null && log['reflectionText'] !== undefined,
      rescheduledToMin: (log['rescheduledToMin'] as number | null) ?? null,
      postponedToDate: (log['postponedToDate'] as string | null) ?? null,
    })),
    reschedules: byKeys(db.rows('rescheduleEvents'), 'questId', 'date').map(event => ({
      quest: sym(event['questId']),
      date: event['date'] as string,
      fromMin: (event['fromMin'] as number | null) ?? null,
      toMin: event['toMin'] as number,
      reasonTag: (event['reasonTag'] as string | null) ?? null,
      hasNote: event['reasonNote'] !== null,
    })),
    streaks: byKeys(db.rows('questStreaks'), 'questId').map(streak => ({
      quest: sym(streak['questId']),
      currentDays: streak['currentRunDays'] as number,
      longestDays: streak['bestRunDays'] as number,
      shields: streak['shieldsAvailable'] as number,
      completionsTowardShield: streak['completionsTowardShield'] as number,
      pendingShieldGrant: streak['pendingShieldGrant'] as number,
      runStartDate: (streak['runStartDate'] as string | null) ?? null,
      lastCountedDate: streak['lastCountedDate'] as string,
    })),
    shieldConsumptions: byKeys(db.rows('shieldConsumptions'), 'questId', 'date').map(row => `${sym(row['questId'])}:${row['date']}`),
    counters: { ...(envelope.counters as JsonObject), lastActiveCountedDate: envelope.lastActiveCountedDate, returnerPending: envelope.returnerPending },
    achievements: db.rows('achievements').map(row => row['achievementId'] as string),
    titles: db.rows('titles').map(row => row['titleId'] as string),
    cosmetics: byKeys(db.rows('cosmetics'), 'cosmeticId').map(row => ({ id: row['cosmeticId'] as string, source: row['source'] as string, equipped: row['equipped'] as boolean })),
    displayedTitle: (account['displayedTitleId'] as string | null) ?? null,
    pendingReturnerShields: account['pendingReturnerShields'] as number,
    openDay: (account['lastHpDate'] as string | null) ?? null,
    lastActiveDate: (account['lastActiveDate'] as string | null) ?? null,
    days: byKeys(db.rows('dailyStates'), 'date').map(day => ({
      date: day['date'] as string,
      closed: day['rolloverAt'] !== null && day['rolloverAt'] !== undefined,
      intensityMode: day['intensityMode'] as string,
      hp: day['hpStart'] === undefined ? null : { start: day['hpStart'] as number, end: day['hpEnd'] as number, max: day['hpMax'] as number },
      missedCount: (day['missedCount'] as number | undefined) ?? 0,
      momentum: (day['momentumBucket'] as string | undefined) ?? 'steady',
      returnerFired: (day['returnerFired'] as boolean | undefined) ?? false,
      banked: day['crownBankedXp'] === null || day['crownBankedXp'] === undefined ? null : { xp: day['crownBankedXp'] as number, coins: day['crownBankedCoins'] as number },
      lock:
        day['committedAt'] === null
          ? null
          : { quests: (day['lockedQuestIds'] as bigint[]).map(id => sym(id) as string), broken: day['lockBrokenAt'] !== null },
      comeback: {
        armed: day['comebackArmed'] as boolean,
        fires: (day['comebackFired'] ? 1 : 0) + (day['comebackReFired'] ? 1 : 0),
        armedViaRecovery: day['comebackArmedViaRecovery'] as boolean,
      },
      crown: {
        grantedXP: day['crownXpGranted'] as number,
        remainingXP: day['crownXpRemaining'] as number,
        grantedCoins: day['crownCoinsGranted'] as number,
        remainingCoins: day['crownCoinsRemaining'] as number,
        periodStart: day['crownPeriodStart'] as string,
      },
    })),
    comebackEvents: byKeys(db.rows('comebackEvents'), 'date', 'kind').map(event => ({
      date: event['date'] as string,
      kind: event['kind'] as string,
      xpBonus: event['xpBonus'] as number,
      coinBonus: event['coinBonus'] as number,
    })),
    recoveries: byKeys(db.rows('recoveryQuests'), 'date').map(recovery => ({
      date: recovery['date'] as string,
      state: recovery['state'] as string,
      sourceQuest: sym(recovery['sourceQuestId']),
      triggers: ((recovery['triggerLogIds'] as bigint[] | undefined) ?? []).map(id => logOccurrences.get(id) ?? String(id)),
      isReturnerDay: (recovery['isReturnerDay'] as boolean | undefined) ?? false,
    })),
    returnerEvents: byKeys(db.rows('returnerEvents'), 'date').map(event => ({
      date: event['date'] as string,
      lastActiveDate: event['lastActiveDate'] as string,
      daysAbsent: event['daysAbsent'] as number,
      shieldTarget: sym(event['shieldTargetQuestId']),
      shieldPending: event['shieldPending'] as boolean,
    })),
    metrics: byKeys(
      db.rows('metrics').filter(metric => metric['builtin'] !== true),
      'id',
    ).map(metric => ({ id: sym(metric['id']) as string, active: metric['active'] as boolean })),
    quickLogs: byKeys([...db.rows('journals'), ...db.rows('meals'), ...db.rows('sideQuests')], 'id').map(entry => ({
      entry: String(entry['id']).slice(1),
      rewarded: entry['rewarded'] as boolean,
    })),
  };
};

// Scenario helpers: native payloads, with `@name` for a quest, preset or entry id.
const daily = (startDate: string): JsonObject => ({ frequency: 'daily', interval: 1, startDate, end: { kind: 'never' } });
const weekly = (startDate: string, daysOfWeek: number[]): JsonObject => ({ frequency: 'weekly', interval: 1, startDate, end: { kind: 'never' }, daysOfWeek });
const create = (at: string, quest: string, schedule: JsonObject): Step => ({
  at,
  type: 'quest.create',
  payload: { questId: `@${quest}`, statAffinity: 'body', recurrence: daily('2026-01-01'), ...schedule },
});
const act = (at: string, type: string, quest: string, date: string, payload: JsonObject = {}): Step => ({ at, type, occurrence: { quest, date }, payload });
const command = (at: string, type: string, payload: JsonObject = {}): Step => ({ at, type, payload });
const seedStep = (at: string, type: string, payload: JsonObject = {}, occurrence?: { quest: string; date: string }): Step => ({
  at,
  type: `seed.${type}`,
  payload,
  ...(occurrence ? { occurrence } : {}),
});
const ROUTINE = { strictness: 'routine', startTimeMinutes: 480, durationMinutes: 60 };
const ANCHOR = { strictness: 'anchor', startTimeMinutes: 420, durationMinutes: 30 };
const utc = (id: string, source: string, steps: Step[]): Scenario => ({ id, source, timeZone: 'UTC', offsetMinutes: 0, steps });
const repeat = <T>(count: number, make: (index: number) => T): T[] => Array.from({ length: count }, (_, index) => make(index));
const day = (base: string, offset: number): string => rules.formatLocalDate(rules.addDays(rules.parseLocalDate(base), offset));
const walked = (id: string, source: string, steps: Step[], timeZone = 'UTC', offsetMinutes = 0): Scenario => ({ id, source, timeZone, offsetMinutes, walk: true, steps });
const horizon = (at: string, offsetMinutes?: number): Step => ({ at, type: 'horizon', ...(offsetMinutes === undefined ? {} : { offsetMinutes }) });
const stamped = (step: Step, offsetMinutes: number): Step => ({ ...step, offsetMinutes });
const ROLLOVER_SPEC = 'tests/rollover/rollover.service.spec.ts';

const scenarios: Scenario[] = [
  ...['quest.complete', 'quest.partial', 'quest.skip'].map(type =>
    utc(`day-stamp-refuses-tomorrow-${type}`, 'tests/quests/day-stamp.spec.ts', [
      create('2026-03-01T08:00:00Z', 'q1', ROUTINE),
      act('2026-03-10T12:00:00Z', type, 'q1', '2026-03-11'),
    ]),
  ),
  ...['quest.complete', 'quest.skip'].map(type =>
    utc(`day-stamp-admits-today-and-earlier-${type}`, 'tests/quests/day-stamp.spec.ts', [
      create('2026-03-01T08:00:00Z', 'q1', ROUTINE),
      act('2026-03-10T12:00:00Z', type, 'q1', '2026-03-10'),
      act('2026-03-10T12:00:01Z', type, 'q1', '2026-03-08'),
    ]),
  ),
  utc('day-stamp-five-minute-skew', 'tests/quests/day-stamp.spec.ts', [
    create('2026-03-01T08:00:00Z', 'q1', ROUTINE),
    act('2026-03-10T23:54:59Z', 'quest.complete', 'q1', '2026-03-11'),
    act('2026-03-10T23:55:00Z', 'quest.complete', 'q1', '2026-03-11'),
    act('2026-03-10T23:59:59Z', 'quest.complete', 'q1', '2026-03-12'),
  ]),
  utc('recovery-completes-once', 'tests/quests/compassion-commands.service.spec.ts', [
    create('2026-03-01T08:00:00Z', 'q1', ANCHOR),
    seedStep('2026-03-10T00:00:00Z', 'day', { date: '2026-03-10' }),
    seedStep('2026-03-10T00:00:00Z', 'openDay', { date: '2026-03-10' }),
    seedStep('2026-03-10T00:00:00Z', 'recovery', { date: '2026-03-10', sourceQuest: '@q1' }),
    command('2026-03-10T12:00:00Z', 'recovery.complete', { reflectionText: true }),
    command('2026-03-10T12:30:00Z', 'recovery.complete'),
    command('2026-03-11T12:30:00Z', 'recovery.complete'),
  ]),
  utc('lock-capacity-counts-empty-days', 'tests/quests/lock-capacity.spec.ts', [
    ...repeat(3, index => create('2026-03-17T08:00:00Z', `q${index + 1}`, ROUTINE)),
    ...repeat(3, index => act('2026-03-19T08:30:00Z', 'quest.complete', `q${index + 1}`, '2026-03-19')),
    seedStep('2026-03-20T00:00:00Z', 'day', { date: '2026-03-20' }),
    command('2026-03-20T12:00:00Z', 'plan.setLock', { locked: true, questIds: ['@q1'] }),
  ]),
  utc('lock-capacity-whole-empty-window', 'tests/quests/lock-capacity.spec.ts', [
    create('2026-02-01T08:00:00Z', 'q1', ROUTINE),
    seedStep('2026-03-20T00:00:00Z', 'day', { date: '2026-03-20' }),
    command('2026-03-20T12:00:00Z', 'plan.setLock', { locked: true, questIds: ['@q1'] }),
  ]),
  utc('lock-capacity-days-since-the-account-began', 'tests/quests/lock-capacity.spec.ts', [
    ...repeat(4, index => create('2026-03-18T07:00:00Z', `q${index + 1}`, ROUTINE)),
    ...repeat(4, index => act('2026-03-18T08:30:00Z', 'quest.complete', `q${index + 1}`, '2026-03-18')),
    ...repeat(4, index => act('2026-03-19T08:30:00Z', 'quest.complete', `q${index + 1}`, '2026-03-19')),
    seedStep('2026-03-20T00:00:00Z', 'day', { date: '2026-03-20' }),
    command('2026-03-20T12:00:00Z', 'plan.setLock', { locked: true, questIds: ['@q1', '@q2'] }),
  ]),
  utc('lock-capacity-new-owner-baseline', 'tests/quests/lock-capacity.spec.ts', [
    create('2026-03-20T08:00:00Z', 'q1', ROUTINE),
    seedStep('2026-03-20T08:00:00Z', 'day', { date: '2026-03-20' }),
    command('2026-03-20T12:00:00Z', 'plan.setLock', { locked: true, questIds: ['@q1'] }),
  ]),
  utc('reschedule-window-counts-the-seven-days-ending-on-the-occurrence', 'tests/quests/reschedule-window.spec.ts', [
    create('2026-03-01T08:00:00Z', 'q1', ROUTINE),
    act('2026-03-03T07:00:00Z', 'quest.reschedule', 'q1', '2026-03-03', { toMin: 600 }),
    act('2026-03-12T07:00:00Z', 'quest.reschedule', 'q1', '2026-03-12', { toMin: 600 }),
    act('2026-03-07T07:00:00Z', 'quest.reschedule', 'q1', '2026-03-07', { toMin: 600, reasonTag: 'travel' }),
    act('2026-03-09T07:00:00Z', 'quest.reschedule', 'q1', '2026-03-09', { toMin: 660, note: true }),
    act('2026-03-10T07:00:00Z', 'quest.reschedule', 'q1', '2026-03-10', { toMin: 600 }),
    act('2026-03-10T07:01:00Z', 'quest.reschedule', 'q1', '2026-03-10', { toMin: 600, acceptBeyondCap: true, reasonTag: 'forgot' }),
    act('2026-03-12T07:01:00Z', 'quest.reschedule', 'q1', '2026-03-12', { toMin: 700 }),
  ]),
  utc('honest-planner-counts-ninety-days', 'tests/quests/reschedule-window.spec.ts', [
    ...repeat(5, index => create('2025-11-01T08:00:00Z', `q${index + 1}`, { ...ROUTINE, recurrence: daily('2025-11-01') })),
    act('2025-12-10T07:00:00Z', 'quest.reschedule', 'q5', '2025-12-10', { toMin: 600, reasonTag: 'travel' }),
    ...repeat(4, index => act('2026-03-01T07:00:00Z', 'quest.reschedule', `q${index + 1}`, '2026-03-01', { toMin: 600, reasonTag: 'travel' })),
    ...repeat(4, index => act('2026-03-03T07:00:00Z', 'quest.reschedule', `q${index + 1}`, '2026-03-03', { toMin: 600, note: true })),
    act('2026-03-10T07:00:00Z', 'quest.reschedule', 'q5', '2026-03-10', { toMin: 600, reasonTag: 'other' }),
    act('2026-03-11T07:00:00Z', 'quest.reschedule', 'q5', '2026-03-11', { toMin: 600, reasonTag: 'other' }),
  ]),
  ...[
    ['backward-zone-open-day', '2026-03-11'],
    ['ordinary-zone-day', '2026-03-10'],
  ].map(([name, openDay]) =>
    utc(`quick-log-day-${name}`, 'tests/quick-logs/quick-log-day.spec.ts', [
      seedStep('2026-03-10T00:00:00Z', 'openDay', { date: openDay! }),
      command('2026-03-10T20:00:00Z', 'sidequest.log', { id: '@s1', draft: { date: '2026-03-11' } }),
      command('2026-03-10T20:00:01Z', 'sidequest.log', { id: '@s2', draft: { date: '2026-03-10' } }),
      command('2026-03-10T20:00:02Z', 'journal.save', { id: '@j1', draft: { date: openDay! } }),
    ]),
  ),
  utc('anchor-bands-streak-and-shield', 'scenario', [
    create('2026-03-01T06:00:00Z', 'q1', ANCHOR),
    ...repeat(7, index => act(`${day('2026-03-02', index)}T07:10:00Z`, 'quest.complete', 'q1', day('2026-03-02', index))),
    act('2026-03-09T08:00:00Z', 'quest.complete', 'q1', '2026-03-09'),
    act('2026-03-10T10:00:00Z', 'quest.complete', 'q1', '2026-03-10'),
    act('2026-03-11T07:00:00Z', 'quest.partial', 'q1', '2026-03-11'),
    act('2026-03-14T07:00:00Z', 'quest.complete', 'q1', '2026-03-12'),
    act('2026-03-14T07:05:00Z', 'quest.skip', 'q1', '2026-03-13', { reasonTag: 'too_tired' }),
    act('2026-03-14T07:10:00Z', 'quest.skip', 'q1', '2026-03-14'),
  ]),
  utc('comeback-fires-and-re-fires-after-recovery', 'scenario', [
    create('2026-03-01T06:00:00Z', 'q1', ANCHOR),
    create('2026-03-01T06:00:00Z', 'q2', ROUTINE),
    create('2026-03-01T06:00:00Z', 'q3', { strictness: 'goal' }),
    create('2026-03-01T06:00:00Z', 'q4', { ...ANCHOR, startTimeMinutes: 600 }),
    seedStep('2026-03-10T00:00:00Z', 'day', { date: '2026-03-10', comebackArmed: true, momentum: 'cold' }),
    seedStep('2026-03-10T00:00:00Z', 'openDay', { date: '2026-03-10' }),
    seedStep('2026-03-10T00:00:00Z', 'recovery', { date: '2026-03-10', sourceQuest: '@q1' }),
    act('2026-03-10T07:05:00Z', 'quest.complete', 'q3', '2026-03-10'),
    act('2026-03-10T07:10:00Z', 'quest.complete', 'q1', '2026-03-10'),
    act('2026-03-10T08:10:00Z', 'quest.complete', 'q2', '2026-03-10'),
    command('2026-03-10T09:00:00Z', 'recovery.complete'),
    act('2026-03-10T10:05:00Z', 'quest.complete', 'q4', '2026-03-10'),
    act('2026-03-11T07:10:00Z', 'quest.complete', 'q1', '2026-03-11'),
    act('2026-03-10T09:10:00Z', 'quest.skip', 'q2', '2026-03-09'),
  ]),
  utc('lock-bonus-broken-by-postpone', 'scenario', [
    create('2026-03-01T06:00:00Z', 'q1', ANCHOR),
    create('2026-03-01T06:00:00Z', 'q2', ROUTINE),
    create('2026-03-01T06:00:00Z', 'q3', ROUTINE),
    command('2026-03-02T06:00:00Z', 'quest.delete', { questId: '@q3' }),
    seedStep('2026-03-10T00:00:00Z', 'day', { date: '2026-03-10' }),
    seedStep('2026-03-11T00:00:00Z', 'day', { date: '2026-03-11', closed: true }),
    seedStep('2026-03-10T00:00:00Z', 'openDay', { date: '2026-03-10' }),
    command('2026-03-10T06:00:00Z', 'plan.setLock', { locked: true, questIds: ['@q1', '@q3'] }),
    command('2026-03-10T06:01:00Z', 'plan.setLock', { locked: true, questIds: ['@q1', '@q2'] }),
    act('2026-03-10T07:05:00Z', 'quest.complete', 'q1', '2026-03-10'),
    act('2026-03-10T08:05:00Z', 'quest.postpone', 'q2', '2026-03-10', { reasonTag: 'schedule_conflict', note: true }),
    act('2026-03-10T08:06:00Z', 'quest.complete', 'q2', '2026-03-10'),
    seedStep('2026-03-11T00:00:00Z', 'openDay', { date: '2026-03-11' }),
    command('2026-03-11T06:00:00Z', 'plan.setLock', { locked: false }),
  ]),
  utc('first-terminal-wins-and-yields', 'scenario', [
    create('2026-03-01T06:00:00Z', 'q1', ROUTINE),
    create('2026-03-01T06:00:00Z', 'q2', ROUTINE),
    act('2026-03-10T08:10:00Z', 'quest.complete', 'q1', '2026-03-10'),
    act('2026-03-10T08:11:00Z', 'quest.skip', 'q1', '2026-03-10'),
    act('2026-03-10T08:12:00Z', 'quest.reschedule', 'q1', '2026-03-10', { toMin: 900 }),
    seedStep('2026-03-11T00:00:00Z', 'miss', {}, { quest: 'q2', date: '2026-03-09' }),
    seedStep('2026-03-11T00:00:00Z', 'miss', {}, { quest: 'q2', date: '2026-03-08' }),
    act('2026-03-11T09:00:00Z', 'quest.complete', 'q2', '2026-03-09'),
    act('2026-03-11T09:01:00Z', 'quest.reschedule', 'q2', '2026-03-08', { toMin: 900 }),
    act('2026-03-11T09:02:00Z', 'quest.complete', 'q2', '2026-03-08'),
    act('2026-03-11T09:03:00Z', 'quest.skip', 'q2', '2026-03-08'),
  ]),
  utc('log-reasons-edit-window-and-deletion', 'scenario', [
    create('2026-03-01T06:00:00Z', 'q1', ROUTINE),
    act('2026-03-02T08:10:00Z', 'quest.skip', 'q1', '2026-03-02', { reasonTag: 'forgot', note: true }),
    act('2026-03-03T08:10:00Z', 'quest.attachReason', 'q1', '2026-03-02', { reasonTag: 'too_tired' }),
    act('2026-03-04T08:10:00Z', 'quest.editLog', 'q1', '2026-03-02', { note: true }),
    act('2026-03-05T08:10:00Z', 'quest.editLog', 'q1', '2026-03-02', { reflectionText: true, reasonTag: null }),
    act('2026-03-09T08:11:00Z', 'quest.attachReason', 'q1', '2026-03-02', { note: true }),
    act('2026-03-09T08:12:00Z', 'quest.attachReason', 'q1', '2026-03-05', { reasonTag: 'other' }),
    act('2026-03-10T08:12:00Z', 'quest.complete', 'q1', '2026-03-10'),
    act('2026-03-10T08:13:00Z', 'quest.deleteLog', 'q1', '2026-03-10'),
    act('2026-03-10T08:14:00Z', 'quest.deleteLog', 'q1', '2026-03-10'),
    act('2026-03-10T08:15:00Z', 'quest.complete', 'q1', '2026-03-10'),
    act('2026-03-20T08:15:00Z', 'quest.deleteLog', 'q1', '2026-03-02'),
  ]),
  utc('occurrence-refusals', 'scenario', [
    create('2026-03-01T06:00:00Z', 'q1', ROUTINE),
    create('2026-03-01T06:00:00Z', 'q2', { strictness: 'optional', statAffinity: 'mind' }),
    create('2026-03-01T06:00:00Z', 'q3', { strictness: 'goal', statAffinity: 'wealth', recurrence: weekly('2026-03-02', [1, 3]) }),
    create('2026-03-01T06:00:00Z', 'q4', { strictness: 'recovery' }),
    act('2026-03-10T08:00:00Z', 'quest.postpone', 'q2', '2026-03-10'),
    act('2026-03-10T08:00:01Z', 'quest.postpone', 'q4', '2026-03-10'),
    act('2026-03-10T08:00:02Z', 'quest.reschedule', 'q3', '2026-03-09', { toMin: 600 }),
    act('2026-03-10T08:00:03Z', 'quest.complete', 'q3', '2026-03-10'),
    act('2026-03-10T08:00:04Z', 'quest.postpone', 'q3', '2026-03-11'),
    act('2026-03-11T08:00:05Z', 'quest.postpone', 'q3', '2026-03-11'),
    act('2026-03-10T08:00:06Z', 'quest.complete', 'q4', '2026-03-10'),
    command('2026-03-10T08:01:00Z', 'quest.delete', { questId: '@q1' }),
    act('2026-03-10T08:02:00Z', 'quest.complete', 'q1', '2026-03-10'),
    command('2026-03-10T08:03:00Z', 'quest.update', { questId: '@q1', patch: { active: true, startTimeMinutes: null } }),
    command('2026-03-10T08:04:00Z', 'quest.update', { questId: '@q1', patch: { strictness: 'anchor' } }),
    command('2026-03-10T08:05:00Z', 'quest.update', { questId: '@q1', patch: { strictness: 'anchor', startTimeMinutes: 300 } }),
    command('2026-03-10T08:05:30Z', 'quest.update', { questId: '@q1', patch: { strictness: 'routine', startTimeMinutes: null } }),
    act('2026-03-10T08:06:00Z', 'quest.complete', 'q1', '2026-03-10'),
    act('2026-03-10T08:07:00Z', 'quest.reschedule', 'q1', '2026-03-11', { toMin: 600 }),
    act('2026-03-10T08:08:00Z', 'quest.reschedule', 'q1', '2026-03-11', { toMin: 660 }),
    command('2026-03-10T08:09:00Z', 'quest.delete', { questId: '@q9' }),
    command('2026-03-10T08:10:00Z', 'quest.update', { questId: '@q9', patch: { durationMinutes: 10 } }),
  ]),
  utc('cosmetics-titles-and-overspend', 'scenario', [
    seedStep('2026-03-10T00:00:00Z', 'coins', { coins: 120 }),
    command('2026-03-10T08:00:00Z', 'cosmetic.purchase', { cosmeticId: 'badge_bronze' }),
    command('2026-03-10T08:01:00Z', 'cosmetic.purchase', { cosmeticId: 'accent_ember' }),
    command('2026-03-10T08:02:00Z', 'cosmetic.purchase', { cosmeticId: 'badge_bronze' }),
    command('2026-03-10T08:03:00Z', 'cosmetic.equip', { cosmeticId: 'accent_ember' }),
    command('2026-03-10T08:04:00Z', 'cosmetic.equip', { cosmeticId: 'badge_bronze' }),
    command('2026-03-10T08:05:00Z', 'cosmetic.purchase', { cosmeticId: 'theme_sunrise' }),
    command('2026-03-10T08:06:00Z', 'title.display', { titleId: 'steady_builder' }),
    command('2026-03-10T08:07:00Z', 'title.display', { titleId: null }),
  ]),
  utc('achievements-and-level-up', 'scenario', [
    create('2026-03-01T06:00:00Z', 'q1', { ...ANCHOR, statAffinity: 'discipline' }),
    create('2026-03-01T06:00:00Z', 'q2', { ...ANCHOR, statAffinity: 'body', startTimeMinutes: 480 }),
    ...repeat(5, index => act(`${day('2026-03-02', index)}T07:05:00Z`, 'quest.complete', 'q1', day('2026-03-02', index))),
    ...repeat(5, index => act(`${day('2026-03-02', index)}T08:05:00Z`, 'quest.complete', 'q2', day('2026-03-02', index))),
  ]),
  utc('quick-log-rewards', 'scenario', [
    create('2026-03-01T06:00:00Z', 'q1', { strictness: 'goal', statAffinity: 'body', moduleLink: 'meal', recurrence: weekly('2026-03-02', [2]) }),
    seedStep('2026-03-10T00:00:00Z', 'openDay', { date: '2026-03-10' }),
    command('2026-03-10T08:00:00Z', 'journal.save', { id: '@j1', draft: { date: '2026-03-10' } }),
    command('2026-03-10T08:01:00Z', 'journal.save', { id: '@j2', draft: { date: '2026-03-10' } }),
    command('2026-03-10T08:02:00Z', 'journal.save', { id: '@j3', draft: { date: '2026-03-09' } }),
    command('2026-03-10T08:03:00Z', 'meal.log', { id: '@m1', draft: { date: '2026-03-10' } }),
    command('2026-03-11T08:03:00Z', 'meal.log', { id: '@m2', draft: { date: '2026-03-11' } }),
    command('2026-03-11T08:04:00Z', 'meal.logPreset', { id: '@m3', presetId: '@p9', date: '2026-03-11' }),
    command('2026-03-11T08:05:00Z', 'meal.savePreset', { id: '@p1' }),
    command('2026-03-12T08:06:00Z', 'meal.logPreset', { id: '@m4', presetId: '@p1', date: '2026-03-12' }),
    command('2026-03-11T08:07:00Z', 'weight.save', { date: '2026-03-11' }),
    command('2026-03-11T08:08:00Z', 'weight.save', { date: '2026-03-11' }),
    command('2026-03-11T08:09:00Z', 'weight.save', { date: '2026-03-11', confirmedReplacement: true }),
    ...repeat(4, index => command(`2026-03-11T09:0${index}:00Z`, 'sidequest.log', { id: `@s${index + 1}`, draft: { date: '2026-03-11', statAffinity: 'mind' } })),
    command('2026-03-11T09:05:00Z', 'sidequest.log', { id: '@s5', draft: { date: '2026-03-12' } }),
  ]),
  utc('returner-shield-waits-for-the-next-quest', 'scenario', [
    seedStep('2026-03-10T00:00:00Z', 'returnerShields', { shields: 1 }),
    create('2026-03-10T08:00:00Z', 'q1', ROUTINE),
    create('2026-03-10T08:01:00Z', 'q2', ROUTINE),
    act('2026-03-10T08:30:00Z', 'quest.skip', 'q1', '2026-03-10'),
    act('2026-03-10T08:31:00Z', 'quest.skip', 'q2', '2026-03-10'),
  ]),
  utc('metric-delete-only-deactivates', 'scenario', [
    command('2026-03-10T08:00:00Z', 'metric.create', { id: '@n1', metricClass: 'general' }),
    command('2026-03-10T08:01:00Z', 'metric.update', { id: '@n1', metricClass: 'general' }),
    command('2026-03-10T08:02:00Z', 'metric.delete', { id: '@n1', metricClass: 'general' }),
    command('2026-03-10T08:03:00Z', 'metric.update', { id: '@n1', metricClass: 'general' }),
    command('2026-03-10T08:04:00Z', 'metric.register', { metricId: '@n1', metricClass: 'general', date: '2026-03-10' }),
    command('2026-03-10T08:05:00Z', 'metric.delete', { id: '@n1', metricClass: 'general', detach: true }),
    command('2026-03-10T08:06:00Z', 'metric.update', { id: '@n9', metricClass: 'general' }),
    command('2026-03-10T08:07:00Z', 'metric.register', { metricId: '@n9', metricClass: 'general', date: '2026-03-10' }),
  ]),
  utc('compassion-refuses-a-command-issued-before-the-open-day', 'tests/quests/day-stamp.spec.ts', [
    create('2026-03-01T06:00:00Z', 'q1', ANCHOR),
    seedStep('2026-03-10T00:00:00Z', 'day', { date: '2026-03-10' }),
    seedStep('2026-03-10T00:00:00Z', 'openDay', { date: '2026-03-10' }),
    seedStep('2026-03-10T00:00:00Z', 'recovery', { date: '2026-03-10', sourceQuest: '@q1' }),
    { ...command('2026-03-09T20:00:00Z', 'recovery.complete'), processedAt: '2026-03-10T09:00:00Z', issuerOpenDay: null },
    { ...command('2026-03-09T20:01:00Z', 'plan.setLock', { locked: false }), processedAt: '2026-03-10T09:00:00Z', issuerOpenDay: null },
    command('2026-03-10T09:30:00Z', 'plan.setLock', { locked: true, questIds: ['@q1'] }),
    command('2026-03-10T09:31:00Z', 'recovery.complete'),
  ]),
  {
    id: 'zone-offset-minute-of-day',
    source: 'scenario',
    timeZone: 'Asia/Kolkata',
    offsetMinutes: 330,
    steps: [
      create('2026-03-01T06:00:00Z', 'q1', ANCHOR),
      act('2026-03-10T01:55:00Z', 'quest.complete', 'q1', '2026-03-10'),
      act('2026-03-11T02:05:00Z', 'quest.complete', 'q1', '2026-03-11'),
      act('2026-03-11T18:35:00Z', 'quest.complete', 'q1', '2026-03-12'),
      act('2026-03-12T18:25:00Z', 'quest.complete', 'q1', '2026-03-14'),
    ],
  },
  utc('metric-builtin-is-fixed', 'scenario', [
    command('2026-03-10T08:00:00Z', 'metric.update', { id: '@builtin-steps', metricClass: 'activity' }),
    command('2026-03-10T08:01:00Z', 'metric.delete', { id: '@builtin-weight', metricClass: 'health', detach: true }),
    command('2026-03-10T08:02:00Z', 'metric.register', { metricId: '@builtin-steps', metricClass: 'activity', date: '2026-03-10' }),
    command('2026-03-10T08:03:00Z', 'metric.create', { id: '@n1', metricClass: 'general' }),
    command('2026-03-10T08:04:00Z', 'metric.delete', { id: '@n1', metricClass: 'general' }),
  ]),
  walked('walk-closes-the-prepared-day-once', ROLLOVER_SPEC, [
    create('2026-03-10T12:00:00Z', 'q1', ROUTINE),
    horizon('2026-03-11T12:00:00Z'),
    horizon('2026-03-11T12:00:00Z'),
    horizon('2026-03-13T12:00:00Z'),
  ]),
  walked('walk-records-every-miss-and-breaks-streaks', ROLLOVER_SPEC, [
    ...repeat(6, index => create('2026-03-06T06:00:00Z', `q${index + 1}`, ROUTINE)),
    ...repeat(4, index => act(`${day('2026-03-06', index)}T08:10:00Z`, 'quest.complete', 'q2', day('2026-03-06', index))),
    horizon('2026-03-10T06:00:00Z'),
    act('2026-03-10T08:10:00Z', 'quest.complete', 'q6', '2026-03-10'),
    horizon('2026-03-11T12:00:00Z'),
  ]),
  walked('walk-dates-the-last-activity', ROLLOVER_SPEC, [
    create('2026-03-10T06:00:00Z', 'q1', ROUTINE),
    act('2026-03-10T08:10:00Z', 'quest.complete', 'q1', '2026-03-10'),
    horizon('2026-03-11T12:00:00Z'),
  ]),
  walked('walk-fires-the-returner', ROLLOVER_SPEC, [
    create('2026-03-10T06:00:00Z', 'q1', ROUTINE),
    act('2026-03-10T08:10:00Z', 'quest.complete', 'q1', '2026-03-10'),
    horizon('2026-03-18T12:00:00Z'),
    act('2026-03-18T12:10:00Z', 'quest.complete', 'q1', '2026-03-18'),
    horizon('2026-03-19T12:00:00Z'),
  ]),
  walked('walk-returner-shield-goes-to-the-longest-run', 'scenario', [
    create('2026-03-01T05:00:00Z', 'q1', ROUTINE),
    create('2026-03-01T05:00:00Z', 'q2', ROUTINE),
    ...repeat(4, index => act(`${day('2026-03-01', index)}T08:10:00Z`, 'quest.complete', 'q1', day('2026-03-01', index))),
    ...repeat(2, index => act(`${day('2026-03-03', index)}T08:20:00Z`, 'quest.complete', 'q2', day('2026-03-03', index))),
    horizon('2026-03-12T12:00:00Z'),
  ]),
  walked('walk-expires-the-recovery', ROLLOVER_SPEC, [
    create('2026-03-08T06:00:00Z', 'q1', ANCHOR),
    horizon('2026-03-09T12:00:00Z'),
    horizon('2026-03-10T12:00:00Z'),
  ]),
  walked('walk-recovery-and-comeback-on-the-day-after-a-miss', 'scenario', [
    create('2026-03-08T05:00:00Z', 'q1', ANCHOR),
    create('2026-03-08T05:00:00Z', 'q2', { ...ANCHOR, startTimeMinutes: 600 }),
    horizon('2026-03-09T06:00:00Z'),
    act('2026-03-09T07:10:00Z', 'quest.complete', 'q1', '2026-03-09'),
    command('2026-03-09T09:00:00Z', 'recovery.complete', { reflectionText: true }),
    act('2026-03-09T10:05:00Z', 'quest.complete', 'q2', '2026-03-09'),
    horizon('2026-03-10T12:00:00Z'),
  ]),
  walked('walk-catch-up-limit-strands-old-days', ROLLOVER_SPEC, [
    create('2025-10-31T06:00:00Z', 'q1', { ...ANCHOR, recurrence: daily('2025-10-01') }),
    horizon('2025-11-01T12:00:00Z'),
    horizon('2026-03-10T12:00:00Z'),
  ]),
  walked('walk-forward-zone-change-skips-the-day-it-jumps', ROLLOVER_SPEC, [
    command('2026-03-09T08:00:00Z', 'account.setTimeZone', { timezone: 'UTC' }),
    create('2026-03-09T08:01:00Z', 'q1', ROUTINE),
    command('2026-03-09T09:00:00Z', 'account.setTimeZone', { timezone: 'Pacific/Kiritimati' }),
    horizon('2026-03-10T11:00:00Z', 840),
    horizon('2026-03-10T11:00:00Z', 840),
    horizon('2026-03-11T11:00:00Z', 840),
  ]),
  walked(
    'walk-backward-zone-change-holds-the-open-day',
    ROLLOVER_SPEC,
    [
      command('2026-03-09T20:00:00Z', 'account.setTimeZone', { timezone: 'Pacific/Kiritimati' }),
      create('2026-03-09T20:01:00Z', 'q1', ROUTINE),
      command('2026-03-09T21:00:00Z', 'account.setTimeZone', { timezone: 'UTC' }),
      horizon('2026-03-10T11:00:00Z', 0),
      horizon('2026-03-10T20:00:00Z', 0),
      horizon('2026-03-11T20:00:00Z', 0),
      horizon('2026-03-12T01:00:00Z', 0),
    ],
    'Pacific/Kiritimati',
    840,
  ),
  walked('walk-intensity-change-takes-effect-the-next-day', 'scenario', [
    create('2026-03-09T06:00:00Z', 'q1', ANCHOR),
    create('2026-03-09T06:00:00Z', 'q2', ROUTINE),
    act('2026-03-10T07:10:00Z', 'quest.complete', 'q1', '2026-03-10'),
    act('2026-03-10T08:30:00Z', 'quest.skip', 'q2', '2026-03-10'),
    command('2026-03-10T09:00:00Z', 'account.setIntensityMode', { intensityMode: 'high_intensity' }),
    horizon('2026-03-11T12:00:00Z'),
    act('2026-03-11T12:30:00Z', 'quest.skip', 'q1', '2026-03-11'),
    horizon('2026-03-13T12:00:00Z'),
  ]),
  walked('walk-staged-intensity-waits-for-the-day-the-walk-prepares', 'scenario', [
    create('2026-03-09T06:00:00Z', 'q1', ANCHOR),
    command('2026-03-09T09:00:00Z', 'account.setIntensityMode', { intensityMode: 'high_intensity' }),
    horizon('2026-03-12T12:00:00Z'),
  ]),
  walked('walk-weekly-crown-banks-on-the-period-close', 'scenario', [
    command('2026-03-01T05:00:00Z', 'account.setIntensityMode', { intensityMode: 'low_intensity' }),
    create('2026-03-02T05:00:00Z', 'q1', ANCHOR),
    create('2026-03-02T05:00:00Z', 'q2', ROUTINE),
    ...repeat(7, index => act(`${day('2026-03-02', index)}T08:10:00Z`, index === 2 ? 'quest.skip' : 'quest.complete', 'q2', day('2026-03-02', index))),
    ...repeat(7, index => index === 4 ? null : act(`${day('2026-03-02', index)}T07:10:00Z`, 'quest.complete', 'q1', day('2026-03-02', index))).filter(
      (step): step is Step => step !== null,
    ),
    horizon('2026-03-09T12:00:00Z'),
    act('2026-03-09T07:10:00Z', 'quest.complete', 'q1', '2026-03-09'),
    horizon('2026-03-11T12:00:00Z'),
  ]),
  walked('walk-locked-day-cleared', 'scenario', [
    create('2026-03-09T05:00:00Z', 'q1', ROUTINE),
    create('2026-03-09T05:00:00Z', 'q2', ROUTINE),
    command('2026-03-10T06:00:00Z', 'plan.setLock', { locked: true, questIds: ['@q1'] }),
    act('2026-03-10T08:10:00Z', 'quest.complete', 'q1', '2026-03-10'),
    horizon('2026-03-11T12:00:00Z'),
  ]),
  walked('walk-offline-completion-replaces-the-miss', 'scenario', [
    create('2026-03-09T05:00:00Z', 'q1', ROUTINE),
    horizon('2026-03-11T06:00:00Z'),
    act('2026-03-11T07:00:00Z', 'quest.complete', 'q1', '2026-03-10'),
    horizon('2026-03-12T06:00:00Z'),
  ]),
  walked('walk-empty-days-late-quests-and-exceptions', 'scenario', [
    create('2026-03-02T05:00:00Z', 'q1', { ...ROUTINE, recurrence: weekly('2026-03-02', [1]) }),
    act('2026-03-02T08:10:00Z', 'quest.complete', 'q1', '2026-03-02'),
    create('2026-03-04T06:00:00Z', 'q2', { ...ROUTINE, recurrence: daily('2026-03-01') }),
    create('2026-03-04T06:01:00Z', 'q3', { ...ROUTINE, recurrence: { ...daily('2026-03-01'), exceptions: ['2026-03-04', '2026-03-05'] } }),
    horizon('2026-03-07T12:00:00Z'),
  ]),
];

const results: JsonObject[] = [];
for (const scenario of scenarios) results.push(await run(scenario));
writeFileSync(join(outDir, 'scenarios.json'), `${results.map(result => JSON.stringify(result)).join('\n')}\n`);
console.log(`wrote ${results.length} scenarios`);
