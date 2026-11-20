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
