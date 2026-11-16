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
| `ShadowCore`         | `ShadowError` protocol for typed domain errors, `Logger(category:)`         | —                                |
| `ShadowNetworking`   | `APIClient` (async, typed throws), `Endpoint`, middleware, JSON coding      | `ShadowCore`                     |
| `ShadowKeychain`     | `SecureStore` protocol and `KeychainStore` (data-protection keychain)       | `ShadowCore`                     |
| `ShadowStore`        | SQLite store through GRDB: entity tables, change log, field clocks          | `ShadowCore`, GRDB               |
| `ShadowSync`         | Vault sync: replicas, segments, merge, encryption                           | `ShadowCore`, `ShadowStore`, `ShadowKeychain`, GRDB |
| `ShadowAI`           | Model providers: task and pace to a model, request shaping, streaming, cost | `ShadowCore`, `ShadowNetworking`, `ShadowStore` |
| `ShadowDesignSystem` | Tokens, Liquid Glass helpers and native-first SwiftUI components (see below) | —                                |
| `ShadowTestSupport`  | `StubHTTPTransport`, `InMemorySecureStore` — test targets only              | `ShadowCore`, `ShadowNetworking`, `ShadowKeychain`, `ShadowStore`, `ShadowSync`, `ShadowAI` |

Apps depend on modules through the typed helper, so a typo fails at manifest compile time:

```swift
let project = Project.app(
  name: "Memoir",
  platform: .multiplatform,
  dependencies: [.shared(.networking), .shared(.keychain), .shared(.designSystem)],
  testDependencies: [.shared(.testSupport)]
)
```

### Adding a module

1. Add a target and a `.library` product to `Packages/ShadowKit/Package.swift`, with sources in `Sources/<Module>` and tests in `Tests/<Module>Tests`.
2. Add a case to `SharedModule` in `Tuist/ProjectDescriptionHelpers/SharedModule.swift`.
3. `mise run bootstrap`.

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
```

- Pass `--no-selective-testing` when verifying a change: Tuist otherwise skips targets it considers unchanged.
- CI runs `swift test` for the packages, then `tuist test` per platform: iOS with UI tests, macOS and visionOS with `--skip-ui-tests`.
- Swift Testing tests that resolve `Color` or `Font` must be `@MainActor`.

## Adding an app

```sh
mise run new-app Memoir --platform multiplatform   # ios | macos | multiplatform | watchos | tvos | visionos
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
