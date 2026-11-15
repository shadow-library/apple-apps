# Glass Rules

Liquid Glass is the material of the navigation layer. Content is flat and opaque.

## The rules

1. Use the system material only: `.glassEffect`, `.buttonStyle(.glass)` and `.glassProminent`, or the library helpers that wrap them. Never draw glass with colour tokens or blurs.
2. Glass belongs to bars, tab bars, toolbars, sidebars, menus, popovers, alerts, partial sheets and toasts.
3. Glass never goes on content: no glass cards, list rows, fields or reading text. Content stays on `ShadowColor.surfaceCard` and `ShadowColor.surfaceApp` and scrolls beneath glass.
4. Never put glass on glass. Group related glass items so they merge into one shape.
5. Do not tint glass with status colours. The only tint is the accent, on the one action that completes a task.

## Helpers

``ShadowGlass`` selects the variant:

| Variant      | Use                                                                          |
| ------------ | ---------------------------------------------------------------------------- |
| `.regular`   | Bars and their buttons                                                       |
| `.dense`     | Panels with reading text: menus, popovers, alerts, the command palette, toasts |
| `.prominent` | The single completing action; always tinted with the accent                  |
| `.clear`     | Only over photos, covers and full-bleed media                                |

Call `.interactive()` on a variant for controls that respond to touch.

```swift
Label("Filters", systemImage: "line.3.horizontal.decrease")
  .padding(Spacing.space3)
  .shadowGlass(.regular.interactive())
```

`View.shadowGlass(_:in:)` takes any `InsettableShape` and defaults to a capsule.

To group glass items so they merge, use ``ShadowGlassGroup``. It wraps `GlassEffectContainer`. `View.shadowGlassID(_:in:)` and `View.shadowGlassUnion(id:namespace:)` morph and union items.

```swift
ShadowGlassGroup(spacing: Spacing.space2) {
  ShadowIconButton("Share", systemImage: "square.and.arrow.up", variant: .glass) {}
  ShadowIconButton("Favourite", systemImage: "heart", variant: .glass) {}
}
```

``ShadowIconButtonGroup`` renders its children inside a single glass capsule.

Buttons: `.buttonStyle(.shadowGlass)` and `.shadowGlassProminent` are the glass variants of ``ShadowButtonStyle``. In toolbars use plain `Button`, `.shadowBarItem()` for text-primary symbols and `.shadowToolbarProminent()` for the completing action.

## How the rules are enforced

``ShadowMaterialLayer`` is an environment value, `\.shadowMaterialLayer`.

- `.navigation` is the default and allows glass.
- `.shadowGlass(_:)` marks its content as glass, and `.shadowCard()` marks it as content.
- Inside either, `.shadowGlass` draws nothing. Glass button variants fall back: glass becomes a bar item inside glass, and glass becomes bordered (glassProminent becomes filled) inside content.

Wrap custom content containers in `.shadowCard()` so glass inside them degrades instead of stacking.

## Accessibility and platforms

- With Reduce Transparency or Increase Contrast the system frosts the glass. Text tokens stay legible on both.
- All glass APIs compile on visionOS through a `glassBackgroundEffect` fallback, so no `#if` is needed in app code. `scrollEdgeEffectStyle` is unavailable on visionOS; `shadowScreen(_:)` already gates it.
- On macOS, glass on popovers renders flat grey in Catalog captures. This is a capture artefact.
