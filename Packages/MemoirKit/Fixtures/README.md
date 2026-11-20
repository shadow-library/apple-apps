# Reference fixtures

Data generated from the TypeScript reference server, so the Swift port can be checked against what the reference does.

- The reference is `/Users/leander-paul/repositories/shadow-library/platform/apps/memoir-server`; generators take its checkout through `PLATFORM_REPO=<path to the platform checkout>`.
- Fixtures live in `Packages/MemoirKit/Fixtures/<area>/`, outside every target, so SwiftPM ignores them.
- Each area has a generator (`generate.ts`); run it with `PLATFORM_REPO=<path> bun Packages/MemoirKit/Fixtures/<area>/generate.ts`.
- Generators import the reference read-only and compute every expected output by calling the reference; none of its logic is re-implemented.
- Generators are deterministic: their own seeded generator, no clock, no `Math.random`, and only repository-relative paths in their output; no machine path appears in a fixture.
- The outputs are committed; rerun the generator and commit again when the reference changes.
- The reference checkout is read, never written: no install, build or output file inside it.
