# Getting Started

Add ShadowDesignSystem to an app and build a first screen.

## Add the module

Apps in this repository depend on shared modules through the typed `.shared(...)` helper in their `Project.swift`:

```swift
let project = Project.app(
  name: "Memoir",
  platform: .multiplatform,
  dependencies: [.shared(.designSystem)]
)
```

Then run `mise run bootstrap`. Never use `.external(name:)` with a string for shared modules.

Outside the repository, depend on the `ShadowDesignSystem` product of `Packages/ShadowKit`. The package requires Swift 6.2 and OS 26 on every platform.
`ShadowDesignSystem` has no dependencies and uses `MainActor` as its default isolation.

## Apply the theme

Apply the theme once at the root of the app. It sets the accent as the tint, which native controls and the glass button variants pick up.

```swift
import ShadowDesignSystem
import SwiftUI

@main
struct MemoirApp: App {
  var body: some Scene {
    WindowGroup {
      RootView()
        .shadowTheme()
        .shadowToastPresenter()
    }
  }
}
```

## Build a screen

Use native navigation and mark the screen with the level of its title. Content sits on `ShadowColor.surfaceApp`; cards and rows sit on `ShadowColor.surfaceCard`.

```swift
struct LibraryView: View {
  @Environment(\.shadowShowToast) private var showToast
  @State private var isSaving = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: Spacing.space4) {
          ShadowCard {
            ShadowListRow("Quiet hours", subtitle: "10 pm to 7 am", accessory: .chevron)
          } header: {
            ShadowCardHeader("Notifications")
          }

          Button("Save") {
            showToast(ShadowToast("Saved", systemImage: "checkmark.circle", intent: .success))
          }
          .buttonStyle(.shadowFilled)
          .shadowLoading(isSaving)
        }
        .padding(Spacing.space4)
      }
      .shadowScreen(.root)
      .navigationTitle("Library")
    }
  }
}
```

`shadowShowToast` asserts in debug builds when no `shadowToastPresenter` is above it in the hierarchy.

## Fill wide windows

On iPad and Mac a single column leaves most of a wide window empty. Lay a page's sections out with ``ShadowAdaptiveColumns``: it flows them
into two columns where they fit (three with `maxColumns: 3`). A column is added only when every column can be at least
``ShadowMetrics/columnMinWidth`` wide, and no column grows past ``ShadowMetrics/readableWidth``. On iPhone and at accessibility text sizes
it is a single column.

```swift
ScrollView {
  ShadowAdaptiveColumns(spacing: Spacing.space8) {
    ProfileSection()
    NotificationsSection()
    ActivityTable()
      .shadowColumnSpan(.full)
  }
  .padding(Spacing.space5)
}
```

Give a full span to anything that needs the width, such as a table. The layout measures every section, so keep it to bounded content; a
long or growing collection belongs in a `LazyVGrid` or a `List`.

## Strings

The library ships no localised strings. Titles, labels, accessibility labels and messages are parameters of the components, so the app owns its string catalog.

## See what exists

The Catalog app (`Apps/Catalog`) renders every component in light and dark on iPhone, iPad and Mac. Run `mise run bootstrap`, open `ShadowLibrary.xcworkspace` and run the `Catalog` scheme.

## Next

- <doc:Tokens>
- <doc:GlassRules>
- <doc:PlatformBehaviour>
