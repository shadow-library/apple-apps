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
