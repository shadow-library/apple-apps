import { mock } from 'bun:test';
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');
const outDir = dirname(fileURLToPath(import.meta.url));
const server = join(platformRepo, 'apps/memoir-server/src');
const web = join(platformRepo, 'apps/memoir-web/src');

mock.module('@shadow-library/ui', () => ({ DEFAULT_LOCALE: 'en-GB' }));
mock.module('@/lib/format', () => ({ formatLocalDate: (value: string) => value }));

const { setConfig } = await import(Bun.resolveSync('@shadow-library/common/testing', server));
setConfig({ 'telemetry.pseudo-id-secret': 'fixture-secret' });
const finance = await import(join(server, 'modules/finance/index.ts'));
const { AccountService } = await import(join(server, 'modules/account/account.service.ts'));
const { CURRENCY_CODES } = await import(join(server, 'classes/enum.dto.ts'));
const { CURRENCIES } = await import(join(web, 'lib/data/finance.types.ts'));
const financeRules = await import(join(web, 'lib/data/finance.rules.ts'));

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
interface Case {
  id: string;
  input: Json;
  output: Json;
}
interface Divergence {
  file: string;
  function: string;
  id: string;
  reason: string;
  reference: Json;
  exact: Json;
}

const BIGINT_MARK = /"(-?\d+)n"/g;
const encode = (value: unknown): string => JSON.stringify(value, (_key, item) => (typeof item === 'bigint' ? `${item}n` : item)).replace(BIGINT_MARK, '$1');
const clean = (value: unknown): Json => {
  if (value === undefined) return null;
  if (typeof value === 'bigint') return value as unknown as Json;
  if (Array.isArray(value)) return value.map(clean);
  if (value !== null && typeof value === 'object') return Object.fromEntries(Object.entries(value).filter(([, item]) => item !== undefined).map(([key, item]) => [key, clean(item)]));
  return value as Json;
};

const writeJson = (name: string, body: string): void => writeFileSync(join(outDir, name), body);
const fixture = (file: string, groups: Record<string, Case[]>): void => {
  for (const [name, entries] of Object.entries(groups)) {
    const ids = new Set<string>();
    for (const entry of entries) {
      if (ids.has(entry.id)) throw new Error(`duplicate case id ${name}/${entry.id}`);
      ids.add(entry.id);
    }
  }
  const body = Object.entries(groups)
    .map(([key, items]) => `${JSON.stringify(key)}: [\n${items.map(item => encode(item)).join(',\n')}\n]`)
    .join(',\n');
  writeJson(file, `{\n${body}\n}\n`);
};

const lcg = (seed: number) => {
  let state = seed >>> 0;
  return () => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
    return state / 0x1_0000_0000;
  };
};
const pick = <T>(next: () => number, values: readonly T[]): T => values[Math.floor(next() * values.length)] ?? (values[0] as T);
const between = (next: () => number, lower: number, upper: number): number => lower + Math.floor(next() * (upper - lower + 1));

const exponentOf = (code: string): number => {
  const entry = CURRENCIES[code];
  if (!entry) throw new Error(`the reference has no exponent for ${code}`);
  return entry.exponent as number;
};

const floorDivide = (numerator: bigint, denominator: bigint): bigint => {
  const quotient = numerator / denominator;
  return numerator % denominator !== 0n && numerator < 0n !== denominator < 0n ? quotient - 1n : quotient;
};
const roundHalfUp = (numerator: bigint, denominator: bigint): bigint => floorDivide(2n * numerator + denominator, 2n * denominator);
const decimal = (text: string): { digits: bigint; scale: number } => {
  const [whole = '0', fraction = ''] = text.split('.');
  return { digits: BigInt(whole + fraction), scale: fraction.length };
};
const exactHome = (amountMinor: bigint, currency: string, home: string, rate: string): bigint => {
  const { digits, scale } = decimal(rate);
  return roundHalfUp(amountMinor * digits * 10n ** BigInt(exponentOf(home)), 10n ** BigInt(scale + exponentOf(currency)));
};
const canonicalRate = (digits: bigint, scale: number): string => {
  const padded = digits.toString().padStart(scale + 1, '0');
  const whole = padded.slice(0, padded.length - scale);
  const fraction = padded.slice(padded.length - scale).replace(/0+$/, '');
  return fraction ? `${whole}.${fraction}` : whole;
};

const divergences: Divergence[] = [];
const diverge = (file: string, fn: string, id: string, reason: string, reference: unknown, exact: unknown): void => {
  divergences.push({ file, function: fn, id, reason, reference: clean(reference), exact: clean(exact) });
};
const exponentReason = (currency: string, home: string): string =>
  exponentOf(currency) === exponentOf(home) ? 'float' : `exponent ${exponentOf(currency)} to ${exponentOf(home)}`;

const ACCOUNT_ID = 1n;
const INT64_MAX = 2n ** 63n - 1n;
const INT64_MIN = -(2n ** 63n);

const financeHarness = (home: string, rates: Map<string, string>) => {
  const handlers = new Map<string, (context: unknown) => Promise<{ status: string; result: Record<string, unknown> }>>();
  const created: Record<string, unknown>[] = [];
  const create = async (_tx: unknown, values: Record<string, unknown>) => {
    created.push(values);
    return { id: 9n, receiptRef: null, fxRate: null, ...values };
  };
  let subscription: Record<string, unknown> | null = null;
  const expenses = new Map<string, Record<string, unknown>>();
  let confirming = '';
  const service = new finance.FinanceCommandsService(
    { registerHandler: (type: string, handler: never) => handlers.set(type, handler) },
    { grant: async () => [{ coinsDelta: 1 }] },
    { onSubscriptionConfirmed: async () => undefined },
    { ensureSeeded: async () => undefined },
    { create },
    { removeForExpense: async () => undefined, append: async () => undefined },
    {
      create,
      findByIdForUpdateInTx: async () => subscription,
      advanceCycle: async (_tx: unknown, _id: bigint, lastConfirmedDate: string, nextDueDate: string) => {
        subscription = { ...subscription, lastConfirmedDate, nextDueDate };
      },
    },
    { find: async (_tx: unknown, date: string, base: string, quote: string) => (rates.has(`${date}:${base}:${quote}`) ? { rate: rates.get(`${date}:${base}:${quote}`) } : null) },
    { emit: () => undefined },
    {},
  );
  service.onModuleInit();
  const tx = {
    select: (columns?: unknown) => ({
      from: () => ({ where: async () => (columns ? [{ defaultCurrency: home }] : [expenses.get(confirming)].filter(Boolean)) }),
    }),
    insert: () => ({
      values: (row: Record<string, unknown>) => ({
        onConflictDoNothing: () => ({
          returning: async () => {
            const key = row['billingCycleDate'] as string;
            if (expenses.has(key)) return [];
            expenses.set(key, row);
            return [row];
          },
        }),
      }),
    }),
  };
  const run = (type: string, payload: Record<string, unknown>) => {
    const handler = handlers.get(type);
    if (!handler) throw new Error(`no handler registered for '${type}'`);
    if (type === 'subscription.confirmCycle') confirming = payload['billingDate'] as string;
    return handler({ accountId: ACCOUNT_ID, tx, envelope: { commandId: 'c-1', type, payload, localDate: '2026-01-01' } });
  };
  const captureFx = (currency: string, occurredOn: string, amountMinor: bigint) =>
    (service as unknown as Record<string, (...args: unknown[]) => Promise<Record<string, unknown>>>)['captureFx'](tx, currency, home, occurredOn, amountMinor);
  return {
    run,
    created,
    captureFx,
    setSubscription: (row: Record<string, unknown>) => {
      subscription = row;
    },
    subscription: () => subscription,
  };
};

const HOMES = ['EUR', 'USD', 'JPY', 'NOK', 'INR', 'GBP'] as const;
const EDGE_PAIRS: [string, string][] = [
  ['USD', 'EUR'],
  ['NOK', 'EUR'],
  ['JPY', 'EUR'],
  ['EUR', 'JPY'],
  ['USD', 'INR'],
  ['JPY', 'USD'],
];
const EDGE_AMOUNTS = [0n, 1n, -1n, 5n, 49n, 50n, 99n, 100n, 1235n, -1235n, 4250n, 19_900n, 999_999n, 123_456_789n, 9_007_199_254_740_993n, 1_000_000_000_000_007n];
const EDGE_RATES = ['1', '0.5', '0.0061', '0.0856', '0.9213', '1.08', '1.15', '150.25', '0.00000001', '12.34567891', '83.1'];
const CONVERSION_DATE = '2026-10-30';

const randomRate = (next: () => number): string => {
  const scale = between(next, 0, 8);
  const whole = BigInt(pick(next, [0, 0, 0, 1, 1, 2, 7, 11, 83, 150, 1400]));
  const fraction = BigInt(Math.floor(next() * 10 ** scale));
  const digits = whole * 10n ** BigInt(scale) + fraction;
  return digits === 0n ? '1' : canonicalRate(digits, scale);
};

const conversionCases: Case[] = [];
const conversionCase = async (id: string, amountMinor: bigint, currency: string, home: string, rate: string | null): Promise<void> => {
  const rates = new Map<string, string>(rate === null ? [] : [[`${CONVERSION_DATE}:${currency}:${home}`, rate]]);
  const captured = await financeHarness(home, rates).captureFx(currency, CONVERSION_DATE, amountMinor);
  const reference = captured['homeAmountMinor'] as bigint | null;
  conversionCases.push({ id, input: clean({ amountMinor, currency, home, rate }), output: clean(reference) });
  if (rate === null) return;
  const exact = exactHome(amountMinor, currency, home, rate);
  if (exact > INT64_MAX || exact < INT64_MIN) {
    diverge('conversion.json', 'captureFx', id, 'beyond 64-bit minor units', reference, 'error: memoir_finance.overflow');
  } else if (reference !== exact) {
    diverge('conversion.json', 'captureFx', id, exponentReason(currency, home), reference, exact);
  }
};

for (const [currency, home] of EDGE_PAIRS) {
  for (const amount of EDGE_AMOUNTS) {
    for (const rate of EDGE_RATES) await conversionCase(`edge:${currency}>${home}:${amount}@${rate}`, amount, currency, home, rate);
  }
  await conversionCase(`edge:${currency}>${home}:no-rate`, 4250n, currency, home, null);
}
{
  const next = lcg(0x4d31_3001);
  for (const home of HOMES) {
    for (const currency of CURRENCY_CODES as readonly string[]) {
      if (currency === home) continue;
      for (let index = 0; index < 12; index++) {
        const amount = BigInt(pick(next, [1, 7, 99, 100, 250, 999, 1999, 4250, 12_345, 99_999, 1_000_000, 73_210_045]) * (next() < 0.1 ? -1 : 1));
        await conversionCase(`grid:${currency}>${home}#${index}`, amount, currency, home, randomRate(next));
      }
    }
  }
}

interface ProviderScript {
  [date: string]: Record<string, number>;
}
const reconcileCases: Case[] = [];
const reconcileCase = async (id: string, home: string, expenses: { id: string; amountMinor: number; currency: string; occurredOn: string }[], provider: ProviderScript) => {
  const cache = new Map<string, string>();
  const resolved: Record<string, unknown>[] = [];
  const sweep = new finance.FxReconciliationService(
    { registerSweep: () => undefined },
    {
      fetchRates: async (pairs: { base: string; quote: string }[], date?: string) => {
        if (!date) return [];
        const quotes = provider[date] ?? {};
        return pairs.flatMap(pair => (quotes[pair.base] === undefined ? [] : [{ ...pair, rate: quotes[pair.base] }]));
      },
    },
    {
      findForEntry: async (date: string, base: string, quote: string) => (cache.has(`${date}:${base}:${quote}`) ? { rate: cache.get(`${date}:${base}:${quote}`) } : null),
      upsert: async (date: string, base: string, quote: string, rate: string) => {
        cache.set(`${date}:${base}:${quote}`, rate);
      },
    },
    {
      findNullRateAcrossAccounts: async () =>
        expenses.map(expense => ({ ...expense, accountId: ACCOUNT_ID, amountMinor: BigInt(expense.amountMinor), createdAt: new Date(0) })),
      resolveNullRate: async (expenseId: string, fxRate: string, homeAmountMinor: bigint, fxRateDate: string) => {
        resolved.push({ id: expenseId, fxRate, homeAmountMinor, fxRateDate });
      },
    },
    { findDefaultCurrencies: async () => new Map([[ACCOUNT_ID, home]]) },
  );
  await sweep.run();
  const providerText = Object.fromEntries(Object.entries(provider).map(([date, quotes]) => [date, Object.fromEntries(Object.entries(quotes).map(([code, rate]) => [code, String(rate)]))]));
  reconcileCases.push({ id, input: clean({ home, expenses, provider: providerText }), output: clean(resolved) });
  const exact = resolved.map(entry => {
    const expense = expenses.find(candidate => candidate.id === entry['id']);
    if (!expense) throw new Error(`reconciliation resolved an unknown expense ${entry['id']}`);
    return { ...entry, homeAmountMinor: exactHome(BigInt(expense.amountMinor), expense.currency, home, entry['fxRate'] as string) };
  });
  if (encode(exact) === encode(resolved)) return;
  const reasons = [...new Set(expenses.filter(expense => expense.currency !== home).map(expense => exponentReason(expense.currency, home)))];
  diverge('conversion.json', 'reconcile', id, reasons.join(', '), resolved, exact);
};

await reconcileCase(
  'spec:own-date',
  'EUR',
  [
    { id: 'e1', amountMinor: 21_400, currency: 'NOK', occurredOn: '2025-09-10' },
    { id: 'e2', amountMinor: 1_000, currency: 'USD', occurredOn: '2025-08-10' },
    { id: 'e3', amountMinor: 6_415, currency: 'EUR', occurredOn: '2025-09-10' },
    { id: 'e4', amountMinor: 999, currency: 'USD', occurredOn: '2025-09-10' },
  ],
  { '2025-09-10': { NOK: 0.0856, USD: 0.9213 }, '2025-08-10': { USD: 0.9187 } },
);
await reconcileCase(
  'spec:unavailable',
  'NOK',
  [
    { id: 'e1', amountMinor: 4_250, currency: 'EUR', occurredOn: '2025-03-01' },
    { id: 'e2', amountMinor: 1_999, currency: 'GBP', occurredOn: '2025-03-01' },
  ],
  { '2025-03-01': { EUR: 11.6815 } },
);
await reconcileCase('spec:yen', 'EUR', [{ id: 'e1', amountMinor: 1_200, currency: 'JPY', occurredOn: '2025-05-20' }], { '2025-05-20': { JPY: 0.0061 } });
{
  const next = lcg(0x4d31_3002);
  for (let index = 0; index < 40; index++) {
    const home = pick(next, ['EUR', 'USD', 'NOK', 'GBP', 'INR'] as const);
    const dates = ['2025-01-15', '2025-02-28', '2025-06-30', '2025-12-31'];
    const expenses = Array.from({ length: between(next, 1, 5) }, (_, item) => ({
      id: `e${item + 1}`,
      amountMinor: between(next, -500, 250_000),
      currency: pick(next, ['EUR', 'USD', 'NOK', 'GBP', 'INR', 'SEK', 'CHF'] as const),
      occurredOn: pick(next, dates),
    }));
    const provider: ProviderScript = {};
    for (const date of dates) {
      const quotes: Record<string, number> = {};
      for (const currency of ['EUR', 'USD', 'NOK', 'GBP', 'INR', 'SEK', 'CHF']) if (next() < 0.8) quotes[currency] = Number(randomRate(next));
      provider[date] = quotes;
    }
    await reconcileCase(`seeded#${index}`, home, expenses, provider);
  }
}

fixture('conversion.json', { captureFx: conversionCases, reconcile: reconcileCases });

const FREQUENCIES = ['weekly', 'monthly', 'quarterly', 'yearly', 'custom'] as const;
const INTERVALS = [null, 1, 7, 10, 29, 30, 31, 45, 90, 365, 0, -3];
const MONTHLY_AMOUNTS = [0, 1, 2, 3, 11, 12, 13, 99, 100, 199, 999, 1_999, 19_900, 123_457, -1, -100, -19_900, 9_007_199_254_740_991];
const monthlyCases: Case[] = [];
for (const frequency of FREQUENCIES) {
  for (const amountMinor of MONTHLY_AMOUNTS) {
    for (const customIntervalDays of frequency === 'custom' ? INTERVALS : [null]) {
      const harness = financeHarness('EUR', new Map());
      await harness.run('subscription.create', {
        name: 'Gym',
        amountText: '199',
        amountMinor,
        currency: 'EUR',
        frequency,
        billingDay: 1,
        nextDueDate: '2026-01-01',
        categoryId: 'subs',
        ...(customIntervalDays === null ? {} : { customIntervalDays }),
      });
      const id = `${frequency}:${amountMinor}:${customIntervalDays ?? 'default'}`;
      const output = harness.created[0]?.['monthlyEquivalentMinor'] as bigint;
      monthlyCases.push({ id, input: { amountMinor, frequency, customIntervalDays }, output: clean(output) });
      if (customIntervalDays !== null && customIntervalDays <= 0) {
        diverge('monthly-equivalent.json', 'monthlyEquivalentMinor', id, 'custom interval not positive', output, 'error: memoir_finance.custom_interval_not_positive');
      }
    }
  }
}
fixture('monthly-equivalent.json', { monthlyEquivalentMinor: monthlyCases });

interface BudgetExpense {
  amountMinor: number;
  currency: string;
  rate: string | null;
  occurredOn: string;
}
const budgetCases: Case[] = [];
const budgetCase = async (id: string, today: string, home: string, budgetMinor: number | null, expenses: BudgetExpense[]): Promise<void> => {
  const exactSpent = { reference: 0n, exact: 0n };
  const webExpenses = [];
  for (const [index, expense] of expenses.entries()) {
    const rates = new Map<string, string>(expense.rate === null ? [] : [[`${expense.occurredOn}:${expense.currency}:${home}`, expense.rate]]);
    const captured = await financeHarness(home, rates).captureFx(expense.currency, expense.occurredOn, BigInt(expense.amountMinor));
    const homeAmountMinor = captured['homeAmountMinor'] as bigint | null;
    const fxRate = captured['fxRate'] as string | null;
    webExpenses.push({
      id: `b${index}`,
      amountMinor: expense.amountMinor,
      amountText: String(expense.amountMinor),
      currency: expense.currency,
      fxRate: fxRate === null ? null : Number(fxRate),
      homeAmountMinor: homeAmountMinor === null ? null : Number(homeAmountMinor),
      categoryId: 'food',
      occurredOnDate: expense.occurredOn,
      loggedAt: `${expense.occurredOn}T10:00:00.000Z`,
    });
    const inMonth = expense.occurredOn.slice(0, 7) === today.slice(0, 7);
    if (!inMonth) continue;
    if (expense.currency === home) {
      exactSpent.exact += BigInt(expense.amountMinor);
    } else if (expense.rate !== null) {
      exactSpent.exact += exactHome(BigInt(expense.amountMinor), expense.currency, home, expense.rate);
    }
  }
  const settings = { homeCurrency: home, currencies: [home], weekStartsOn: 1, monthlyBudgetMinor: budgetMinor };
  const standing = financeRules.budgetStanding(webExpenses, settings, today) as Record<string, unknown>;
  budgetCases.push({ id, input: clean({ today, home, budgetMinor, expenses }), output: clean(standing) });
  if (standing['kind'] !== 'set') return;
  const exact = { ...standing, spentMinor: Number(exactSpent.exact), leftMinor: (budgetMinor ?? 0) - Number(exactSpent.exact) };
  if (encode(exact) !== encode(standing)) {
    const reasons = [...new Set(expenses.filter(expense => expense.currency !== home && expense.rate !== null).map(expense => exponentReason(expense.currency, home)))];
    diverge('budget.json', 'budgetStanding', id, reasons.join(', '), standing, exact);
  }
};

await budgetCase('spec:unset', '2026-09-14', 'EUR', null, [{ amountMinor: 1_200, currency: 'EUR', rate: null, occurredOn: '2026-09-03' }]);
await budgetCase('spec:mixed', '2026-09-14', 'EUR', 160_000, [
  { amountMinor: 6_415, currency: 'EUR', rate: null, occurredOn: '2026-09-10' },
  { amountMinor: 21_400, currency: 'NOK', rate: '0.0856', occurredOn: '2026-09-10' },
  { amountMinor: 1_000, currency: 'USD', rate: '0.9213', occurredOn: '2026-08-10' },
  { amountMinor: 2_500, currency: 'GBP', rate: null, occurredOn: '2026-09-11' },
]);
await budgetCase('spec:yen-home', '2026-09-14', 'JPY', 50_000, [{ amountMinor: 1_200, currency: 'JPY', rate: null, occurredOn: '2026-09-03' }]);
await budgetCase('spec:overspent', '2026-02-28', 'USD', 10_000, [
  { amountMinor: 9_000, currency: 'USD', rate: null, occurredOn: '2026-02-01' },
  { amountMinor: 2_000, currency: 'EUR', rate: '1.08', occurredOn: '2026-02-28' },
  { amountMinor: -500, currency: 'USD', rate: null, occurredOn: '2026-02-14' },
]);
await budgetCase('spec:month-edges', '2024-02-29', 'EUR', 0, [
  { amountMinor: 100, currency: 'EUR', rate: null, occurredOn: '2024-01-31' },
  { amountMinor: 200, currency: 'EUR', rate: null, occurredOn: '2024-02-01' },
  { amountMinor: 300, currency: 'EUR', rate: null, occurredOn: '2024-02-29' },
  { amountMinor: 400, currency: 'EUR', rate: null, occurredOn: '2024-03-01' },
]);
await budgetCase('spec:yen-abroad', '2026-05-20', 'EUR', 100_000, [{ amountMinor: 1_200, currency: 'JPY', rate: '0.0061', occurredOn: '2026-05-20' }]);
{
  const next = lcg(0x4d31_3003);
  const months = ['2026-01', '2026-02', '2026-03'];
  for (let index = 0; index < 60; index++) {
    const home = pick(next, ['EUR', 'USD', 'NOK', 'GBP'] as const);
    const month = pick(next, months);
    const days = Number(financeRules.financePeriod('month', `${month}-01`).end.slice(8));
    const today = `${month}-${String(between(next, 1, days)).padStart(2, '0')}`;
    const expenses = Array.from({ length: between(next, 0, 8) }, () => {
      const currency = pick(next, ['EUR', 'USD', 'NOK', 'GBP', 'SEK'] as const);
      const expenseMonth = pick(next, months);
      const expenseDays = Number(financeRules.financePeriod('month', `${expenseMonth}-01`).end.slice(8));
      return {
        amountMinor: between(next, -2_000, 80_000),
        currency,
        rate: currency === home || next() < 0.2 ? null : randomRate(next),
        occurredOn: `${expenseMonth}-${String(between(next, 1, expenseDays)).padStart(2, '0')}`,
      };
    });
    await budgetCase(`seeded#${index}`, today, home, next() < 0.15 ? null : between(next, 0, 500_000), expenses);
  }
}

const onboardCases: Case[] = [];
for (const [index, { defaultCurrency, budgetMinor, onboardCurrency }] of [
  { defaultCurrency: 'USD', budgetMinor: 160_000, onboardCurrency: 'EUR' },
  { defaultCurrency: 'EUR', budgetMinor: 160_000, onboardCurrency: 'EUR' },
  { defaultCurrency: 'EUR', budgetMinor: null, onboardCurrency: 'NOK' },
  { defaultCurrency: 'JPY', budgetMinor: 50_000, onboardCurrency: 'JPY' },
  { defaultCurrency: 'GBP', budgetMinor: 0, onboardCurrency: 'INR' },
].entries()) {
  let written: Record<string, unknown> = {};
  const account = { id: ACCOUNT_ID, defaultCurrency, monthlyBudgetMinor: budgetMinor };
  const service = new AccountService(
    { getAccountId: () => ACCOUNT_ID },
    {
      findById: async () => account,
      completeOnboarding: async (_id: bigint, values: Record<string, unknown>) => {
        written = values;
        return null;
      },
    },
    { register: () => undefined },
    {},
  );
  await service
    .onboard({ defaultCurrency: onboardCurrency, enabledCurrencies: ['USD'], timezone: 'Europe/Oslo', scheduleStartMin: 360, scheduleEndMin: 1380 })
    .catch(() => undefined);
  const after = 'monthlyBudgetMinor' in written ? written['monthlyBudgetMinor'] : budgetMinor;
  onboardCases.push({
    id: `onboard#${index}`,
    input: { defaultCurrency, budgetMinor, onboardCurrency },
    output: clean({ defaultCurrency: written['defaultCurrency'], enabledCurrencies: written['enabledCurrencies'], monthlyBudgetMinor: after }),
  });
}
fixture('budget.json', { budgetStanding: budgetCases, onboard: onboardCases });

interface CycleSubscription {
  frequency: (typeof FREQUENCIES)[number];
  billingDay: number;
  customIntervalDays: number | null;
  nextDueDate: string;
  amountMinor: number;
  currency: string;
}
const cycleCases: Case[] = [];
const advance = (subscription: CycleSubscription, from: string): string => finance.advanceDueDate(subscription, from);
const cycleCase = async (id: string, subscription: CycleSubscription, home: string, rate: string | null, confirms: string[]): Promise<void> => {
  const rates = new Map<string, string>();
  if (rate !== null) for (const date of confirms) rates.set(`${date}:${subscription.currency}:${home}`, rate);
  const harness = financeHarness(home, rates);
  harness.setSubscription({ id: 7n, ...subscription, amountText: String(subscription.amountMinor), categoryId: 'subs', note: 'Plan', lastConfirmedDate: null });
  const steps = [];
  const exactSteps = [];
  const confirmed: string[] = [];
  for (const [index, billingDate] of confirms.entries()) {
    const outcome = await harness.run('subscription.confirmCycle', { id: '7', billingDate, expenseId: `x${index}` });
    const row = harness.subscription() ?? {};
    const inserted = outcome.result['expenseId'] === `x${index}`;
    const captured = await harness.captureFx(subscription.currency, billingDate, BigInt(subscription.amountMinor));
    const step = {
      inserted,
      nextDueDate: row['nextDueDate'],
      lastConfirmedDate: row['lastConfirmedDate'],
      homeAmountMinor: subscription.currency === home ? null : captured['homeAmountMinor'],
    };
    steps.push(step);
    if (!confirmed.includes(billingDate)) confirmed.push(billingDate);
    const latest = [...confirmed].sort().at(-1) as string;
    exactSteps.push({
      inserted: !confirms.slice(0, index).includes(billingDate),
      nextDueDate: latest >= subscription.nextDueDate ? advance(subscription, latest) : subscription.nextDueDate,
      lastConfirmedDate: latest,
      homeAmountMinor: subscription.currency === home || rate === null ? null : exactHome(BigInt(subscription.amountMinor), subscription.currency, home, rate),
    });
  }
  cycleCases.push({ id, input: clean({ subscription, home, rate, confirms }), output: clean(steps) });
  if (encode(exactSteps) === encode(steps)) return;
  const reasons = [];
  if (exactSteps.some((step, index) => step.nextDueDate !== steps[index]?.nextDueDate || step.lastConfirmedDate !== steps[index]?.lastConfirmedDate)) {
    reasons.push('latest confirmed cycle wins');
  }
  if (exactSteps.some((step, index) => encode(step.homeAmountMinor) !== encode(steps[index]?.homeAmountMinor))) reasons.push(exponentReason(subscription.currency, home));
  diverge('cycle.json', 'confirmSubscriptionCycle', id, reasons.join(', '), steps, exactSteps);
};

const chain = (subscription: CycleSubscription, count: number): string[] => {
  const dates = [subscription.nextDueDate];
  while (dates.length < count) dates.push(advance(subscription, dates.at(-1) as string));
  return dates;
};
const monthly31: CycleSubscription = { frequency: 'monthly', billingDay: 31, customIntervalDays: null, nextDueDate: '2026-01-31', amountMinor: 19_900, currency: 'EUR' };
await cycleCase('spec:monthly-31', monthly31, 'EUR', null, chain(monthly31, 6));
await cycleCase('spec:duplicate', monthly31, 'EUR', null, ['2026-01-31', '2026-01-31', '2026-02-28', '2026-02-28']);
await cycleCase('spec:out-of-order', monthly31, 'EUR', null, ['2026-01-31', '2026-02-28', '2026-01-31', '2026-03-31', '2026-02-28']);
await cycleCase('spec:late-earlier-cycle', monthly31, 'EUR', null, ['2026-03-31', '2026-01-31']);
await cycleCase('spec:before-anchor', monthly31, 'EUR', null, ['2025-12-31', '2026-01-31']);
const weekly: CycleSubscription = { frequency: 'weekly', billingDay: 1, customIntervalDays: null, nextDueDate: '2026-08-10', amountMinor: 999, currency: 'USD' };
await cycleCase('spec:weekly-usd', weekly, 'EUR', '0.9213', chain(weekly, 5));
const leapYearly: CycleSubscription = { frequency: 'yearly', billingDay: 29, customIntervalDays: null, nextDueDate: '2024-02-29', amountMinor: 12_000, currency: 'NOK' };
await cycleCase('spec:yearly-leap', leapYearly, 'NOK', null, chain(leapYearly, 5));
const quarterly: CycleSubscription = { frequency: 'quarterly', billingDay: 31, customIntervalDays: null, nextDueDate: '2025-11-30', amountMinor: 30_000, currency: 'GBP' };
await cycleCase('spec:quarterly-gbp', quarterly, 'EUR', '1.1712', chain(quarterly, 5));
const custom45: CycleSubscription = { frequency: 'custom', billingDay: 1, customIntervalDays: 45, nextDueDate: '2026-01-01', amountMinor: 4_500, currency: 'EUR' };
await cycleCase('spec:custom-45', custom45, 'EUR', null, chain(custom45, 4));
const customDefault: CycleSubscription = { frequency: 'custom', billingDay: 1, customIntervalDays: null, nextDueDate: '2026-01-01', amountMinor: 4_500, currency: 'EUR' };
await cycleCase('spec:custom-default', customDefault, 'EUR', null, chain(customDefault, 3));
const yen: CycleSubscription = { frequency: 'monthly', billingDay: 15, customIntervalDays: null, nextDueDate: '2026-01-15', amountMinor: 1_480, currency: 'JPY' };
await cycleCase('spec:yen-to-euro', yen, 'EUR', '0.0061', chain(yen, 3));
const euroToYen: CycleSubscription = { frequency: 'monthly', billingDay: 15, customIntervalDays: null, nextDueDate: '2026-01-15', amountMinor: 999, currency: 'EUR' };
await cycleCase('spec:euro-to-yen', euroToYen, 'JPY', '163.42', chain(euroToYen, 3));
{
  const next = lcg(0x4d31_3004);
  for (let index = 0; index < 100; index++) {
    const frequency = pick(next, FREQUENCIES);
    const billingDay = between(next, 1, 31);
    const year = between(next, 2023, 2027);
    const month = between(next, 1, 12);
    const days = Number(financeRules.financePeriod('month', `${year}-${String(month).padStart(2, '0')}-01`).end.slice(8));
    const subscription: CycleSubscription = {
      frequency,
      billingDay,
      customIntervalDays: frequency === 'custom' ? pick(next, [null, 1, 7, 14, 30, 31, 45, 90, 365]) : null,
      nextDueDate: `${year}-${String(month).padStart(2, '0')}-${String(Math.min(billingDay, days)).padStart(2, '0')}`,
      amountMinor: between(next, 0, 50_000),
      currency: pick(next, ['EUR', 'USD', 'NOK', 'GBP'] as const),
    };
    const home = pick(next, ['EUR', 'USD', 'NOK'] as const);
    const confirms = chain(subscription, between(next, 1, 6));
    if (next() < 0.25) confirms.push(pick(next, confirms));
    await cycleCase(`seeded#${index}`, subscription, home, subscription.currency === home || next() < 0.2 ? null : randomRate(next), confirms);
  }
}
fixture('cycle.json', { confirmSubscriptionCycle: cycleCases });

const exponents: Record<string, number> = {};
for (const code of CURRENCY_CODES as readonly string[]) exponents[code] = exponentOf(code);
writeJson('currencies.json', `${JSON.stringify({ codes: CURRENCY_CODES, exponents }, null, 2)}\n`);

writeJson('divergences.json', `{\n"count": ${divergences.length},\n"cases": [\n${divergences.map(item => encode(item)).join(',\n')}\n]\n}\n`);
console.log(
  `conversion ${conversionCases.length}+${reconcileCases.length}, monthly ${monthlyCases.length}, budget ${budgetCases.length}+${onboardCases.length}, cycle ${cycleCases.length}, divergences ${divergences.length}`,
);
