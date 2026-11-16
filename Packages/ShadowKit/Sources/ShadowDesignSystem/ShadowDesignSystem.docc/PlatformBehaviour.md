# Platform Behaviour

Where the library follows the platform instead of the Shadow UI design spec, and the native limits it accepts.

## Principle

Use the system control and tint it. The library decides tint, surfaces, text colours, radii and spacing; the platform decides behaviour. Where the two disagree, the platform wins and the decision is listed here.

## Selection

- Tables and `List(selection:)` keep the native selection: the system accent when focused, grey when unfocused. This deviates from the design spec's selection colour because Shadow cannot replicate it on a native `Table`, and the native band follows the user's accent and focus.
- Exactly one selection layer is drawn per platform. On a Mac `List(selection:)` and on the iPad sidebar, ``ShadowListRow`` does not draw its own pill.
- Labels on the focused accent band switch to on-accent, and labels on the unfocused grey band keep their tokens. AppKit does not rerun a row's body when focus changes, so the library resolves the colour at render time. This applies to ``ShadowListRow``, ``ShadowSidebarLabel`` icons and table cells.
- A label ``ShadowBadge`` on the focused accent band of a Mac list or table row becomes an on-accent outline: no fill, on-accent border, symbol and word, so the status still reads without its colour. Touch list selection is accent-soft, so badges there keep their intent colours.
- iPad table rows get the same on-accent labels and badges on the accent band. iPadOS reports the prominent selection only to the cells of the row that holds keyboard focus, so ``ShadowTable`` tracks its own selection and focus: a cell finished with `.shadowTableCell(row:)` takes on-accent while its row is selected, the table holds keyboard focus and its window is active. The grey band keeps the tokens, including a window that stays visible while another window or app is active.
- Without keyboard focus, for example on a touch-only iPad with no hardware keyboard or Full Keyboard Access, cells follow what iPadOS reports, as before (not verified on a touch-only device). A column without `.shadowTableCell(row:)` follows iPadOS too, so on rows selected in code and further rows of a multiple selection that column keeps its standard colours while the others invert.
- Touch lists keep the accent-soft selection with accent text; grouped sections keep their own selection.

## Mac segmented control

The native segmented control keeps the system accent for the selected segment. It is not redrawn.

## Sheets and popovers

- Sheets are native `.sheet` with `.shadowSheetStyle(_:)`. A partial sheet uses the medium and large glass detents; a form sheet uses `.presentationSizing(.form)`.
- `.shadowFittedDetents()` sizes a sheet, or a popover adapted to a sheet on iPhone, to its content instead of the design spec's medium detent. It also fits iPad form sheets. It wraps the content in its own `ScrollView`, so pass content that does not scroll by itself; a `List` or `ScrollView` inside collapses.
- Dialogs are native `.alert` and `.confirmationDialog`. Pair `.shadowDialogCancelAction()` with `.shadowDestructiveDialogAction()`. On Mac, Return cancels and the destructive action is ⌘⌫.
- The macOS 26 alert hides the app icon for window-attached alerts. This is system behaviour.

## Toasts

Toasts anchor to the top safe area of the window on iPhone and iPad, wherever ``ShadowToastCenter`` is attached, so they never sit under navigation bars or large titles. Mac placement is unchanged. Toasts use dense glass because they carry reading text.

## Controls the library does not restyle

- Toolbar toggles render natively; toolbars ignore custom `ToggleStyle`.
- The Mac Picker pop-up chevron and Mac Slider tick marks stay native.
- The iOS 26 graphical `DatePicker` draws the selected day as an accent-soft disc, not a solid accent disc.
- Mac grouped lists and forms stay the native grey grouped style; the design spec's bordered card per section is not drawn. Native `List` and `Form` cannot produce it.
- Mac list section headers keep the hairline AppKit draws under them; `listRowSeparator(_:)` and `listSectionSeparator(_:)` do not remove it.
- Mac outline disclosure chevrons stay where AppKit places them, in the gutter before the row's indent rather than on the text column.
- The Mac account menu label is drawn by AppKit at its ideal size, so it does not fill its container and its chevron follows the name.

On Mac these native renderings are the spec; the component guides say so.

## Lists and tables

- A ``ShadowListRow`` pads itself only inside ``ShadowGroupedSection``. In a `List` it publishes its insets through `.listRowInsets`. Outside a `List`, wrap it in a grouped section or pad it with `ShadowListMetrics().rowInsets`.
- ``ShadowTable`` is a native `Table` on Mac and regular width, and a row list with a Sort menu on compact width. The caller sorts the rows. Compact rows wrap long identifiers to two lines unless `.shadowListRowSingleLineTitle(truncationMode:)` is applied.
- While loading, ``ShadowTable`` keeps the native header and draws the rows passed in redacted, in the table's own columns, so the skeleton follows the headers. Pass placeholder rows; with none it draws generic bars shaped by `skeletonColumns`, which cannot follow native column widths.
- Table headers are `subheadline` medium in `textSecondary`. Cells are `textPrimary`, because native iPad tables draw later columns secondary. Finish every column's cell with `.shadowTableCell(row:)` so selected rows read on the iPad accent band; on Mac and on the compact list it changes nothing.

## Other decisions

- On iPhone and iPad, a disabled ``ShadowStepper`` dims only the stepper by ``ShadowOpacity`` and stays one VoiceOver element. The touch stepper is drawn without its own label, so its track is the standalone native one, which is slightly darker.
- Native `ColorPicker` and `DatePicker` do not dim themselves when disabled on iOS 26. Callers dim them with ``ShadowOpacity`` and keep the label.
- ``ShadowOneTimeCodeField`` boxes are outlined with `borderControl` on every platform so they reach 3:1 non-text contrast. The spec draws borderless boxes on touch.
- Empty rating stars use `textTertiary` instead of `borderStrong` to reach 3:1.
- Static ``ShadowTag`` is a borderless `surfaceWell` capsule so it never reads as a filter.
- Avatar tints are chosen by a hash of the name, so a name always gets the same tint; changing the hash changes existing tints.
- ``ShadowGlass`` has no tint API. Glass cannot take intent colours.

## Preview hooks

Symbols marked `@_spi(Preview)` exist for the Catalog and screenshot capture, for example `.shadowPreviewInteraction(.pressed)`, `.shadowPreviewFieldFocus(_:)` and `.shadowPreviewHoverEffects(_:)`. Import them with `@_spi(Preview) import ShadowDesignSystem`. Apps should not use them.
