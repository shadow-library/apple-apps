# Tokens

Semantic colour, type, spacing, radius and density values, generated from one source file.

## Use semantic tokens only

`ShadowColor` exposes semantic tokens such as `textPrimary`, `surfaceCard`, `borderSubtle`, `accent` and the intent families (`success…`, `warning…`, `danger…`, `info…`, `neutral…`).
Each resolves to a light or dark value from the current `colorScheme`, including subtree overrides.

```swift
Text("Storage")
  .shadowFont(.headline)
  .foregroundStyle(ShadowColor.textPrimary)
  .padding(Spacing.space4)
  .background(ShadowColor.surfaceCard, in: RoundedRectangle(cornerRadius: Radius.section))
```

Primitive palette values (indigo-600, red-700 and so on) are not emitted. Do not reproduce them as literals, and do not use `Color(red:green:blue:)` in app code.
The `glass*` colour tokens exist for static previews only. Never paint glass with them; see <doc:GlassRules>.

Status colours mean status and nothing else. Use one accent per view.

## Typography

``ShadowTextStyle`` has cross-platform roles (`.largeTitle`, `.title`, `.headline`, `.body`, `.callout`, `.subheadline`, `.footnote`, `.caption`) that map to SF Pro text styles on iOS and to the macOS scale on Mac.
Apply them with `Font.shadow(_:)` or `View.shadowFont(_:)`. Both scale with Dynamic Type.

## Spacing, radius and density

- ``Spacing``: `space05` (2pt), `space1` (4), `space2` (8), `space3` (12), `space4` (16), `space5` (20), `space6` (24), `space8` (32), `space10` (40).
- ``Radius``: `sm` 4, `md` 6, `lg` 8, `xl` 12, `xxl` 16, `section` 20, `panel` 26, `sheet` 32, `full` 9999.
- ``ShadowMetrics``: control heights, row heights, sidebar and inspector widths. Touch controls are 36, 44 and 50pt; Mac controls are 24, 28 and 32pt.
- ``ShadowDensity``: `.touch` or `.compact`. `ShadowDensity.current` picks by platform, and components read their metrics from it.

Use `ShadowMetrics.control(_:)` with a ``ShadowControlSize`` instead of hard-coding heights.

## Where tokens come from

`Design/tokens.json` is the single source. `Scripts/generate-design-tokens.swift` turns it into the files under `Tokens/Generated/`:

```sh
mise run tokens
```

Never edit the generated files. CI runs the generator and fails when the output differs from what is committed, so commit the regenerated files together with the JSON change.

The generator resolves aliases, requires a value for both light and dark, and fails on unknown aliases, cycles and invalid colours.

## Contrast guarantees

`ContrastTests` computes WCAG contrast ratios from the token values. Every text pair listed there must reach 4.5:1 in both light and dark:

- `textPrimary`, `textSecondary` and `accentText` on `surfaceCard` and `surfaceApp`; `textPrimary` and `textSecondary` on `surfaceRaised`.
- `destructiveLabel` and `textTertiary` on `surfaceCard`; `accentText` on `accentSoft`.
- `neutralText` and `infoText` on `surfaceCard` and `surfaceApp`; `dangerText` on `surfaceCard` and `surfaceApp`.
- Each intent's `…TextOnSubtle` on its `…BgSubtle` fill.
- `onAccent` on `accent`, `accentHover`, `accentActive` and `selectionRow`.
- `dangerOnSolid` on `dangerSolid`, `dangerSolidHover` and `dangerSolidActive`.
- `warningOnSolid` on `warningSolidStrong`; `neutralOnSolid` on `neutralSolid`.
- `textPrimary` on `bgHover`, `bgPressed` and `surfaceWell`.
- White (`onAccent`) on every swipe-action tile kind.

Translucent fills, such as the dark `…BgSubtle` tokens, are composited over `surfaceCard` before measuring.

Not guaranteed: `successSolid` with white text is 3.3:1. Use it for glyphs and fills, never for text.

### Deviations from the Shadow UI design spec

These values differ from the Shadow UI design spec so that every pair above passes:

- Dark `accentHover` and `accentActive` darken (indigo-600, indigo-700) instead of lightening.
- Dark `dangerSolidHover` and `dangerSolidActive` use red-700 and red-800.
- Light `dangerText` is `#d92525`.
- `warningSolidStrong` and `neutralSolidStrong` are added for warning and neutral swipe tiles.
- `borderControl` is an Apple addition for control outlines. It reaches 3:1 on `surfaceCard`, `surfaceApp`, `surfaceRaised` and `surfaceWell` in both themes.

A change to any token that appears in `ContrastTests` needs a passing run of `mise run test:packages`. Tests that resolve `Color` or `Font` must be `@MainActor`.
