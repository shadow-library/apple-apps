# Agent guide — apple-apps

Read `README.md` first; it covers layout, modules and tasks.

## Rules

- Never commit or hand-edit `*.xcodeproj`, `*.xcworkspace` or `Derived/`. Change the Swift manifests and run `tuist generate --no-open`.
- Every app's `Project.swift` goes through `Project.app(...)`. Build settings belong in `Tuist/ProjectDescriptionHelpers/Settings+Shadow.swift`, never per app (capability-derived settings are built in `AppCapability.swift` and merged there); settings of the package targets (ShadowKit, product kits) live in `Tuist/Package.swift`'s `PackageSettings`.
- Every identifier is reverse-DNS under its owner: `com.shadow.apps.<app>` for an app (bundle id, keychain services, defaults keys) and `com.shadow.library.<library>` for a shared library (bundle id, migration identifiers, format tags, hash domain separators). A new library target is added to the list in `Tuist/Package.swift`.
- Depend on shared modules with `.shared(.<module>)`, never `.external(name:)` with a string.
- Depend on product modules with `.product(.<module>)` (`ProductModule`), never `.external(name:)` with a string.
- Code reused by a second app belongs in `Packages/ShadowKit`, not copied between apps.
- A product's core lives in `Packages/<Product>Kit` (first: `Packages/NovelForgeKit`, module `NovelForgeCore`). It imports no UI framework (SwiftUI, UIKit, AppKit) and reaches ShadowKit through the package's products.
- Capabilities (iCloud, push, background modes, keychain group, camera, Mac sandbox) are declared only through `Project.app(capabilities:)` with `AppCapability`; never write entitlements, `aps-environment`, `UIBackgroundModes` or usage strings by hand. Capabilities that need a signing team are emitted only when `TUIST_DEVELOPMENT_TEAM` is set, so team-less builds must keep working.
- `ShadowTestSupport` is for test targets only; never link it into an app target.
- Third-party dependencies are added to `Tuist/Package.swift` (for apps), `Packages/ShadowKit/Package.swift` (for shared modules) or the product package's own `Package.swift` and need the user's approval.
- `ShadowDesignSystem`: use semantic tokens only (`ShadowColor`, `Spacing`, `Radius`), never primitives or literal colours; the library has no user-facing strings.
- Glass goes on the navigation layer only (bars, sidebars, menus, popovers, sheets), never on content. Use `.shadowGlass` and `ShadowGlassGroup`, never a hand-drawn effect.
- Tokens come from `Design/tokens.json`; run `mise run tokens` and never edit `Tokens/Generated/`.
- Each app area owns its own `<Area>.xcstrings` and never edits another's. A plural variation key written as `%#@name@` takes later arguments by explicit position (`%2$@`, `%2$lld`); an unnumbered specifier after it crashes at run time.
- `@_spi(Preview)` is for preview and capture hooks (Catalog, screenshots), never for app code.
- Novel Forge schema v1 is frozen: adding kinds or fields raises `NovelForgeSchema.version` and saves `Fixtures/schema/registry-v<N>.json` beside v1; never reorder or rename hashed key components.
- Write Novel Forge data through the typed records in `NovelForgeCore/Records` (their create, edit, revise and append writes), never by setting raw JSON fields on a `WriteTransaction`.
- Derived state lives in a `Derivation` on the `Projection` frame, in `Reconcile/<Area>/`: `.records` inputs map from the `EntityRef` alone, per-novel aggregates over hash-keyed kinds subscribe through `RecordIndexDerivation` (or through `.outputs(of:)` of their own per-ref layer whose rows record the novel and chapter), and `key(of:)`, a one-key `request(for:)` and a primary key are mandatory.
- Local unsynced Novel Forge tables are named `nf_local_*`, created with `CREATE TABLE IF NOT EXISTS` by the write that first needs them, read only after a `tableExists` check, and cleared with their owner (`ChatLocalCleanup`, `ChatTurnRecords.forgetOrphans`, `PendingActions.forget`) so a deleted session, novel or proposal leaves nothing behind.
- App code builds proposal apply and revert contexts only through the public narrow inits (`ProposalApplyContext(novel:now:)`, `ProposalRevertContext(novel:now:)`); whether unrestricted writing is available comes from `UnrestrictedWriting.isAvailable`, never from a caller.
- Register every derivation in the incremental == rebuild harness (`Tests/NovelForgeCoreTests/Projection/ProjectionHarness.swift`); raise its `version` when `outputs(for:in:)` changes meaning.
- Fixtures come from `bun` generators that import the reference read-only; they are deterministic and hold no machine paths. Never write inside the reference checkout.
- Port JavaScript semantics through `ShadowText` (`Packages/ShadowKit/Sources/ShadowText`, with `Regex/`); never use `NSRegularExpression` or Swift `Regex` for a pattern taken from the reference.
- A remote storage provider lives in its own `ShadowSync<Name>` module that depends on `ShadowSync` (plus `ShadowNetworking` when it speaks HTTP), never inside `ShadowSync`; one that signs in with OAuth uses `OAuthSession`.
- Sync files are deleted only by the rules in `ShadowSync` (`SyncCompaction`, `SyncAdoption`), by recorded names and never by prefix; never hand-delete under `replicas/`.
- Pipelines call models only through `JobStepContext.call` or `callText`, which apply the route, the hard-line screens and the ledger.
- Job keys are built and read through `NovelJobAddress` and `NovelJobKind`, never by string.
- A job's `origin` comes from `NovelJobOrigin.json`.
- Derived ids use `derivedID(_:_:)` with a `com.shadow.library.<library>.<purpose>` domain.
- New test suites take a `TestTimeLimit` tier (`quick`, `standard`, `property`), never a literal limit.
- Tests are named `should…`; Swift Testing tests that resolve `Color` or `Font` need `@MainActor`.

## Verifying a change

- Packages: `mise run test:packages` runs every package — fastest loop, needs no generation.
- Apps: `mise run bootstrap && tuist test <Scheme>`; add `--platform macOS` if simulators are unavailable.
- Use `--no-selective-testing` with `tuist test`, or unchanged targets are skipped. CI passes `--skip-ui-tests` on macOS and visionOS.
- `mise run screenshots` and anything touching simulators or the window server needs the command sandbox disabled, or it hangs.
- Always finish with `mise run lint` and `mise run lint:graph`.

Tuist requires the repository to have at least one commit; `tuist generate` fails on a fresh `git init`.
