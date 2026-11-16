# Reference fixtures

Data generated from the TypeScript reference product, so the Swift port can be checked against what the reference does.

- Fixtures live in `Packages/NovelForgeKit/Fixtures/<area>/`, outside every target, so SwiftPM ignores them.
- Each area has a generator (`generate.ts`, or a script named for what it collects, such as `text/collect-regexes.ts`).
- Run it with `PLATFORM_REPO=<path to the reference checkout> bun <script>`.
- `regex/generate.ts` needs the checkout's installed dependencies: it resolves `typescript` and `@eslint-community/regexpp` through the checkout's eslint.
- Generators are deterministic: their own seeded generator, no clock, no `Math.random`, and only repository-relative paths in their output.
- The outputs are committed; rerun the generator and commit again when the reference changes.
- Tests read fixtures through `ReferenceFixture` (`Tests/NovelForgeCoreTests/Support/ReferenceFixture.swift`).
- The reference checkout is read, never written: no install, build or output file inside it.
