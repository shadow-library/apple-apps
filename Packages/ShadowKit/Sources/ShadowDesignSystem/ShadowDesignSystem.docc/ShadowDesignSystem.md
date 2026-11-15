# ``ShadowDesignSystem``

Shadow UI for Apple: the Shadow Library brand on native SwiftUI controls, for iOS, iPadOS, macOS and visionOS (minimum OS 26).

## Overview

The library keeps the brand (indigo accent, tinted neutral canvas, hairline borders, flat opaque content) and leaves behaviour, metrics, type and materials to the system.
Native controls are tinted rather than redrawn; custom components exist only where SwiftUI has no equivalent.

- Colour, spacing, radius and type values are semantic tokens generated from `Design/tokens.json`. See <doc:Tokens>.
- Liquid Glass is the system material and belongs to the navigation layer only. See <doc:GlassRules>.
- Where the library follows the platform instead of the Shadow UI design spec, the decision is recorded in <doc:PlatformBehaviour>.

The library contains no user-facing strings. Every title, label and message is passed in by the app.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:Tokens>
- <doc:GlassRules>
- <doc:PlatformBehaviour>

### Tokens

- ``ShadowColor``
- ``ShadowColorToken``
- ``ShadowRGBA``
- ``ShadowTextStyle``
- ``Spacing``
- ``Radius``
- ``ShadowMetrics``
- ``ShadowDensity``
- ``ShadowControlSize``
- ``ShadowOpacity``
- ``ShadowElevation``
- ``ShadowMotion``

### Glass

- ``ShadowGlass``
- ``ShadowGlassGroup``
- ``ShadowMaterialLayer``

### Buttons

- ``ShadowButtonStyle``
- ``ShadowButtonVariant``
- ``ShadowButtonLayout``
- ``ShadowButtonMetrics``
- ``ShadowIconButton``
- ``ShadowIconButtonGroup``

### Cards

- ``ShadowCard``
- ``ShadowCardHeader``
- ``ShadowCardButtonStyle``
- ``ShadowCardMetrics``

### Inputs

- ``ShadowFieldKind``
- ``ShadowFieldPhase``
- ``ShadowFieldMetrics``
- ``ShadowValidationMessage``
- ``ShadowPasswordField``
- ``ShadowSearchField``
- ``ShadowTextEditor``
- ``ShadowCharacterCount``
- ``ShadowStepper``
- ``ShadowRowLabel``
- ``ShadowSwatchPicker``
- ``ShadowSwatch``
- ``ShadowOneTimeCodeField``
- ``ShadowOneTimeCode``
- ``ShadowTokenField``
- ``ShadowTokenRules``
- ``ShadowRating``
- ``ShadowRatingScale``
- ``ShadowFileDropZone``
- ``ShadowFileRow``
- ``ShadowTransferState``
- ``ShadowFlowLayout``

### Status

- ``ShadowIntent``
- ``ShadowBadge``
- ``ShadowBadgeIntent``
- ``ShadowTag``
- ``ShadowAvatar``
- ``ShadowAvatarGroup``
- ``ShadowAvatarTint``
- ``ShadowCallout``
- ``ShadowContentUnavailable``
- ``ShadowLinearProgressStyle``
- ``ShadowRingProgressStyle``
- ``ShadowCapacityGauge``
- ``ShadowSkeletonLine``
- ``ShadowSkeletonCircle``
- ``ShadowSkeletonRectangle``
- ``ShadowStatistic``
- ``ShadowStatisticGrid``
- ``ShadowDelta``
- ``ShadowDeltaBadge``
- ``ShadowSparkline``

### Lists

- ``ShadowListRow``
- ``ShadowListKind``
- ``ShadowListAccessory``
- ``ShadowSectionHeader``
- ``ShadowGroupedSection``
- ``ShadowSymbolTile``
- ``ShadowLabeledContent``
- ``ShadowIdentifierText``
- ``ShadowDetailsForm``
- ``ShadowDisclosureGroupStyle``
- ``ShadowRowAction``
- ``ShadowTreeNode``
- ``ShadowNotification``
- ``ShadowNotificationList``

### Data

- ``ShadowTable``
- ``ShadowChartPalette``
- ``ShadowChartLegend``
- ``ShadowChartCallout``
- ``ShadowSteps``
- ``ShadowPageControl``
- ``ShadowTimeline``
- ``ShadowTimelineItem``

### Navigation

- ``ShadowScreenLevel``
- ``ShadowColumn``
- ``ShadowColumnWidth``
- ``ShadowSidebarLabel``
- ``ShadowSidebarHeader``

### Presentation

- ``ShadowSheetStyle``
- ``ShadowSheetCancel``
- ``ShadowSheetConfirm``
- ``ShadowDismissGuard``
- ``ShadowToast``
- ``ShadowToastButton``
- ``ShadowToastCenter``
- ``ShadowCommand``
- ``ShadowCommandSection``
- ``ShadowCommandPalette``
- ``ShadowAccountMenu``
- ``ShadowOrganizationSwitcher``
- ``ShadowOrganization``
