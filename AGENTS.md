# Agent guide — apple-apps

Read `README.md` first; it covers layout, modules and tasks.

## Rules

- Never commit or hand-edit `*.xcodeproj`, `*.xcworkspace` or `Derived/`. Change the Swift manifests and run `tuist generate --no-open`.
- Every app's `Project.swift` goes through `Project.app(...)`. Build settings belong in `Tuist/ProjectDescriptionHelpers/Settings+Shadow.swift`, never per app.
- Depend on shared modules with `.shared(.<module>)`, never `.external(name:)` with a string.
- Code reused by a second app belongs in `Packages/ShadowKit`, not copied between apps.
- `ShadowTestSupport` is for test targets only; never link it into an app target.
- Third-party dependencies are added to `Tuist/Package.swift` (for apps) or `Packages/ShadowKit/Package.swift` (for shared modules) and need the user's approval.

## Verifying a change

- Shared packages: `mise run test:packages` — fastest loop, needs no generation.
- Apps: `mise run bootstrap && tuist test <Scheme>`; add `--platform macOS` if simulators are unavailable.
- Always finish with `mise run lint` and `mise run lint:graph`.

Tuist requires the repository to have at least one commit; `tuist generate` fails on a fresh `git init`.
