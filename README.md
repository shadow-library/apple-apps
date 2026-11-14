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
| `ShadowDesignSystem` | Tokens, `.shadowGlass`, `ShadowButtonStyle`, `ShadowIconButton`, `ShadowCard` | —                                |
| `ShadowTestSupport`  | `StubHTTPTransport`, `InMemorySecureStore` — test targets only              | `ShadowNetworking`, `ShadowKeychain` |

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
