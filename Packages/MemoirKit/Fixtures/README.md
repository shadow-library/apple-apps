# Reference fixtures

Data generated from the TypeScript reference server, so the Swift port can be checked against what the reference does.

- The reference is `/Users/leander-paul/repositories/shadow-library/platform/apps/memoir-server`; generators take its checkout through `PLATFORM_REPO=<path to the platform checkout>`.
- Fixtures live in `Packages/MemoirKit/Fixtures/<area>/`, outside every target, so SwiftPM ignores them.
- Each area has a generator (`generate.ts`); run it with `PLATFORM_REPO=<path> bun Packages/MemoirKit/Fixtures/<area>/generate.ts`.
- Generators import the reference read-only and compute every expected output by calling the reference; none of its logic is re-implemented, except as the exact model below.
- Generators are deterministic: their own seeded generator, no clock, no `Math.random`, and only repository-relative paths in their output; no machine path appears in a fixture.
- The outputs are committed; rerun the generator and commit again when the reference changes.
- The reference checkout is read, never written: no install, build or output file inside it.

## rules

```sh
PLATFORM_REPO=<path to the platform checkout> bun Packages/MemoirKit/Fixtures/rules/generate.ts
```

- Imports `apps/memoir-server/src/modules/rules/index.ts`, which imports only its siblings, so no module is mocked.
- Inputs are every literal input of `tests/rules/*.spec.ts` except the calendar specs (`time`, `recurrence`, `account-today`); the finite domains (reward over strictness, band, completion, tier, lock and one-shot; timing bands for every minute and elapsed days −1 to 5; levels 1 to 999 and every threshold ±1; streak, HP and Crown grids; achievement and title thresholds ±1); and the seeded cases of `properties.spec.ts`, drawn with its LCG, seeds, run count and draw order.
- Each `<rule>.json` maps a reference function to its cases, one per line: `{"id", "input", "output"}`, the output always from the reference.
- `divergences.json` lists every case where the reference's float result differs from an exact `BigInt` rational model of the same rule (decimal constants read as exact decimals, a fractional field agreeing only when the float is the nearest double to the exact value), with the fields that differ and the exact output, fractions written `{"fraction": [n, d]}`. Rules with no fractional arithmetic are their own exact model.
- `ruleset-v1.json` is the reference's `RULESET_V1` in the native exact units and key names, as canonical JSON with its SHA-256.
- The generator also writes `Sources/MemoirCore/Rules/LevelCurve+V1.swift`, the level table, and stops if the reference's curve and the exact model ever disagree on a level.

## calendar

```sh
PLATFORM_REPO=<path to the platform checkout> bun Packages/MemoirKit/Fixtures/calendar/generate.ts
```

- Imports `src/modules/rules/index.ts` and `src/modules/finance/subscription-cycle.ts`, with `@modules/rules`, `@shadow-library/common` (`AppError`) and `@server/database` mocked for the latter.
- Inputs are every literal input of `tests/rules/time.spec.ts`, `recurrence.spec.ts`, `account-today.spec.ts` and `tests/finance/subscription-cycle.spec.ts`, including the windows and cursors their loops visit, then seeded grids: civil dates from 1900 to 2100 (`time.json`), 700 seeded rules with real and made-up cursors (`recurrence.json`), and every frequency and billing day (`subscription.json`).
- `zones.json` holds the zone cases, limited to a fixed list of 20 zones (half-hour and 45-minute offsets, midnight transitions, negative DST, abolished DST) and to 2015 to 2030, so that Node ICU and Apple's tz data agree on the rules: offsets and fields around every transition, local minutes on both sides of every gap and fold, day starts and lengths, `clampPerformedAt` and `accountToday`. Zone case ids name the zone and input, so they stay stable.
- `zone-exclusions.json` lists every zone case where Foundation's `TimeZone` disagrees with ICU, each with its reason, and the tests skip those. Checked against macOS 27.2.1 tzdata, it lists the America/Havana cases from 2026-11, where the system rule is newer than ICU 78.1. After an OS update the zone vectors can fail; the failure message names the mismatching ids and their function. Confirm each is a tz-data difference (replay never reads `TimeZone`), add it with a reason and update `tzdata` and `count`, and rerun `swift test --package-path Packages/MemoirKit --filter IssueClockVector`. Never regenerate `zones.json` with a different ICU, and never widen the zone list until one passes.
- `divergences.json` lists the reference's `epochDayOf` for years 0 to 99, where `Date.UTC` reads the year as 1900 to 1999; the native civil arithmetic counts the real year. The tests check the exact value.
- Not represented, because the native code refuses these inputs:
  - negative years and years past 9999, since `LocalDate` holds only 0000 to 9999;
  - a monthly day of month below 1 or a weekly rule without weekdays, which the reference accepts and turns into dates that do not exist (`RecurrenceRule` throws);
  - a minute of the day outside 0 to 1439, which the reference rolls into the neighbouring day (`IssueClock.resolve` throws);
  - a billing day outside 1 to 31, which only the reference's database check refuses (`SubscriptionCycle` throws).

## finance

```sh
PLATFORM_REPO=<path to the platform checkout> bun --tsconfig-override "$PLATFORM_REPO/apps/memoir-server/tsconfig.json" Packages/MemoirKit/Fixtures/finance/generate.ts
```

- Imports `src/modules/finance/index.ts`, `src/modules/account/account.service.ts` and `src/classes/enum.dto.ts` with their real dependencies (the tsconfig override resolves the server's aliases; `telemetry.pseudo-id-secret` is set through `@shadow-library/common/testing`), and memoir-web's `lib/data/finance.rules.ts` and `finance.types.ts` with `@shadow-library/ui` and `@/lib/format` mocked. Repositories, the database transaction and the rates provider are in-memory fakes, as in `tests/finance/finance-commands-currency.spec.ts`.
- `conversion.json`: `captureFx` (the expression the reference also uses on an amount edit and in its sweep) over edge pairs, amounts and rates and a seeded grid of every accepted currency into six home currencies; `reconcile` runs `FxReconciliationService.run` over scripted provider answers, which the native `RateFiller` replays. Provider rates are written as the reference's own `String(rate)`.
- `monthly-equivalent.json`: `monthlyEquivalentMinor` read back from `subscription.create`, for every frequency, amounts up to 2^53 − 1 and custom intervals including 0 and −3.
- `budget.json`: memoir-web `budgetStanding` over expenses whose stored home amount comes from the server's `captureFx`, and `onboard` from `AccountService.onboard` (a default-currency change clears the budget).
- `cycle.json`: sequences of `subscription.confirmCycle` against one subscription, with the next due date, the last confirmed date, whether an expense was inserted, and its home amount after each step.
- `currencies.json`: the accepted codes (`CURRENCY_CODES`) and memoir-web's exponent for each.
- `divergences.json` lists every case where the reference differs from the exact model, with its reason: `exponent e to f` (the reference multiplies minor units by the rate without the ISO 4217 exponents), `float` (a binary-float product rounds the other way, or an amount above 2^53 loses digits), `beyond 64-bit minor units` (the native code reports overflow), `custom interval not positive` (the native code refuses it), and `latest confirmed cycle wins` (the reference moves the due date back when an earlier cycle is confirmed later). The tests assert that native equals the exact model and differs from the reference for each listed case.
- Deliberate differences the vectors do not exercise:
  - a device that already holds a cycle's expense, removed included, never writes it again when the cycle is confirmed again, where the reference re-inserts a deleted one; the coin follows the confirm command either way;
  - a device that has not yet received a cycle's expense writes it again under the same derived id, and because its fields are registers, a later write restores an expense the owner deleted elsewhere and reverts the owner's edits made elsewhere (`FinanceConvergenceTests` pins this);
  - an anchor date moved to or before the latest confirmed billing date is ignored and the next due date stays the cycle after it, where the reference's `subscription.update` sets `nextDueDate` outright;
  - an expense converts through the `mm_fx_rate` of its pair and day, the first writer's, even when its own locked rate came from a record that lost the merge.
- Not represented: rounding a provider's rate to eight places (Postgres `numeric(18, 8)` does it in the reference, outside reachable code), and currencies with three or four decimals, which the reference does not accept; unit tests cover both.

## commands

```sh
PLATFORM_REPO=<path to the platform checkout> bun Packages/MemoirKit/Fixtures/commands/generate.ts
```

- Imports the reference's command handlers (`quests/quest-commands.service.ts` with `quest-command.types.ts`, `compassion-commands`, `metrics-commands`, `finance-commands`, `progression-commands`, `quick-logs-commands`), `commands/command-bus.service.ts` and `account/account.service.ts`, with their packages, repositories and sibling modules mocked; `rules/index.ts` and `progression/cosmetic.catalogue.ts` are real. `Date.now` is pinned to 2026-11-20 12:00 UTC.
- Each case is a native payload (and occurrence); the generator turns it into the reference's wire payload (digit-string ids, `occurrenceId`, the texts and content put back with valid defaults) and calls the handler. Store calls the handler makes before it has validated everything are answered by fixed stubs; any other store call ends the run as accepted, a `ValidationError` gives the refused field, an `AppErrorCode` the code, anything else `crashed`.
- The intensity mode and returner threshold are checked by the reference's route schema, which a generator cannot run, so their verdicts come from the values the schema declares (`account.dto.ts`, the ruleset's intensity modes). `receipt.scan` has no reference command.
- `commands.json` maps each type to its cases, one per line: `{"id", "payload", "occurrence", "reference", "native", "reason"}`. `native` is set, with a `reason`, only where the native code deliberately differs; the tests compare with it, and with `reference` otherwise.
- `content.json` holds the reference's refusals of content (names, the reason note, mood, calories, weight, billing day), which live in records here and are checked through `CommandContent` and `CommandIssuer.validate(text:for:)`.

## replay

```sh
PLATFORM_REPO=<path to the platform checkout> bun Packages/MemoirKit/Fixtures/replay/generate.ts
```

- Imports the reference's `QuestCommandsService`, `CompassionCommandsService`, `ProgressionCommandsService`, `QuickLogsCommandsService` and `MetricsCommandsService` with the real `HeroLedger`, `ProgressionService`, `RolloverService.resettleOpenDayCrown`, `applyStreakTransition`, quest linkage, cosmetic catalogue and `rules/index.ts`. Packages and sibling modules are mocked; the store is an in-memory stand-in for drizzle (tables as rows, the operators as predicates) with repositories that repeat only their reference SQL (the convergence upserts and `YIELDING_STATES`, the streak write's run start, the `rollover_at IS NULL` guard, natural keys). `Date.now` is each step's instant.
- Each scenario is a list of native steps (payload with `@name` for an id, occurrence, instant, the zone's fixed offset); the generator turns each into the reference's wire payload, stamps `localDate` with `accountToday` as the web does (a late step names the open day its device knew and the instant the server handles it, `issuerOpenDay` and `processedAt`; native replay reads only the issuing instant), and records the handler's status (`applied`, `superseded`, `rejected` with its kind, `refused` with its code, and the lock's advisory capacity). `seed.*` steps stand for what the day walk writes (an open day, a system miss, a pending Recovery, the open day ahead of the zone, a coin balance, a waiting Returner shield).
- Walk scenarios (`walk: true`) also import the real `RolloverService` and run its `catchUp` before every step, as `RolloverGate` does before every command, over a rollover repository that repeats its natural keys and guards (misses that never displace a row, the `rollover_at IS NULL` upsert, expiry bounded above only, one Recovery quest and one Returner event per day) with `rollover.catchup-max-days` at 90; a `horizon` step runs only the walk, and the settings steps stage the pending zone or intensity, or set the Returner threshold, as `PATCH /account` does; the walk promotes a staged change on the next day it prepares, on both sides. Native replay walks through `Replay.step` and `Replay.walk`, each step stamped with its own offset where it names one. Built-in metrics are seeded as the reference's `builtin` rows and named `@builtin-<name>`.
- Scenarios cover the literal cases of `tests/quests/day-stamp.spec.ts`, `compassion-commands.service.spec.ts`, `lock-capacity.spec.ts`, `reschedule-window.spec.ts`, `tests/quick-logs/quick-log-day.spec.ts` and `tests/rollover/rollover.service.spec.ts` (all but its re-close guard, which native replay cannot reach, and its statement counts), then flows through bands, streaks and shields, Comeback fire and re-fire after a Recovery, the lock bonus and its break, first-terminal convergence and yielding misses, log reasons and the edit window, every occurrence refusal, cosmetics and overspend, achievements and level-ups, quick-log rewards, a metric's soft delete, built-in metrics, a compassion command that arrives after the open day passed it, and a non-UTC offset; the walk scenarios add the Returner's shield target, Recovery and Comeback on the day after a miss, an intensity change and one staged across an absence, the weekly Crown bank, a cleared locked day, an offline completion, empty days, a quest created after its first date and recurrence exceptions.
- `scenarios.json` holds one scenario per line with `expected.steps` and `expected.state`: the hero totals and trail (ledger keys naming the occurrence or day instead of the reference's serial ids), logs, reschedules, streaks, shield uses, counters, achievements, titles, cosmetics, days (closed, intensity, HP, misses, momentum, Returner, lock, Comeback, Crown and its bank), the open day and last active date, Comeback events, Recovery quests (source and trigger logs), Returner events, metrics and quick-log rewards.
- `tests/commands/hero-ledger.service.spec.ts` drives the ledger with intents no single command produces (several spends in one grant, a jump of three levels); `ReplayTests` checks those literal cases against `HeroLedger` directly.

## money

```sh
bun Packages/MemoirKit/Fixtures/money/generate.ts
```

- Money in the game (ruleset v2) is native: the reference has no money commands, so this generator imports nothing, reads no checkout and needs no `PLATFORM_REPO`. Like the native `receipt.scan` cases in `commands.json`, every expected outcome is literal, worked out by hand from `rules/money-v2.ts` and ruleset v1's quest and quick-log tables, and each case carries the `reason` it holds.
- `vectors.json` holds one case per line: `{"id", "reason", "steps", "expected"}`. A step is a native payload with `@name` for an id (`at`, `type`, `payload`, an `occurrence` naming its quest without the `@`, `rulesetVersion` when it is not 2, and `clock` when it is delivered out of clock order); a `horizon` step only walks the days. `expected.steps` is each command's outcome as the whole log decides it (`applied`, `superseded`, or `refused` with the native code), and `expected.state` names only the members a case checks: the hero's XP and coins, covered days, the money and saving streaks, the last settled week, the last money activity, closes and their fines, debuff multipliers on given days, Returner events, notices, achievements, quest log XP and the money events on the trail.
- Cases cover the late logging window and its refusals, the daily log's intensity, v1 commands from an older device, Monday-anchored weeks settling once the late window after them has closed (with late cover, a short week, two full weeks and an absence past the catch-up limit), close rewards and duplicates, the saving streak, fines clamped to the balance, debuffs on quick logs, side quests, the money log and a quest completion, debuffs that never stack, intensity on a penalty, a penalty resetting the money streak, goal milestones and purchases, achievements reached through money XP, the Returner measuring money activity only once a quest was kept, an earlier-clocked close delivered late, and a late fine withdrawing a purchase.
- `MoneyReplayVectorTests` runs each case through `Replay.step` and compares; a step clocked before one already taken replays every command so far from the start, as a device does from the checkpoint before it.

## guardrails

```sh
PLATFORM_REPO=<path to the platform checkout> bun Packages/MemoirKit/Fixtures/guardrails/generate.ts
```

- Imports `src/modules/ai-worker/guardrails.ts` and `prompt-contract.ts`, with `@server/classes` (`AppErrorCode`), `@modules/inference` and `@server/database` mocked; the guardrails and the prompt are real.
- `guardrails.json`: `applyGuardrails` over every literal input of `tests/ai/guardrails.spec.ts` (`spec`), then 1,500 seeded drafts (`seeded`) drawn with the rules' LCG from phrase pools on, inside and just outside every pattern, quotes of the seeded sources with case, punctuation and accent changes, and the Unicode a JavaScript regex treats specially (Kelvin sign, dotted and dotless i, long s, fullwidth letters, NBSP, U+2028, zero-width joiners, astral characters). Each draft is first passed through `parseDraft`, as the executor does, so suggestions with missing, numeric, null or array members reach the guardrails as they would. The output is the reference's outcome as `JSON.stringify` writes it, compared by its JSON text.
- `quotes.json`: `findVerbatimQuote` over the spec's literal, probes at the shingle edges and through the normalisation, and 400 seeded outputs built from whole short sources, seven-to-nine-word stretches of long ones (re-cased, re-punctuated, wrapped, or with a word or an accent changed) and random fragments; the reference finds a quote in 231 of them, and in 247 of all the cases.
- `parse.json`: `parseDraft(JSON.parse(raw))` for every seeded reply and literal edge cases (duplicate keys, wrong member types, non-objects), as the draft or `{"error": "AI_009"}`.
- `prompts.json` and `contract.json`: `buildPrompt` over two contexts (Unicode, control characters, decimals) and the reference's allowed kinds, crisis answer and system prompt.
