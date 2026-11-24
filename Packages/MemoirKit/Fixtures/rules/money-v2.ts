// Money in the game, ruleset v2: native rules with no reference counterpart, written out here as the literal input `generate.ts` turns into
// `ruleset-v2.json`. Every table is the standard intensity's; low and high intensity multiply its XP, coins, fines and debuff days by
// `intensityScale` (thousandths) and round the exact product half up (1.5 -> 2, 10.5 -> 11), as the rules round elsewhere. Debuff multipliers do
// not scale.

export const intensityScale = { standard: 1000, low_intensity: 500, high_intensity: 1500 } as const;

export type Reward = { xp: number; coins: number };
export type Effect = ({ kind: 'reward' } & Reward) | { kind: 'penalty'; fine: number; multiplier: number; days: number };

export const standardDailyLog: Reward = { xp: 3, coins: 0 };

export const standardClose: Record<string, Effect> = {
  within_typical: { kind: 'reward', xp: 40, coins: 8 },
  within: { kind: 'reward', xp: 20, coins: 3 },
  over_10: { kind: 'penalty', fine: 15, multiplier: 850, days: 7 },
  over_25: { kind: 'penalty', fine: 30, multiplier: 750, days: 14 },
  over_more: { kind: 'penalty', fine: 60, multiplier: 600, days: 30 },
  unscored: { kind: 'penalty', fine: 60, multiplier: 600, days: 30 },
};

export const standardMilestones: Record<string, Reward> = {
  p25: { xp: 10, coins: 0 },
  p50: { xp: 10, coins: 0 },
  p75: { xp: 15, coins: 0 },
  p100: { xp: 30, coins: 5 },
};

export const standardGoalPurchase: Record<string, Reward> = { within: { xp: 30, coins: 5 }, over: { xp: 0, coins: 0 } };

export const moneyV2 = {
  lateDays: 2,
  weekAnchorWeekday: 1,
  weekMinCovered: 5,
  coverageThreshold: { thousandths: 600 },
  closeGraceDays: 3,
  pendingHoldDays: 7,
};
