# Shadow Library — Apple Apps

Monorepo for every Shadow Library app on Apple platforms (iOS, iPadOS, macOS, watchOS, tvOS, visionOS) and the Swift packages they share.

## Requirements

- Xcode 27 (Swift 6.2+)
- [mise](https://mise.jdx.dev) — pins Tuist and runs the repo tasks: `brew install mise`

## Getting started

```sh
mise install          # installs the pinned Tuist
mise run bootstrap    # resolves packages and generates ShadowLibrary.xcworkspace
open ShadowLibrary.xcworkspace
```

Xcode projects and the workspace are generated from Swift manifests and are never committed. Re-run `tuist generate` after changing any
`Project.swift`, `Tuist/Package.swift` or helper; adding or removing source files does not need it, since targets use buildable folders.

To sign for devices, export your team before generating: `export TUIST_DEVELOPMENT_TEAM=ABCDE12345`.

## Layout

```
Apps/                         one folder per app, each with its own Project.swift
  Catalog/                    design-system gallery; also the pipeline's smoke test
  NovelForge/                 Novel Forge for iPhone, iPad and Mac (`.phoneAndMac`); vault opening and the library shell
Packages/
  ShadowKit/                  the shared Swift package (one library product per module)
  NovelForgeKit/              Novel Forge's core (`NovelForgeCore`): domain rules, pipelines, retrieval; no UI
Tuist/
  Package.swift               external + local package dependencies for the apps
  ProjectDescriptionHelpers/  Project.app(...), shared settings, platform presets
  Templates/app/              scaffold used by `mise run new-app`
Tuist.swift  Workspace.swift  mise.toml  .swift-format
```

## Shared modules

| Module               | Purpose                                                                     | Depends on                       |
| -------------------- | --------------------------------------------------------------------------- | -------------------------------- |
| `ShadowCore`         | `ShadowError`, `Logger(category:)`, `HybridLogicalClock`, `TrustedClock`, `UUIDv7Generator`, `ReplicaID`, `JSONValue`, canonical JSON, HTTP dates | — |
| `ShadowNetworking`   | `APIClient` (async, typed throws), `Endpoint`, middleware, JSON coding, streaming transport and server-sent events | `ShadowCore` |
| `ShadowKeychain`     | `SecureStore` protocol and `KeychainStore` (data-protection keychain)       | `ShadowCore`                     |
| `ShadowStore`        | SQLite store through GRDB: `VaultStore`, `EntitySchema` and `SchemaRegistry`, `ChangeRecord`, per-field clocks and merge, snapshots, retention, upgrade | `ShadowCore`, GRDB |
| `ShadowSync`         | Vault sync through a `StorageProvider` (`LocalFolderProvider`): `SyncEngine`, replica lifecycle, segment codec, encrypted vault files, key ring, recovery | `ShadowCore`, `ShadowStore`, `ShadowKeychain`, GRDB |
| `ShadowAI`           | `ModelProvider` with `AnthropicProvider` and `OpenRouterProvider`, `ModelCatalog` (task and pace to a model), `RetryingProvider`, structured calls, `Ledger` of model calls and spend | `ShadowCore`, `ShadowNetworking`, `ShadowStore` |
| `ShadowDesignSystem` | Tokens, Liquid Glass helpers and native-first SwiftUI components (see below) | —                                |
| `ShadowTestSupport`  | Test targets only: `StubHTTPTransport` and streaming stubs, `InMemorySecureStore`, `InMemoryKeychain`, `InMemoryStorageProvider`, `FaultInjectingStorageProvider`, `StorageProviderConformance`, `ScriptedModelProvider`, `CausalReplicas`, `forAll`/`replay` with `SeededGenerator` | `ShadowCore`, `ShadowNetworking`, `ShadowKeychain`, `ShadowStore`, `ShadowSync`, `ShadowAI` |

Apps depend on modules through the typed helper, so a typo fails at manifest compile time:

```swift
let project = Project.app(
  name: "Memoir",
  platform: .multiplatform,
  dependencies: [.shared(.networking), .shared(.keychain), .shared(.designSystem)],
  testDependencies: [.shared(.testSupport)]
)
```

`VaultStore.open` on a file sets file protection `completeUntilFirstUserAuthentication` on the vault directory and on the database, `-wal` and `-shm` files, and fails with `StoreError.fileProtection` if it cannot (macOS has no such protection and skips it; in-memory stores are untouched). `SyncEngine.start()` (or `StorageAttachment.attach(_:)`) flags the vault directory as excluded from device backups, `StorageAttachment.detach(_:)` clears it, and a failure there is reported (`SyncEngine.backupExclusionFailure`, a log entry) without failing the attach (attach is idempotent and re-asserted on every start; clearing the flag is eventually consistent on macOS; a vault directory must hold only the vault's own files or the flag is refused), since the flag is only guidance and the replica self-check carries correctness.

Product cores are depended on the same way, through `ProductModule` (`.product(.novelForgeCore)`), so no dependency is named by a string.

### Adding a module

1. Add a target and a `.library` product to `Packages/ShadowKit/Package.swift`, with sources in `Sources/<Module>` and tests in `Tests/<Module>Tests`.
2. Add a case to `SharedModule` in `Tuist/ProjectDescriptionHelpers/SharedModule.swift`.
3. `mise run bootstrap`.

A product module is added the same way: a library product in the product's package, a case in `ProductModule` (`Tuist/ProjectDescriptionHelpers/ProductModule.swift`), and a `.package(path:)` entry in `Tuist/Package.swift` for a new package.

## Novel Forge core

`Packages/NovelForgeKit` holds `NovelForgeCore`: the product's records, rules and derived state on top of `ShadowStore`. It imports no UI framework and depends on `ShadowCore`, `ShadowStore`, `ShadowAI` and GRDB; `ShadowTestSupport` is linked by its tests only.

| Folder                   | Contents                                                                                               |
| ------------------------ | ------------------------------------------------------------------------------------------------------ |
| `Text`                   | JavaScript string, number and JSON semantics (UTF-16 indexing, `OrderedJSON` stringify) that policies port exactly |
| `Text/Regex`             | `JSRegex`: a backtracking engine for JavaScript patterns, with case folding and a follow analysis        |
| `Schema`                 | `NovelForgeSchema` (`version`), `NovelForgeKind`, `NovelForgeField`, `NovelForgeKey`                    |
| `Store`                  | `NovelForgeStore`: opens the vault (file or in-memory) with the schema registry and reconciler          |
| `Records`                | One typed record per kind (`NovelRecord`, `DraftRecord`, `FinalChapterRecord`, ...) with create, edit, revision and append writes and reads |
| `Rules`                  | Pure rules: content hash, progress, next chapter, batch selection, bible manifest, promises, volume stats |
| `Policies/*`             | Ported pure policies: `Checks`, `HardLine`, `Ideas`, `Metrics`, `Prose`, `ReplyScanner`, `Reveal`, `WritePolicy` |
| `ChangeSet`              | The change-set vocabulary (`OpType`, `OpSpecs`), parsing, reference resolution and validation          |
| `Projection`             | `Derivation`, `NovelForgeReconciler` and the record index: derived tables kept equal to a rebuild        |
| `Reconcile/*`            | Derivations per area: `Chapters`, `Notebook`, `Story`                                                    |
| `Domain/*`               | Operations on the records: `Story`, `Notebook`                                                           |

### Reference fixtures

Expected outputs come from the TypeScript reference product and are committed under `Packages/NovelForgeKit/Fixtures/<area>/` (`change-set`, `checks`, `hard-line`, `ideas`, `metrics`, `prose`, `regex`, `reply-scanner`, `reveal`, `rules`, `schema`, `text`, `write-policy`). Regenerate an area with a read-only checkout of the reference:

```sh
PLATFORM_REPO=<path to the reference checkout> bun Packages/NovelForgeKit/Fixtures/<area>/generate.ts
```

`text/` uses `collect-regexes.ts` instead of `generate.ts`, and `regex/generate.ts` needs the checkout's installed dependencies. See `Packages/NovelForgeKit/Fixtures/README.md`.

## ShadowDesignSystem

Shadow UI for Apple: the brand (indigo accent, tinted neutrals, flat opaque content) on native SwiftUI controls, with Liquid Glass for the navigation layer only. Minimum OS 26 on every platform. It contains no user-facing strings.

### Adopting it in an app

1. Depend on it in the app's `Project.swift`: `dependencies: [.shared(.designSystem)]`, then `mise run bootstrap`.
2. Apply the theme and a toast presenter once at the root:

```swift
import ShadowDesignSystem

WindowGroup {
  RootView()
    .shadowTheme()
    .shadowToastPresenter()
}
```

3. Use semantic tokens only (`ShadowColor.textPrimary`, `Spacing.space4`, `Radius.section`), never primitive palette values or literal colours.
4. Keep glass on bars, toolbars, sidebars, menus, popovers and sheets. Content (cards, rows, fields) stays flat on `ShadowColor.surfaceCard`.

The DocC catalog has a getting-started article, the token and contrast reference, the glass rules, and the platform decisions that deviate from the Shadow UI design spec.

### Regenerating tokens

`Design/tokens.json` is the source for colours, spacing, radii, metrics, opacity and elevation. After editing it:

```sh
mise run tokens
```

This rewrites `Packages/ShadowKit/Sources/ShadowDesignSystem/Tokens/Generated/`. Never edit those files by hand. CI regenerates them and fails on a diff. Every text pair in `ContrastTests` must still pass `mise run test:packages`.

### Building the docs

The catalog is `Packages/ShadowKit/Sources/ShadowDesignSystem/ShadowDesignSystem.docc`. Build it with Xcode, which needs no extra package:

```sh
cd Packages/ShadowKit
xcodebuild docbuild -scheme ShadowDesignSystem -destination 'generic/platform=macOS' -derivedDataPath .build/docbuild
```

The archive is written to `.build/docbuild/Build/Products/Debug/ShadowDesignSystem.doccarchive`; open it in Xcode. `swift package generate-documentation` would need `swift-docc-plugin`, which is not a dependency of this repository.

## Novel Forge app

`Apps/NovelForge` runs on iPhone, iPad and Mac from one target (`.phoneAndMac`; no visionOS). It depends on `NovelForgeCore`, `ShadowStore`, `ShadowAI`, `ShadowKeychain`, `ShadowNetworking` and `ShadowDesignSystem`. At launch it opens the vault, one SQLite database at `<Application Support>/<bundle id>/Vaults/Default/vault.sqlite`, off the main actor; a failure shows an error screen with Try Again instead of crashing. The root is a three-column `NavigationSplitView`: the library, the sections of the selected novel, and the section's screen. Unit tests run against a temporary directory, and the app itself uses an in-memory store when hosted by XCTest. Opening goes through `NovelForgeStore` in `NovelForgeCore`.

Each area owns a folder under `Apps/NovelForge/Sources/<Area>/` (`Library`, `Reader`, `Story`, `StoryBible`, `Notebook`) and plugs into the shell through one entry view, `struct <Area>View: View { let context: NovelContext }`, where `NovelContext` holds the `VaultStore` and the novel's id. `Navigation/NovelDetailView.swift` maps a `NovelSection` to that view, so an area replaces only its own folder. The shell keeps one `NovelNavigator` per novel in the environment (`@Environment(NovelNavigator.self)`): `section` is the selected section, `show(_:)` switches to one, `open(_:_:)` replaces that section's own `NavigationStack` path with one `Hashable` route and selects the section (a deep link), and `push(_:)` appends a route within the current section. An area registers `navigationDestination(for:)` for its own route types, and each section's path survives switching sections. A route can outlive its entity (deleted, or removed on another device), so every destination must render a "not found" state rather than assume the entity exists.

A screen that holds text the user has typed registers its flush with `Shared/UnsavedWork` (`UnsavedWork.shared.register { … }` returns a token to `unregister` with). The app flushes every registration when the scene leaves the active phase (inside a background-task assertion on iOS), when a window closes, and before quitting on macOS (`applicationShouldTerminate` answers `.terminateLater` until the flushes finish or a timeout passes). A flush should write the text to durable local storage and not depend on the network. Models that carry such state are kept per novel above the section switch (`Navigation/NovelReaders` for the Reader) so a section or novel switch does not discard them.

Observe reads with `ReadObserver` (`Shared/ReadObserver.swift`; `run(_:onValue:)` hands every emitted value to a hook, and an equal value is not republished) and surface failures through `PresentedError` (a localized headline with the error code as detail, never developer text). Markdown prose is rendered by `Shared/ProseView`, which the Reader and the Story Bible share. Strings are per area: `Library.xcstrings` and `Navigation.xcstrings` are used with `Text(_:tableName:)` and `LocalizedStringResource(_:table:)`; an area adds its own `<Area>.xcstrings` and never edits another's. `Localizable.xcstrings` holds only the vault-opening strings.

## Catalog app

`Apps/Catalog` is a gallery of every component and token page in light and dark, with the presentation and device-screen demos. It is also the pipeline's smoke test and the subject of the screenshot harness. Run the `Catalog` scheme from the workspace, or `Catalog -list-components` to print the page ids.

Launch arguments: `-component <id>`, `-appearance light|dark`, `-scroll <0..1>`, `-screen <name>`, `-present`, `-animated` (keeps animations on for a deep link, which otherwise disables them).

### Screenshot harness

```sh
mise run screenshots -- --platform iphone,macos --component Button,Card --appearance both
mise run screenshots -- --help
```

Output goes to `scratch-pad/shots/latest/<platform>/<id>-<appearance>[-s<percent>][-<screen>][-presented][-landscape].png`.

| Option                             | Effect                                                                                                       |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `--platform iphone,ipad,macos`     | Platforms to capture (default all)                                                                           |
| `--component <id>,…`               | Page ids from `Catalog -list-components` (default all)                                                       |
| `--appearance light,dark,both`     | Appearances (default both)                                                                                   |
| `--scroll <f>,…`                   | Scroll positions from 0 to 1 on scrolling pages, for example `0,0.5,1`                                       |
| `--screen <name>,…`                | Sub-screens of pages that have several, such as `library`, `today` and `stepup` on iPhoneScreens             |
| `--present`                        | Open the page's sample sheet, alert, popover, toast or palette before the shot; files get `-presented`       |
| `--orientation portrait,landscape` | iPad orientation. Landscape runs a UI test (`CatalogUITests/CatalogShotTests`)                               |
| `--content-size <name>`            | Simulator Dynamic Type size, such as `accessibility-extra-extra-extra-large`; the next default run resets it |
| `--out <dir>`                      | Output directory                                                                                             |
| `--skip-build`, `--keep-booted`    | Reuse the last build in `scratch-pad/derived-data`; leave simulators booted                                  |

How it captures:

- iPhone and iPad use `simctl io screenshot` on iOS 26.5 simulators. Each shot is retaken until two consecutive frames match.
- iPad landscape runs the iOS UI test, which rotates the device and screenshots with `XCUIScreen`. The harness writes the shot list to a file and passes its path in `CATALOG_SHOT_PLAN`; the test skips when the variable is absent.
- Mac needs no permission: the app composites its own windows into a PNG (`-snapshot <png>`), without Screen Recording access.

Simulators and the window server require running outside any command sandbox. Inside one the run hangs.

## Testing

```sh
mise run test:packages                      # shared packages with SwiftPM; no generation needed
mise run test:apps                          # tuist test --skip-ui-tests
tuist test Catalog --platform macOS --no-selective-testing
tuist test NovelForge --platform macOS --no-selective-testing
```

- `mise run test:packages` covers `ShadowKit` and `NovelForgeKit`. Property tests print their seed on failure; rerun it with `replay(seed:)` from `ShadowTestSupport`.
- Pass `--no-selective-testing` when verifying a change: Tuist otherwise skips targets it considers unchanged.
- CI runs `swift test` for the packages, then `tuist test` per platform: iOS with UI tests, macOS with `--skip-ui-tests`, and visionOS with `--skip-ui-tests` on `Catalog` only (the new apps have no visionOS destination).
- Swift Testing tests that resolve `Color` or `Font` must be `@MainActor`.

## Adding an app

```sh
mise run new-app Memoir --platform multiplatform   # ios | macos | multiplatform | phoneAndMac | watchos | tvos | visionos
```

This creates `Apps/Memoir` with app, test target and scheme, bundle ID `com.shadowlibrary.memoir`, and regenerates the workspace.

## Tasks

| Command                   | What it does                                          |
| ------------------------- | ----------------------------------------------------- |
| `mise run bootstrap`      | `tuist install` + `tuist generate --no-open`          |
| `mise run test`           | Package tests (`swift test`) and app tests (`tuist test`) |
| `mise run test:packages`  | Shared package tests only — no project generation     |
| `mise run test:apps`      | App tests without UI tests (`tuist test --skip-ui-tests`) |
| `mise run tokens`         | Regenerates design-token sources from `Design/tokens.json` |
| `mise run screenshots`    | Captures Catalog pages (see Screenshot harness)       |
| `mise run lint`           | `swift format lint --strict`                          |
| `mise run lint:graph`     | Fails on implicit or redundant module dependencies    |
| `mise run format`         | Formats sources in place                              |
| `mise run clean`          | Removes generated projects and build artifacts        |

## Conventions

- Swift 6 language mode with complete concurrency checking; `ExistentialAny` and `MemberImportVisibility` are on everywhere.
- App targets default to `MainActor` isolation; library modules do not, except `ShadowDesignSystem`.
- Swift Testing (`import Testing`) for all tests; test names start with `should`.
- Errors crossing a module boundary conform to `ShadowError` and are thrown with typed `throws(...)` where the set is closed.
- Minimum OS 26 on every platform, set once in `Organization.minimumOSVersion` and the package manifest.
