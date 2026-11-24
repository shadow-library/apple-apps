// Money in the game (ruleset v2) is native: the reference has no money commands, so these replay vectors are literal. Each case is a list of native
// steps and the outcome a reader works out by hand from Fixtures/rules/money-v2.ts and ruleset v1's quick-log and quest tables, with the reason it
// holds. Run with `bun Packages/MemoirKit/Fixtures/money/generate.ts`; it reads nothing and writes `vectors.json`, one case per line.
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

type Json = null | boolean | number | string | Json[] | { [key: string]: Json };

type Step = {
  at: string;
  type: string;
  payload?: { [key: string]: Json };
  occurrence?: { quest: string; date: string };
  rulesetVersion?: number;
  /** The command's place in clock order when it is not its place in the list: a command delivered late. */
  clock?: number;
};

type Outcome = { status: 'applied' | 'superseded' | 'refused' | 'horizon'; code?: string };

type Reward = { xp: number; coins: number };
type Close = {
  budget: string;
  periodStart: string;
  outcome: string;
  deposited: boolean;
  closedOn: string;
  reward?: Reward;
  fine?: { intended: number; applied: number; multiplier: number; from: string; through: string };
};

/** Only the members a case names are compared. */
type State = {
  hero?: Reward;
  coveredDays?: { date: string; source: 'expense' | 'no_spend' }[];
  weekStreak?: number;
  lastSettledWeekStart?: string | null;
  savingStreak?: number;
  lastActivityDay?: string | null;
  closes?: Close[];
  /** The debuff multiplier on each date, in thousandths, or null where none is in force. */
  debuffs?: { [date: string]: number | null };
  returners?: { date: string; lastActiveDate: string; daysAbsent: number }[];
  notices?: number;
  achievements?: string[];
  logs?: { quest: string; date: string; xp: number }[];
  moneyEvents?: { key: string; type: string; date: string; xp: number; coins: number }[];
};

type Case = { id: string; reason: string; steps: Step[]; expected: { steps: Outcome[]; state: State } };

const at = (date: string, time = '09:00') => `${date}T${time}:00Z`;
const noSpend = (on: string, date: string, time?: string, extra: Partial<Step> = {}): Step => ({
  at: at(on, time),
  type: 'money.noSpend',
  payload: { date },
  ...extra,
});
const expense = (on: string, id: string, occurredOn: string | null, time?: string, extra: Partial<Step> = {}): Step => ({
  at: at(on, time),
  type: 'expense.create',
  payload: occurredOn === null ? { id, source: 'manual' } : { id, source: 'manual', occurredOn },
  ...extra,
});
const close = (on: string, budget: string, periodStart: string, outcome: string, deposited: boolean, time?: string, extra: Partial<Step> = {}): Step => ({
  at: at(on, time),
  type: 'budget.closePeriod',
  payload: { budgetId: budget, periodStart, outcome, deposited },
  ...extra,
});
const sideQuest = (on: string, id: string, time?: string, extra: Partial<Step> = {}): Step => ({
  at: at(on, time),
  type: 'sidequest.log',
  payload: { id, draft: { date: on } },
  ...extra,
});
const journal = (on: string, id: string, time?: string): Step => ({ at: at(on, time), type: 'journal.save', payload: { id, draft: { date: on } } });
const horizon = (on: string, time?: string): Step => ({ at: at(on, time), type: 'horizon' });
const intensity = (on: string, mode: string): Step => ({ at: at(on), type: 'account.setIntensityMode', payload: { intensityMode: mode } });
const routine = (on: string, id: string): Step => ({
  at: at(on, '06:00'),
  type: 'quest.create',
  payload: {
    questId: id,
    statAffinity: 'body',
    recurrence: { frequency: 'daily', interval: 1, startDate: '2026-03-01', end: { kind: 'never' } },
    strictness: 'routine',
    startTimeMinutes: 480,
    durationMinutes: 60,
  },
});
const complete = (on: string, quest: string): Step => ({ at: at(on, '08:30'), type: 'quest.complete', occurrence: { quest: quest.replace(/^@/, ''), date: on }, payload: {} });
const days = (from: string, count: number) => Array.from({ length: count }, (_, i) => new Date(Date.parse(`${from}T00:00:00Z`) + i * 86_400_000).toISOString().slice(0, 10));

const applied: Outcome = { status: 'applied' };
const superseded: Outcome = { status: 'superseded' };
const walked: Outcome = { status: 'horizon' };
const refused = (code: string): Outcome => ({ status: 'refused', code });
const OUTSIDE = 'memoir_replay.outside_logging_window';
const NEWER = 'memoir_replay.needs_newer_ruleset';
const log = (date: string, xp: number) => ({ key: `moneylog_${date}`, type: 'money_log', date, xp, coins: 0 });

const fullWeek = days('2026-03-02', 5).map((day) => noSpend(day, day));
const keptOnceThenDeleted: Step[] = [
  routine('2026-03-01', '@q1'),
  complete('2026-03-01', '@q1'),
  { at: at('2026-03-02', '06:00'), type: 'quest.delete', payload: { questId: '@q1' } },
];

const cases: Case[] = [
  {
    id: 'logging-covers-a-day-within-the-late-window',
    reason:
      'a day is covered by logging on it or at most two days later and never ahead; the first cover earns the 3 XP daily log, later ones nothing; an expense outside the ' +
      'window is still taken in',
    steps: [
      noSpend('2026-03-05', '2026-03-05', '09:00'),
      noSpend('2026-03-05', '2026-03-03', '09:05'),
      noSpend('2026-03-05', '2026-03-02', '09:10'),
      noSpend('2026-03-05', '2026-03-06', '09:15'),
      noSpend('2026-03-05', '2026-03-05', '09:20'),
      expense('2026-03-05', '@e1', '2026-03-04', '09:25'),
      expense('2026-03-05', '@e2', '2026-03-04', '09:30'),
      expense('2026-03-05', '@e3', '2026-03-01', '09:35'),
    ],
    expected: {
      steps: [applied, applied, refused(OUTSIDE), refused(OUTSIDE), superseded, applied, applied, applied],
      state: {
        hero: { xp: 9, coins: 0 },
        coveredDays: [
          { date: '2026-03-03', source: 'no_spend' },
          { date: '2026-03-04', source: 'expense' },
          { date: '2026-03-05', source: 'no_spend' },
        ],
        lastActivityDay: '2026-03-05',
        moneyEvents: [log('2026-03-05', 3), log('2026-03-03', 3), log('2026-03-04', 3)],
      },
    },
  },
  {
    id: 'the-daily-log-follows-the-covered-days-intensity',
    reason:
      'the log XP scales with the intensity of the day it covers: high intensity takes effect the day after it is set and gives 3 x 1.5 = 4.5, rounded half up to 5; the day ' +
      'before keeps standard 3',
    steps: [intensity('2026-03-04', 'high_intensity'), noSpend('2026-03-05', '2026-03-05'), noSpend('2026-03-05', '2026-03-04', '09:05')],
    expected: { steps: [applied, applied, applied], state: { hero: { xp: 8, coins: 0 }, moneyEvents: [log('2026-03-05', 5), log('2026-03-04', 3)] } },
  },
  {
    id: 'commands-from-an-older-device-cover-nothing',
    reason:
      'a v1 expense.create names no day and is not money activity; a money body stamped v1 is refused as needing ruleset 2; only the v2 command covers and counts as activity',
    steps: [
      expense('2026-03-05', '@e1', null, '09:00', { rulesetVersion: 1 }),
      noSpend('2026-03-05', '2026-03-05', '09:05', { rulesetVersion: 1 }),
      expense('2026-03-05', '@e2', '2026-03-05', '09:10', { rulesetVersion: 1 }),
      noSpend('2026-03-06', '2026-03-06'),
    ],
    expected: {
      steps: [applied, refused(NEWER), refused(NEWER), applied],
      state: { hero: { xp: 3, coins: 0 }, coveredDays: [{ date: '2026-03-06', source: 'no_spend' }], lastActivityDay: '2026-03-06' },
    },
  },
  {
    id: 'a-week-settles-only-once-the-late-window-after-it-has-closed',
    reason:
      'five covered days of the week from Monday 2 March; that week settles when Tuesday 10 March closes, which the walk to 10 March has not done; the close of Tuesday 3 ' +
      'March, after the first money activity, settled the empty week before',
    steps: [...fullWeek, horizon('2026-03-10')],
    expected: { steps: [...fullWeek.map(() => applied), walked], state: { weekStreak: 0, lastSettledWeekStart: '2026-02-23' } },
  },
  {
    id: 'a-week-with-five-covered-days-extends-the-money-streak',
    reason: 'the walk to 11 March closes Tuesday 10 March, settling the week from 2 March with 5 of 7 days covered',
    steps: [...fullWeek, horizon('2026-03-11')],
    expected: { steps: [...fullWeek.map(() => applied), walked], state: { weekStreak: 1, lastSettledWeekStart: '2026-03-02', hero: { xp: 15, coins: 0 } } },
  },
  {
    id: 'a-day-covered-late-counts-for-its-week',
    reason: 'Sunday 8 March is covered on Tuesday 10 March, two days late, before the week settles at the close of that Tuesday',
    steps: [...days('2026-03-04', 4).map((day) => noSpend(day, day)), noSpend('2026-03-10', '2026-03-08'), horizon('2026-03-11')],
    expected: { steps: [applied, applied, applied, applied, applied, walked], state: { weekStreak: 1, lastSettledWeekStart: '2026-03-02' } },
  },
  {
    id: 'a-short-week-resets-the-money-streak',
    reason: 'the week from 2 March extends the streak to 1; the week from 9 March has 4 covered days, so its settlement at the close of 17 March resets it',
    steps: [...fullWeek, ...days('2026-03-09', 4).map((day) => noSpend(day, day)), horizon('2026-03-18')],
    expected: { steps: [...fullWeek.map(() => applied), applied, applied, applied, applied, walked], state: { weekStreak: 0, lastSettledWeekStart: '2026-03-09' } },
  },
  {
    id: 'two-full-weeks-make-a-streak-of-two',
    reason: 'both weeks from 2 and 9 March have five covered days and settle in turn',
    steps: [...fullWeek, ...days('2026-03-09', 5).map((day) => noSpend(day, day)), horizon('2026-03-18')],
    expected: { steps: [...fullWeek.map(() => applied), applied, applied, applied, applied, applied, walked], state: { weekStreak: 2, lastSettledWeekStart: '2026-03-09' } },
  },
  {
    id: 'an-absence-past-the-catch-up-limit-settles-only-the-weeks-it-walks',
    reason:
      'after the streak reaches 1, the walk to 22 June closes only the 90 days before it; the weeks it settles have nothing covered, and the latest it settles starts on 8 June',
    steps: [...fullWeek, horizon('2026-03-11'), horizon('2026-06-22')],
    expected: { steps: [...fullWeek.map(() => applied), walked, walked], state: { weekStreak: 0, lastSettledWeekStart: '2026-06-08' } },
  },
  {
    id: 'closes-within-the-limit-reward-and-count-once',
    reason:
      'within gives 20 XP and 3 coins and its deposit extends the saving streak; within_typical gives 40 XP and 8 coins, and a close within the limit without a ' +
      'deposit (a trip) leaves the saving streak as it was; a second close of the same period is superseded and changes nothing',
    steps: [
      close('2026-03-04', '@home', '2026-02-01', 'within', true, '09:00'),
      close('2026-03-04', '@trip', '2026-02-10', 'within_typical', false, '09:05'),
      close('2026-03-04', '@home', '2026-02-01', 'over_more', false, '09:10'),
    ],
    expected: {
      steps: [applied, applied, superseded],
      state: {
        hero: { xp: 60, coins: 11 },
        savingStreak: 1,
        lastActivityDay: '2026-03-04',
        closes: [
          { budget: 'home', periodStart: '2026-02-01', outcome: 'within', deposited: true, closedOn: '2026-03-04', reward: { xp: 20, coins: 3 } },
          { budget: 'trip', periodStart: '2026-02-10', outcome: 'within_typical', deposited: false, closedOn: '2026-03-04', reward: { xp: 40, coins: 8 } },
        ],
      },
    },
  },
  {
    id: 'a-deposit-streak-counts-consecutive-deposits',
    reason: 'two closes in a row that deposited',
    steps: [close('2026-03-04', '@home', '2026-01-01', 'within', true, '09:00'), close('2026-03-04', '@home', '2026-02-01', 'within_typical', true, '09:05')],
    expected: { steps: [applied, applied], state: { savingStreak: 2, hero: { xp: 60, coins: 11 } } },
  },
  {
    id: 'only-a-close-over-the-limit-or-unscored-breaks-the-saving-streak',
    reason:
      'two deposits make a streak of 2; a within close without a deposit (a calibration month) keeps it; over_10 resets it to 0; a deposit starts it again at 1; ' +
      'an unscored close resets it to 0',
    steps: [
      close('2026-03-04', '@home', '2026-01-01', 'within', true, '09:00'),
      close('2026-03-04', '@trip', '2026-01-10', 'within_typical', true, '09:05'),
      close('2026-03-04', '@cafe', '2026-01-01', 'within', false, '09:10'),
      close('2026-03-04', '@home', '2026-02-01', 'over_10', false, '09:15'),
      close('2026-03-04', '@cafe', '2026-02-01', 'within', true, '09:20'),
      close('2026-03-04', '@trip', '2026-02-10', 'unscored', false, '09:25'),
    ],
    expected: { steps: [applied, applied, applied, applied, applied, applied], state: { savingStreak: 0 } },
  },
  {
    id: 'a-deposit-after-an-overspent-close-starts-the-saving-streak-again',
    reason: 'over_25 resets the saving streak; the deposit after it makes it 1, and a trip within its limit without a deposit keeps it at 1',
    steps: [
      close('2026-03-04', '@home', '2026-01-01', 'within', true, '09:00'),
      close('2026-03-04', '@home', '2026-02-01', 'over_25', false, '09:05'),
      close('2026-03-04', '@cafe', '2026-02-01', 'within_typical', true, '09:10'),
      close('2026-03-04', '@trip', '2026-02-10', 'within', false, '09:15'),
    ],
    expected: { steps: [applied, applied, applied, applied], state: { savingStreak: 1 } },
  },
  {
    id: 'a-fine-takes-at-most-the-balance',
    reason:
      'three side quests give 24 XP and 3 coins; over_10 fines 15 coins, of which the balance allows 3, and debuffs XP to 850 thousandths for 7 days from the close day',
    steps: [
      sideQuest('2026-03-03', '@s1', '09:00'),
      sideQuest('2026-03-03', '@s2', '09:05'),
      sideQuest('2026-03-03', '@s3', '09:10'),
      close('2026-03-04', '@home', '2026-02-01', 'over_10', false),
    ],
    expected: {
      steps: [applied, applied, applied, applied],
      state: {
        hero: { xp: 24, coins: 0 },
        closes: [
          {
            budget: 'home',
            periodStart: '2026-02-01',
            outcome: 'over_10',
            deposited: false,
            closedOn: '2026-03-04',
            fine: { intended: 15, applied: 3, multiplier: 850, from: '2026-03-04', through: '2026-03-10' },
          },
        ],
        debuffs: { '2026-03-03': null, '2026-03-04': 850, '2026-03-10': 850, '2026-03-11': null },
        moneyEvents: [{ key: 'moneyfine_home_2026-02-01', type: 'money_fine', date: '2026-03-04', xp: 0, coins: -3 }],
      },
    },
  },
  {
    id: 'a-debuff-cuts-xp-grants-dated-under-it',
    reason:
      'over_more debuffs to 600 thousandths for 30 days (4 March to 2 April): a journal entry earns floor(5 x 0.6) = 3, a side quest floor(8 x 0.6) = 4 and keeps its coin, ' +
      'the daily log floor(3 x 0.6) = 1; a side quest stamped v1 is not debuffed (8); a journal entry on 3 April, after the debuff, earns 5',
    steps: [
      close('2026-03-04', '@home', '2026-02-01', 'over_more', false, '09:00'),
      journal('2026-03-04', '@j1', '09:05'),
      sideQuest('2026-03-04', '@s1', '09:10'),
      noSpend('2026-03-04', '2026-03-04', '09:15'),
      sideQuest('2026-03-05', '@s2', '09:00', { rulesetVersion: 1 }),
      journal('2026-04-03', '@j2'),
    ],
    expected: { steps: [applied, applied, applied, applied, applied, applied], state: { hero: { xp: 21, coins: 2 }, moneyEvents: [
      { key: 'moneyfine_home_2026-02-01', type: 'money_fine', date: '2026-03-04', xp: 0, coins: 0 },
      log('2026-03-04', 1),
    ] } },
  },
  {
    id: 'debuffs-never-stack',
    reason:
      'over_more (600, 4 March to 2 April) then over_10 (850, 30 March to 5 April): the stronger multiplier holds while both cover a day, the later end holds after it; side ' +
      'quests earn floor(8 x 0.6) = 4 on 31 March and floor(8 x 0.85) = 6 on 4 April',
    steps: [
      close('2026-03-04', '@home', '2026-02-01', 'over_more', false),
      close('2026-03-30', '@trip', '2026-03-01', 'over_10', false),
      sideQuest('2026-03-31', '@s1'),
      sideQuest('2026-04-04', '@s2'),
    ],
    expected: {
      steps: [applied, applied, applied, applied],
      state: { hero: { xp: 10, coins: 2 }, debuffs: { '2026-04-02': 600, '2026-04-03': 850, '2026-04-05': 850, '2026-04-06': null } },
    },
  },
  {
    id: 'a-quest-completion-under-a-debuff',
    reason: 'a routine quest kept on time earns 10 XP; under over_more it earns floor(10 x 0.6) = 6, recorded on the log and the trail alike',
    steps: [routine('2026-03-01', '@q1'), close('2026-03-02', '@home', '2026-02-01', 'over_more', false, '07:00'), complete('2026-03-02', '@q1')],
    expected: { steps: [applied, applied, applied], state: { logs: [{ quest: 'q1', date: '2026-03-02', xp: 6 }] } },
  },
  {
    id: 'intensity-scales-a-penalty',
    reason: 'low intensity, in force from the day after it is set, halves over_25 to a 15-coin fine and 7 debuff days at 750 thousandths',
    steps: [intensity('2026-03-03', 'low_intensity'), close('2026-03-04', '@home', '2026-02-01', 'over_25', false)],
    expected: {
      steps: [applied, applied],
      state: {
        closes: [
          {
            budget: 'home',
            periodStart: '2026-02-01',
            outcome: 'over_25',
            deposited: false,
            closedOn: '2026-03-04',
            fine: { intended: 15, applied: 0, multiplier: 750, from: '2026-03-04', through: '2026-03-10' },
          },
        ],
      },
    },
  },
  {
    id: 'a-penalty-resets-the-money-streak',
    reason: 'the week from 2 March settles to a streak of 1; an over_10 close on 11 March resets it',
    steps: [...fullWeek, horizon('2026-03-11'), close('2026-03-11', '@home', '2026-02-01', 'over_10', false)],
    expected: { steps: [...fullWeek.map(() => applied), walked, applied], state: { weekStreak: 0, lastSettledWeekStart: '2026-03-02' } },
  },
  {
    id: 'goal-rewards-count-once-per-goal-and-milestone',
    reason: 'milestones give 10, 10, 15 and 30 XP with 5 coins at 100%; a repeated milestone or a second purchase is superseded; a purchase within target gives 30 XP and 5 coins',
    steps: [
      { at: at('2026-03-04', '09:00'), type: 'goal.milestone', payload: { goalId: '@bike', milestone: 'p25' } },
      { at: at('2026-03-04', '09:05'), type: 'goal.milestone', payload: { goalId: '@bike', milestone: 'p25' } },
      { at: at('2026-03-04', '09:10'), type: 'goal.milestone', payload: { goalId: '@bike', milestone: 'p50' } },
      { at: at('2026-03-04', '09:15'), type: 'goal.milestone', payload: { goalId: '@bike', milestone: 'p75' } },
      { at: at('2026-03-04', '09:20'), type: 'goal.milestone', payload: { goalId: '@bike', milestone: 'p100' } },
      { at: at('2026-03-04', '09:25'), type: 'goal.bought', payload: { goalId: '@bike', outcome: 'within' } },
      { at: at('2026-03-04', '09:30'), type: 'goal.bought', payload: { goalId: '@bike', outcome: 'over' } },
    ],
    expected: { steps: [applied, superseded, applied, applied, applied, applied, superseded], state: { hero: { xp: 95, coins: 10 }, achievements: [] } },
  },
  {
    id: 'money-xp-earns-achievements',
    reason: 'two rewarded closes and a goal give 40 + 20 + 30 + 30 = 120 XP, past level 2 at 100: the money handlers run the achievement checks',
    steps: [
      close('2026-03-04', '@home', '2026-01-01', 'within_typical', true, '09:00'),
      close('2026-03-04', '@home', '2026-02-01', 'within', true, '09:05'),
      { at: at('2026-03-04', '09:10'), type: 'goal.milestone', payload: { goalId: '@bike', milestone: 'p100' } },
      { at: at('2026-03-04', '09:15'), type: 'goal.bought', payload: { goalId: '@bike', outcome: 'within' } },
    ],
    expected: { steps: [applied, applied, applied, applied], state: { hero: { xp: 120, coins: 21 }, achievements: ['first_level_up', 'xp_100'] } },
  },
  {
    id: 'money-activity-keeps-a-former-quest-keeper-from-returning',
    reason:
      'a quest kept on 1 March and deleted, then money logged every day: the Returner measures the absence from the later of the last quest day and the last money day, so ' +
      'it never reaches 7 days',
    steps: [...keptOnceThenDeleted, ...days('2026-03-02', 14).map((day) => noSpend(day, day)), horizon('2026-03-16')],
    expected: { steps: [applied, applied, applied, ...days('2026-03-02', 14).map(() => applied), walked], state: { returners: [] } },
  },
  {
    id: 'without-money-activity-a-former-quest-keeper-returns',
    reason: 'the same vault logs money only on 2 March, so on 12 March the absence is 10 days from 2 March and the Returner fires',
    steps: [...keptOnceThenDeleted, noSpend('2026-03-02', '2026-03-02'), horizon('2026-03-12')],
    expected: { steps: [applied, applied, applied, applied, walked], state: { returners: [{ date: '2026-03-12', lastActiveDate: '2026-03-02', daysAbsent: 10 }] } },
  },
  {
    id: 'a-vault-without-money-activity-settles-no-week',
    reason: 'quests alone never settle a money week, so a vault that never logged money keeps no money state',
    steps: [routine('2026-03-01', '@q1'), complete('2026-03-01', '@q1'), horizon('2026-03-20')],
    expected: { steps: [applied, applied, walked], state: { weekStreak: 0, lastSettledWeekStart: null, lastActivityDay: null, coveredDays: [] } },
  },
  {
    id: 'a-vault-that-never-kept-a-quest-never-returns',
    reason: 'money activity alone never starts the Returner, however long the absence',
    steps: [noSpend('2026-03-02', '2026-03-02'), horizon('2026-03-20')],
    expected: { steps: [applied, walked], state: { returners: [], lastActivityDay: '2026-03-02' } },
  },
  {
    id: 'a-late-earlier-close-takes-the-period',
    reason: 'a close clocked earlier but delivered after another close of the same period wins in replay order; the one taken first is superseded',
    steps: [
      close('2026-03-05', '@home', '2026-02-01', 'within', true, '09:00', { clock: 2 }),
      close('2026-03-04', '@home', '2026-02-01', 'over_more', false, '09:00', { clock: 1 }),
    ],
    expected: {
      steps: [superseded, applied],
      state: {
        hero: { xp: 0, coins: 0 },
        savingStreak: 0,
        closes: [
          {
            budget: 'home',
            periodStart: '2026-02-01',
            outcome: 'over_more',
            deposited: false,
            closedOn: '2026-03-04',
            fine: { intended: 60, applied: 0, multiplier: 600, from: '2026-03-04', through: '2026-04-02' },
          },
        ],
      },
    },
  },
  {
    id: 'a-late-fine-withdraws-a-later-purchase',
    reason:
      'seven within_typical closes give 56 coins and a 50-coin badge is bought; a fine clocked before the purchase arrives late and takes all 56, so the purchase no longer ' +
      'fits (HRO_001) and the owner is told',
    steps: [
      ...['@b1', '@b2', '@b3', '@b4', '@b5', '@b6', '@b7'].map((budget, i) => close('2026-03-02', budget, '2026-02-01', 'within_typical', false, `09:0${i}`, { clock: i + 1 })),
      { at: at('2026-03-05'), type: 'cosmetic.purchase', payload: { cosmeticId: 'badge_bronze' }, clock: 9 },
      close('2026-03-04', '@b8', '2026-02-01', 'over_more', false, '09:00', { clock: 8 }),
    ],
    expected: {
      steps: [applied, applied, applied, applied, applied, applied, applied, refused('memoir_replay.hro_001'), applied],
      state: { hero: { xp: 280, coins: 0 }, notices: 1 },
    },
  },
];

const outDir = dirname(fileURLToPath(import.meta.url));
for (const c of cases) {
  if (c.steps.length !== c.expected.steps.length) throw new Error(`${c.id}: ${c.steps.length} steps, ${c.expected.steps.length} outcomes`);
}
if (new Set(cases.map((c) => c.id)).size !== cases.length) throw new Error('case ids repeat');
writeFileSync(join(outDir, 'vectors.json'), cases.map((c) => JSON.stringify(c)).join('\n') + '\n');
