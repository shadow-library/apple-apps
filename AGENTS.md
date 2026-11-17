# Agent guide — apple-apps

Read `README.md` first; it covers layout, modules and tasks.

## Rules

- Never commit or hand-edit `*.xcodeproj`, `*.xcworkspace` or `Derived/`. Change the Swift manifests and run `tuist generate --no-open`.
- Every app's `Project.swift` goes through `Project.app(...)`. Build settings belong in `Tuist/ProjectDescriptionHelpers/Settings+Shadow.swift`, never per app.
- Depend on shared modules with `.shared(.<module>)`, never `.external(name:)` with a string.
- Depend on product modules with `.product(.<module>)` (`ProductModule`), never `.external(name:)` with a string.
- Code reused by a second app belongs in `Packages/ShadowKit`, not copied between apps.
- A product's core lives in `Packages/<Product>Kit` (first: `Packages/NovelForgeKit`, module `NovelForgeCore`). It imports no UI framework (SwiftUI, UIKit, AppKit) and reaches ShadowKit through the package's products.
- `ShadowTestSupport` is for test targets only; never link it into an app target.
- Third-party dependencies are added to `Tuist/Package.swift` (for apps), `Packages/ShadowKit/Package.swift` (for shared modules) or the product package's own `Package.swift` and need the user's approval.
- `ShadowDesignSystem`: use semantic tokens only (`ShadowColor`, `Spacing`, `Radius`), never primitives or literal colours; the library has no user-facing strings.
- Glass goes on the navigation layer only (bars, sidebars, menus, popovers, sheets), never on content. Use `.shadowGlass` and `ShadowGlassGroup`, never a hand-drawn effect.
- Tokens come from `Design/tokens.json`; run `mise run tokens` and never edit `Tokens/Generated/`.
- `@_spi(Preview)` is for preview and capture hooks (Catalog, screenshots), never for app code.
- Novel Forge schema v1 is frozen: adding kinds or fields raises `NovelForgeSchema.version` and saves `Fixtures/schema/registry-v<N>.json` beside v1; never reorder or rename hashed key components.
- Write Novel Forge data through the typed records in `NovelForgeCore/Records` (their create, edit, revise and append writes), never by setting raw JSON fields on a `WriteTransaction`.
- Derived state lives in a `Derivation` on the `Projection` frame, in `Reconcile/<Area>/`: `.records` inputs map from the `EntityRef` alone, per-novel aggregates over hash-keyed kinds subscribe through `RecordIndexDerivation`, and `key(of:)`, a one-key `request(for:)` and a primary key are mandatory.
- Register every derivation in the incremental == rebuild harness (`Tests/NovelForgeCoreTests/Projection/ProjectionHarness.swift`); raise its `version` when `outputs(for:in:)` changes meaning.
- Fixtures come from `bun` generators that import the reference read-only; they are deterministic and hold no machine paths. Never write inside the reference checkout.
- Port JavaScript semantics through `Text/` and `Text/Regex`; never use `NSRegularExpression` or Swift `Regex` for a pattern taken from the reference.
- Sync files are deleted only by the rules in `ShadowSync` (`SyncCompaction`, `SyncAdoption`), by recorded names and never by prefix; never hand-delete under `replicas/`.
- Tests are named `should…`; Swift Testing tests that resolve `Color` or `Font` need `@MainActor`.

## Verifying a change

- Packages: `mise run test:packages` runs every package — fastest loop, needs no generation.
- Apps: `mise run bootstrap && tuist test <Scheme>`; add `--platform macOS` if simulators are unavailable.
- Use `--no-selective-testing` with `tuist test`, or unchanged targets are skipped. CI passes `--skip-ui-tests` on macOS and visionOS.
- `mise run screenshots` and anything touching simulators or the window server needs the command sandbox disabled, or it hangs.
- Always finish with `mise run lint` and `mise run lint:graph`.

Tuist requires the repository to have at least one commit; `tuist generate` fails on a fresh `git init`.
