// Generated from Design/tokens.json by Scripts/generate-design-tokens.swift. Do not edit; run `mise run tokens`.

import SwiftUI

nonisolated public enum ShadowColor {
  /// Window and screen background: iOS grouped background, macOS window background. Content cards sit on it.
  public static let surfaceApp: Color = ShadowColorToken.surfaceApp.color

  /// Cards, inset grouped list sections, table bodies and control fills that must read against surface-app.
  public static let surfaceCard: Color = ShadowColorToken.surfaceCard.color

  /// Recessed fills: segmented-control track, search field, text field fill on iOS, skeleton bars.
  public static let surfaceWell: Color = ShadowColorToken.surfaceWell.color

  /// Menus, popovers, alerts and sheets that sit above content. Dark mode lifts it instead of casting a shadow.
  public static let surfaceRaised: Color = ShadowColorToken.surfaceRaised.color

  /// Mac help tags (.help) only. Text on it is text-on-tooltip.
  public static let surfaceTooltip: Color = ShadowColorToken.surfaceTooltip.color

  /// The selected segment's thumb resting on surface-well.
  public static let surfaceThumb: Color = ShadowColorToken.surfaceThumb.color

  /// Pointer hover on iPad and Mac rows and plain buttons. Never used on iPhone.
  public static let bgHover: Color = ShadowColorToken.bgHover.color

  /// Pressed state for rows and plain buttons on every platform.
  public static let bgPressed: Color = ShadowColorToken.bgPressed.color

  /// Titles and body copy on surface-app, surface-card and surface-raised. 15:1 or better in both themes.
  public static let textPrimary: Color = ShadowColorToken.textPrimary.color

  /// Subtitles, row detail text and field labels on every surface. At least 4.5:1 on surface-app in both themes.
  public static let textSecondary: Color = ShadowColorToken.textSecondary.color

  /// Footnotes, section footers and timestamps on surface-card (4.8:1 light). Source pair flagged: 4.2:1 on surface-app in light, so on the bare
  /// background use it only at 15px+ or switch to text-secondary.
  public static let textTertiary: Color = ShadowColorToken.textTertiary.color

  /// Placeholder text in empty fields only; never for content. Decorative contrast by design (below 4.5:1).
  public static let textPlaceholder: Color = ShadowColorToken.textPlaceholder.color

  /// Text on surface-tooltip.
  public static let textOnTooltip: Color = ShadowColorToken.textOnTooltip.color

  /// The app tint: filled buttons, selected controls, switch on-track, progress fill, selection checkmarks. One accent per screen.
  public static let accent: Color = ShadowColorToken.accent.color

  /// Filled button under the iPad/Mac pointer.
  public static let accentHover: Color = ShadowColorToken.accentHover.color

  /// Filled button while pressed.
  public static let accentActive: Color = ShadowColorToken.accentActive.color

  /// Tinted button fill, selected sidebar row, selected list row background.
  public static let accentSoft: Color = ShadowColorToken.accentSoft.color

  /// Labels and glyphs on accent and accent-hover fills.
  public static let onAccent: Color = ShadowColorToken.onAccent.color

  /// Accent used as text: links, plain buttons, nav bar buttons, selected sidebar label. 4.5:1 on surface-card and accent-soft.
  public static let accentText: Color = ShadowColorToken.accentText.color

  /// Hairlines inside a card: list row separators on surface-card, dividers between grouped controls.
  public static let borderSubtle: Color = ShadowColorToken.borderSubtle.color

  /// Outer border of cards, bordered buttons, fields and tables. Separators on surface-app.
  public static let borderDefault: Color = ShadowColorToken.borderDefault.color

  /// Switch off-track, bordered button under pointer, stronger dividers.
  public static let borderStrong: Color = ShadowColorToken.borderStrong.color

  /// Checkbox and radio outlines on Mac; field border under the pointer.
  public static let borderInteractive: Color = ShadowColorToken.borderInteractive.color

  /// Field border while editing (iOS) or key focus (Mac).
  public static let borderFocus: Color = ShadowColorToken.borderFocus.color

  /// Solid fill for a neutral button or count badge.
  public static let neutralSolid: Color = ShadowColorToken.neutralSolid.color

  /// Neutral solid fill under the pointer.
  public static let neutralSolidHover: Color = ShadowColorToken.neutralSolidHover.color

  /// Neutral solid fill while pressed.
  public static let neutralSolidActive: Color = ShadowColorToken.neutralSolidActive.color

  /// Neutral fill that carries white text in both themes, such as a swipe action. neutral-solid turns light in dark mode.
  public static let neutralSolidStrong: Color = ShadowColorToken.neutralSolidStrong.color

  /// Text and glyphs on the neutral solid fill.
  public static let neutralOnSolid: Color = ShadowColorToken.neutralOnSolid.color

  /// Background of neutral callouts, tags and subtle badges.
  public static let neutralBgSubtle: Color = ShadowColorToken.neutralBgSubtle.color

  /// Text on neutral-bg-subtle. At least 4.5:1 in both themes.
  public static let neutralTextOnSubtle: Color = ShadowColorToken.neutralTextOnSubtle.color

  /// Neutral text and glyphs on surface-card and surface-app: validation messages, status labels.
  public static let neutralText: Color = ShadowColorToken.neutralText.color

  /// Border of neutral callouts and tags.
  public static let neutralBorder: Color = ShadowColorToken.neutralBorder.color

  /// Solid fill for a success button or count badge.
  public static let successSolid: Color = ShadowColorToken.successSolid.color

  /// Success solid fill under the pointer.
  public static let successSolidHover: Color = ShadowColorToken.successSolidHover.color

  /// Success solid fill while pressed.
  public static let successSolidActive: Color = ShadowColorToken.successSolidActive.color

  /// Text and glyphs on the success solid fill.
  public static let successOnSolid: Color = ShadowColorToken.successOnSolid.color

  /// Background of success callouts, tags and subtle badges.
  public static let successBgSubtle: Color = ShadowColorToken.successBgSubtle.color

  /// Text on success-bg-subtle. At least 4.5:1 in both themes.
  public static let successTextOnSubtle: Color = ShadowColorToken.successTextOnSubtle.color

  /// Success glyphs and 3:1 marks (checkmarks, status dots) on surface-card. Source pair flagged: 3.3:1 in light, below 4.5:1 for text; set
  /// success copy in success-text-on-subtle on success-bg-subtle or pair the glyph with text-secondary words.
  public static let successText: Color = ShadowColorToken.successText.color

  /// Border of success callouts and tags.
  public static let successBorder: Color = ShadowColorToken.successBorder.color

  /// Solid fill for a warning button or count badge.
  public static let warningSolid: Color = ShadowColorToken.warningSolid.color

  /// Warning solid fill under the pointer.
  public static let warningSolidHover: Color = ShadowColorToken.warningSolidHover.color

  /// Warning solid fill while pressed.
  public static let warningSolidActive: Color = ShadowColorToken.warningSolidActive.color

  /// Warning fill that carries white text, such as a swipe action. warning-solid is too light for text.
  public static let warningSolidStrong: Color = ShadowColorToken.warningSolidStrong.color

  /// Text and glyphs on the warning solid fill.
  public static let warningOnSolid: Color = ShadowColorToken.warningOnSolid.color

  /// Background of warning callouts, tags and subtle badges.
  public static let warningBgSubtle: Color = ShadowColorToken.warningBgSubtle.color

  /// Text on warning-bg-subtle. At least 4.5:1 in both themes.
  public static let warningTextOnSubtle: Color = ShadowColorToken.warningTextOnSubtle.color

  /// Warning glyphs and 3:1 marks on surface-card. Source pair flagged: 3.2:1 in light, below 4.5:1 for text; set warning copy in
  /// warning-text-on-subtle on warning-bg-subtle.
  public static let warningText: Color = ShadowColorToken.warningText.color

  /// Border of warning callouts and tags.
  public static let warningBorder: Color = ShadowColorToken.warningBorder.color

  /// Solid fill for a destructive button or count badge.
  public static let dangerSolid: Color = ShadowColorToken.dangerSolid.color

  /// Destructive solid fill under the pointer.
  public static let dangerSolidHover: Color = ShadowColorToken.dangerSolidHover.color

  /// Destructive solid fill while pressed.
  public static let dangerSolidActive: Color = ShadowColorToken.dangerSolidActive.color

  /// Text and glyphs on the destructive solid fill.
  public static let dangerOnSolid: Color = ShadowColorToken.dangerOnSolid.color

  /// Background of destructive callouts, tags and subtle badges.
  public static let dangerBgSubtle: Color = ShadowColorToken.dangerBgSubtle.color

  /// Text on destructive-bg-subtle. At least 4.5:1 in both themes.
  public static let dangerTextOnSubtle: Color = ShadowColorToken.dangerTextOnSubtle.color

  /// Destructive text and glyphs on surface-card and surface-app: validation messages, status labels.
  public static let dangerText: Color = ShadowColorToken.dangerText.color

  /// Border of destructive callouts and tags.
  public static let dangerBorder: Color = ShadowColorToken.dangerBorder.color

  /// Apple addition: destructive labels on light surfaces and glass (Delete in menus, alerts, swipe-free rows, validation messages). 6.5:1 on
  /// surface-card in light; danger-text stays for glyphs and 3:1 marks.
  public static let destructiveLabel: Color = ShadowColorToken.destructiveLabel.color

  /// Apple addition: the unfilled part of slider and progress tracks, visible on cards, panels and glass in both themes.
  public static let fillTrack: Color = ShadowColorToken.fillTrack.color

  /// Solid fill for a informational button or count badge.
  public static let infoSolid: Color = ShadowColorToken.infoSolid.color

  /// Informational solid fill under the pointer.
  public static let infoSolidHover: Color = ShadowColorToken.infoSolidHover.color

  /// Informational solid fill while pressed.
  public static let infoSolidActive: Color = ShadowColorToken.infoSolidActive.color

  /// Text and glyphs on the informational solid fill.
  public static let infoOnSolid: Color = ShadowColorToken.infoOnSolid.color

  /// Background of informational callouts, tags and subtle badges.
  public static let infoBgSubtle: Color = ShadowColorToken.infoBgSubtle.color

  /// Text on informational-bg-subtle. At least 4.5:1 in both themes.
  public static let infoTextOnSubtle: Color = ShadowColorToken.infoTextOnSubtle.color

  /// Informational text and glyphs on surface-card and surface-app: validation messages, status labels.
  public static let infoText: Color = ShadowColorToken.infoText.color

  /// Border of informational callouts and tags.
  public static let infoBorder: Color = ShadowColorToken.infoBorder.color

  /// Chart series 1 (Swift Charts foregroundStyle). Slot order is the colour-blind safety mechanism: append, never reorder.
  public static let chart1: Color = ShadowColorToken.chart1.color

  /// Chart series 2 (Swift Charts foregroundStyle). Slot order is the colour-blind safety mechanism: append, never reorder.
  public static let chart2: Color = ShadowColorToken.chart2.color

  /// Chart series 3 (Swift Charts foregroundStyle). Slot order is the colour-blind safety mechanism: append, never reorder.
  public static let chart3: Color = ShadowColorToken.chart3.color

  /// Chart series 4 (Swift Charts foregroundStyle). Slot order is the colour-blind safety mechanism: append, never reorder.
  public static let chart4: Color = ShadowColorToken.chart4.color

  /// Chart series 5 (Swift Charts foregroundStyle). Slot order is the colour-blind safety mechanism: append, never reorder.
  public static let chart5: Color = ShadowColorToken.chart5.color

  /// Chart series 6 (Swift Charts foregroundStyle). Slot order is the colour-blind safety mechanism: append, never reorder.
  public static let chart6: Color = ShadowColorToken.chart6.color

  /// Chart series 7 (Swift Charts foregroundStyle). Slot order is the colour-blind safety mechanism: append, never reorder.
  public static let chart7: Color = ShadowColorToken.chart7.color

  /// Chart series 8 (Swift Charts foregroundStyle). Slot order is the colour-blind safety mechanism: append, never reorder.
  public static let chart8: Color = ShadowColorToken.chart8.color

  /// Chart axes, gridline labels and the 'other' series.
  public static let chartNeutral: Color = ShadowColorToken.chartNeutral.color

  /// Keyboard focus ring on iPad (hardware keyboard) and Mac. Solid, 3:1 on every surface.
  public static let focusRing: Color = ShadowColorToken.focusRing.color

  /// Soft halo around a focused text field, outside its focus-ring border.
  public static let focusFieldRing: Color = ShadowColorToken.focusFieldRing.color

  /// Soft halo around a focused text field that has an error.
  public static let focusFieldRingError: Color = ShadowColorToken.focusFieldRingError.color

  /// Dimming behind alerts and modal sheets on iPhone and iPad. Mac sheets do not dim.
  public static let scrim: Color = ShadowColorToken.scrim.color

  /// Regular Liquid Glass for the navigation layer in previews: bar buttons, tab bar, toolbars, sidebars, partial sheets. Apps use the system
  /// material (.glassEffect()), never this colour.
  public static let glassFill: Color = ShadowColorToken.glassFill.color

  /// Rim of glass shapes in previews; reads as the lens edge.
  public static let glassStroke: Color = ShadowColorToken.glassStroke.color

  /// Outer hairline that separates glass from the content beneath it.
  public static let glassEdge: Color = ShadowColorToken.glassEdge.color

  /// Tinted glass for the one prominent action on a bar (.glassProminent): Done, Verify, New. Label is on-accent.
  public static let glassTint: Color = ShadowColorToken.glassTint.color

  /// Denser regular glass for panels that carry reading text: menus, popovers, alerts, confirmation dialogs, the command palette. Keeps
  /// text-primary above 4.5:1 over any content.
  public static let glassFillStrong: Color = ShadowColorToken.glassFillStrong.color

  /// Clear glass, only over media (covers, photos, charts drawn full-bleed). Always paired with glass-dim and on-accent-white glyphs.
  public static let glassFillClear: Color = ShadowColorToken.glassFillClear.color

  /// Dimming layer under clear glass so its glyphs stay legible on bright media.
  public static let glassDim: Color = ShadowColorToken.glassDim.color

  /// Top-edge specular highlight of glass in previews; the system draws this from the device's motion.
  public static let glassSpecular: Color = ShadowColorToken.glassSpecular.color

  /// Selected item inside a glass bar: the tab bar pill, the active glass segment.
  public static let glassTintSoft: Color = ShadowColorToken.glassTintSoft.color

  /// Top-down sheen across glass in previews: the light the lens catches.
  public static let glassSheen: Color = ShadowColorToken.glassSheen.color

  /// Bright corner of the glass rim in previews (top-leading edge).
  public static let glassRim: Color = ShadowColorToken.glassRim.color

  /// Dim corner of the glass rim in previews (bottom-trailing edge).
  public static let glassRimSoft: Color = ShadowColorToken.glassRimSoft.color

  /// Selected row in a focused Mac table or sidebar. Label switches to on-accent.
  public static let selectionRow: Color = ShadowColorToken.selectionRow.color
}
