// Generated from Design/tokens.json by Scripts/generate-design-tokens.swift. Do not edit; run `mise run tokens`.

nonisolated public enum ShadowColorToken: String, CaseIterable, Sendable {
  case surfaceApp = "surface-app"
  case surfaceCard = "surface-card"
  case surfaceWell = "surface-well"
  case surfaceRaised = "surface-raised"
  case surfaceTooltip = "surface-tooltip"
  case surfaceThumb = "surface-thumb"
  case bgHover = "bg-hover"
  case bgPressed = "bg-pressed"
  case textPrimary = "text-primary"
  case textSecondary = "text-secondary"
  case textTertiary = "text-tertiary"
  case textPlaceholder = "text-placeholder"
  case textOnTooltip = "text-on-tooltip"
  case accent = "accent"
  case accentHover = "accent-hover"
  case accentActive = "accent-active"
  case accentSoft = "accent-soft"
  case onAccent = "on-accent"
  case accentText = "accent-text"
  case borderSubtle = "border-subtle"
  case borderDefault = "border-default"
  case borderStrong = "border-strong"
  case borderInteractive = "border-interactive"
  case borderFocus = "border-focus"
  case neutralSolid = "neutral-solid"
  case neutralSolidHover = "neutral-solid-hover"
  case neutralSolidActive = "neutral-solid-active"
  case neutralOnSolid = "neutral-on-solid"
  case neutralBgSubtle = "neutral-bg-subtle"
  case neutralTextOnSubtle = "neutral-text-on-subtle"
  case neutralText = "neutral-text"
  case neutralBorder = "neutral-border"
  case successSolid = "success-solid"
  case successSolidHover = "success-solid-hover"
  case successSolidActive = "success-solid-active"
  case successOnSolid = "success-on-solid"
  case successBgSubtle = "success-bg-subtle"
  case successTextOnSubtle = "success-text-on-subtle"
  case successText = "success-text"
  case successBorder = "success-border"
  case warningSolid = "warning-solid"
  case warningSolidHover = "warning-solid-hover"
  case warningSolidActive = "warning-solid-active"
  case warningOnSolid = "warning-on-solid"
  case warningBgSubtle = "warning-bg-subtle"
  case warningTextOnSubtle = "warning-text-on-subtle"
  case warningText = "warning-text"
  case warningBorder = "warning-border"
  case dangerSolid = "danger-solid"
  case dangerSolidHover = "danger-solid-hover"
  case dangerSolidActive = "danger-solid-active"
  case dangerOnSolid = "danger-on-solid"
  case dangerBgSubtle = "danger-bg-subtle"
  case dangerTextOnSubtle = "danger-text-on-subtle"
  case dangerText = "danger-text"
  case dangerBorder = "danger-border"
  case destructiveLabel = "destructive-label"
  case fillTrack = "fill-track"
  case infoSolid = "info-solid"
  case infoSolidHover = "info-solid-hover"
  case infoSolidActive = "info-solid-active"
  case infoOnSolid = "info-on-solid"
  case infoBgSubtle = "info-bg-subtle"
  case infoTextOnSubtle = "info-text-on-subtle"
  case infoText = "info-text"
  case infoBorder = "info-border"
  case chart1 = "chart-1"
  case chart2 = "chart-2"
  case chart3 = "chart-3"
  case chart4 = "chart-4"
  case chart5 = "chart-5"
  case chart6 = "chart-6"
  case chart7 = "chart-7"
  case chart8 = "chart-8"
  case chartNeutral = "chart-neutral"
  case focusRing = "focus-ring"
  case focusFieldRing = "focus-field-ring"
  case focusFieldRingError = "focus-field-ring-error"
  case scrim = "scrim"
  case glassFill = "glass-fill"
  case glassStroke = "glass-stroke"
  case glassEdge = "glass-edge"
  case glassTint = "glass-tint"
  case glassFillStrong = "glass-fill-strong"
  case glassFillClear = "glass-fill-clear"
  case glassDim = "glass-dim"
  case glassSpecular = "glass-specular"
  case glassTintSoft = "glass-tint-soft"
  case glassSheen = "glass-sheen"
  case glassRim = "glass-rim"
  case glassRimSoft = "glass-rim-soft"
  case selectionRow = "selection-row"

  public var light: ShadowRGBA {
    switch self {
    case .surfaceApp: ShadowRGBA(hex: 0xF5F6F8)
    case .surfaceCard: ShadowRGBA(hex: 0xFFFFFF)
    case .surfaceWell: ShadowRGBA(hex: 0xF0F0F3)
    case .surfaceRaised: ShadowRGBA(hex: 0xFFFFFF)
    case .surfaceTooltip: ShadowRGBA(hex: 0x202226)
    case .surfaceThumb: ShadowRGBA(hex: 0xFFFFFF)
    case .bgHover: ShadowRGBA(hex: 0xF0F0F3)
    case .bgPressed: ShadowRGBA(hex: 0xE5E7EB)
    case .textPrimary: ShadowRGBA(hex: 0x111214)
    case .textSecondary: ShadowRGBA(hex: 0x525866)
    case .textTertiary: ShadowRGBA(hex: 0x707784)
    case .textPlaceholder: ShadowRGBA(hex: 0x9CA3AF)
    case .textOnTooltip: ShadowRGBA(hex: 0xFAFAFB)
    case .accent: ShadowRGBA(hex: 0x4F46E5)
    case .accentHover: ShadowRGBA(hex: 0x4338CA)
    case .accentActive: ShadowRGBA(hex: 0x3730A3)
    case .accentSoft: ShadowRGBA(hex: 0xF0F1FE)
    case .onAccent: ShadowRGBA(hex: 0xFFFFFF)
    case .accentText: ShadowRGBA(hex: 0x4F46E5)
    case .borderSubtle: ShadowRGBA(hex: 0xF0F0F3)
    case .borderDefault: ShadowRGBA(hex: 0xE5E7EB)
    case .borderStrong: ShadowRGBA(hex: 0xC8CDD4)
    case .borderInteractive: ShadowRGBA(hex: 0x9CA3AF)
    case .borderFocus: ShadowRGBA(hex: 0x5B5CEB)
    case .neutralSolid: ShadowRGBA(hex: 0x202226)
    case .neutralSolidHover: ShadowRGBA(hex: 0x343842)
    case .neutralSolidActive: ShadowRGBA(hex: 0x111214)
    case .neutralOnSolid: ShadowRGBA(hex: 0xFFFFFF)
    case .neutralBgSubtle: ShadowRGBA(hex: 0xF5F6F8)
    case .neutralTextOnSubtle: ShadowRGBA(hex: 0x343842)
    case .neutralText: ShadowRGBA(hex: 0x525866)
    case .neutralBorder: ShadowRGBA(hex: 0xE5E7EB)
    case .successSolid: ShadowRGBA(hex: 0x16A34A)
    case .successSolidHover: ShadowRGBA(hex: 0x15803D)
    case .successSolidActive: ShadowRGBA(hex: 0x166534)
    case .successOnSolid: ShadowRGBA(hex: 0xFFFFFF)
    case .successBgSubtle: ShadowRGBA(hex: 0xF0FDF4)
    case .successTextOnSubtle: ShadowRGBA(hex: 0x15803D)
    case .successText: ShadowRGBA(hex: 0x16A34A)
    case .successBorder: ShadowRGBA(hex: 0xBBF7D0)
    case .warningSolid: ShadowRGBA(hex: 0xD97706)
    case .warningSolidHover: ShadowRGBA(hex: 0xB45309)
    case .warningSolidActive: ShadowRGBA(hex: 0x92400E)
    case .warningOnSolid: ShadowRGBA(hex: 0xFFFFFF)
    case .warningBgSubtle: ShadowRGBA(hex: 0xFFFBEB)
    case .warningTextOnSubtle: ShadowRGBA(hex: 0xB45309)
    case .warningText: ShadowRGBA(hex: 0xD97706)
    case .warningBorder: ShadowRGBA(hex: 0xFDE68A)
    case .dangerSolid: ShadowRGBA(hex: 0xDC2626)
    case .dangerSolidHover: ShadowRGBA(hex: 0xB91C1C)
    case .dangerSolidActive: ShadowRGBA(hex: 0x991B1B)
    case .dangerOnSolid: ShadowRGBA(hex: 0xFFFFFF)
    case .dangerBgSubtle: ShadowRGBA(hex: 0xFEF2F2)
    case .dangerTextOnSubtle: ShadowRGBA(hex: 0xB91C1C)
    case .dangerText: ShadowRGBA(hex: 0xDC2626)
    case .dangerBorder: ShadowRGBA(hex: 0xFECACA)
    case .destructiveLabel: ShadowRGBA(hex: 0xB91C1C)
    case .fillTrack: ShadowRGBA(hex: 0xE5E7EB)
    case .infoSolid: ShadowRGBA(hex: 0x4F46E5)
    case .infoSolidHover: ShadowRGBA(hex: 0x4338CA)
    case .infoSolidActive: ShadowRGBA(hex: 0x3730A3)
    case .infoOnSolid: ShadowRGBA(hex: 0xFFFFFF)
    case .infoBgSubtle: ShadowRGBA(hex: 0xF0F1FE)
    case .infoTextOnSubtle: ShadowRGBA(hex: 0x4338CA)
    case .infoText: ShadowRGBA(hex: 0x4F46E5)
    case .infoBorder: ShadowRGBA(hex: 0xC7C8FA)
    case .chart1: ShadowRGBA(hex: 0x2A78D6)
    case .chart2: ShadowRGBA(hex: 0xE2602C)
    case .chart3: ShadowRGBA(hex: 0x199E70)
    case .chart4: ShadowRGBA(hex: 0xB97A00)
    case .chart5: ShadowRGBA(hex: 0xD55181)
    case .chart6: ShadowRGBA(hex: 0x008300)
    case .chart7: ShadowRGBA(hex: 0x6250D6)
    case .chart8: ShadowRGBA(hex: 0xE34948)
    case .chartNeutral: ShadowRGBA(hex: 0x707784)
    case .focusRing: ShadowRGBA(hex: 0x5B5CEB)
    case .focusFieldRing: ShadowRGBA(hex: 0x5B5CEB, alpha: 0.15)
    case .focusFieldRingError: ShadowRGBA(hex: 0xDC2626, alpha: 0.12)
    case .scrim: ShadowRGBA(hex: 0x09090B, alpha: 0.4)
    case .glassFill: ShadowRGBA(hex: 0xFAFAFB, alpha: 0.6)
    case .glassStroke: ShadowRGBA(hex: 0xFFFFFF, alpha: 0.7)
    case .glassEdge: ShadowRGBA(hex: 0x09090B, alpha: 0.1)
    case .glassTint: ShadowRGBA(hex: 0x4F46E5, alpha: 0.88)
    case .glassFillStrong: ShadowRGBA(hex: 0xFAFAFB, alpha: 0.86)
    case .glassFillClear: ShadowRGBA(hex: 0xFFFFFF, alpha: 0.16)
    case .glassDim: ShadowRGBA(hex: 0x000000, alpha: 0.28)
    case .glassSpecular: ShadowRGBA(hex: 0xFFFFFF, alpha: 0.85)
    case .glassTintSoft: ShadowRGBA(hex: 0x4F46E5, alpha: 0.13)
    case .glassSheen: ShadowRGBA(hex: 0xFFFFFF, alpha: 0.38)
    case .glassRim: ShadowRGBA(hex: 0xFFFFFF, alpha: 0.95)
    case .glassRimSoft: ShadowRGBA(hex: 0xFFFFFF, alpha: 0.4)
    case .selectionRow: ShadowRGBA(hex: 0x4F46E5)
    }
  }

  public var dark: ShadowRGBA {
    switch self {
    case .surfaceApp: ShadowRGBA(hex: 0x09090B)
    case .surfaceCard: ShadowRGBA(hex: 0x111214)
    case .surfaceWell: ShadowRGBA(hex: 0xFFFFFF, alpha: 0.04)
    case .surfaceRaised: ShadowRGBA(hex: 0x17181B)
    case .surfaceTooltip: ShadowRGBA(hex: 0xE5E7EB)
    case .surfaceThumb: ShadowRGBA(hex: 0x343842)
    case .bgHover: ShadowRGBA(hex: 0x202226)
    case .bgPressed: ShadowRGBA(hex: 0x343842)
    case .textPrimary: ShadowRGBA(hex: 0xF5F6F8)
    case .textSecondary: ShadowRGBA(hex: 0x9CA3AF)
    case .textTertiary: ShadowRGBA(hex: 0x79808D)
    case .textPlaceholder: ShadowRGBA(hex: 0x707784)
    case .textOnTooltip: ShadowRGBA(hex: 0x111214)
    case .accent: ShadowRGBA(hex: 0x5B5CEB)
    case .accentHover: ShadowRGBA(hex: 0x8283F0)
    case .accentActive: ShadowRGBA(hex: 0xA5A6F5)
    case .accentSoft: ShadowRGBA(hex: 0x5B5CEB, alpha: 0.15)
    case .onAccent: ShadowRGBA(hex: 0xFFFFFF)
    case .accentText: ShadowRGBA(hex: 0x8283F0)
    case .borderSubtle: ShadowRGBA(hex: 0xFFFFFF, alpha: 0.08)
    case .borderDefault: ShadowRGBA(hex: 0x202226)
    case .borderStrong: ShadowRGBA(hex: 0x343842)
    case .borderInteractive: ShadowRGBA(hex: 0x525866)
    case .borderFocus: ShadowRGBA(hex: 0x8283F0)
    case .neutralSolid: ShadowRGBA(hex: 0xE5E7EB)
    case .neutralSolidHover: ShadowRGBA(hex: 0xC8CDD4)
    case .neutralSolidActive: ShadowRGBA(hex: 0xF5F6F8)
    case .neutralOnSolid: ShadowRGBA(hex: 0x111214)
    case .neutralBgSubtle: ShadowRGBA(hex: 0x202226)
    case .neutralTextOnSubtle: ShadowRGBA(hex: 0xC8CDD4)
    case .neutralText: ShadowRGBA(hex: 0x9CA3AF)
    case .neutralBorder: ShadowRGBA(hex: 0x343842)
    case .successSolid: ShadowRGBA(hex: 0x16A34A)
    case .successSolidHover: ShadowRGBA(hex: 0x22C55E)
    case .successSolidActive: ShadowRGBA(hex: 0x4ADE80)
    case .successOnSolid: ShadowRGBA(hex: 0xFFFFFF)
    case .successBgSubtle: ShadowRGBA(hex: 0x16A34A, alpha: 0.15)
    case .successTextOnSubtle: ShadowRGBA(hex: 0x86EFAC)
    case .successText: ShadowRGBA(hex: 0x4ADE80)
    case .successBorder: ShadowRGBA(hex: 0x22C55E, alpha: 0.3)
    case .warningSolid: ShadowRGBA(hex: 0xD97706)
    case .warningSolidHover: ShadowRGBA(hex: 0xF59E0B)
    case .warningSolidActive: ShadowRGBA(hex: 0xFBBF24)
    case .warningOnSolid: ShadowRGBA(hex: 0xFFFFFF)
    case .warningBgSubtle: ShadowRGBA(hex: 0xD97706, alpha: 0.15)
    case .warningTextOnSubtle: ShadowRGBA(hex: 0xFCD34D)
    case .warningText: ShadowRGBA(hex: 0xFBBF24)
    case .warningBorder: ShadowRGBA(hex: 0xF59E0B, alpha: 0.3)
    case .dangerSolid: ShadowRGBA(hex: 0xDC2626)
    case .dangerSolidHover: ShadowRGBA(hex: 0xEF4444)
    case .dangerSolidActive: ShadowRGBA(hex: 0xF87171)
    case .dangerOnSolid: ShadowRGBA(hex: 0xFFFFFF)
    case .dangerBgSubtle: ShadowRGBA(hex: 0xDC2626, alpha: 0.15)
    case .dangerTextOnSubtle: ShadowRGBA(hex: 0xFCA5A5)
    case .dangerText: ShadowRGBA(hex: 0xF87171)
    case .dangerBorder: ShadowRGBA(hex: 0xEF4444, alpha: 0.3)
    case .destructiveLabel: ShadowRGBA(hex: 0xF87171)
    case .fillTrack: ShadowRGBA(hex: 0x525866)
    case .infoSolid: ShadowRGBA(hex: 0x4F46E5)
    case .infoSolidHover: ShadowRGBA(hex: 0x5B5CEB)
    case .infoSolidActive: ShadowRGBA(hex: 0x8283F0)
    case .infoOnSolid: ShadowRGBA(hex: 0xFFFFFF)
    case .infoBgSubtle: ShadowRGBA(hex: 0x5B5CEB, alpha: 0.15)
    case .infoTextOnSubtle: ShadowRGBA(hex: 0xA5A6F5)
    case .infoText: ShadowRGBA(hex: 0x8283F0)
    case .infoBorder: ShadowRGBA(hex: 0x5B5CEB, alpha: 0.3)
    case .chart1: ShadowRGBA(hex: 0x3987E5)
    case .chart2: ShadowRGBA(hex: 0xD95926)
    case .chart3: ShadowRGBA(hex: 0x199E70)
    case .chart4: ShadowRGBA(hex: 0xC98500)
    case .chart5: ShadowRGBA(hex: 0xD55181)
    case .chart6: ShadowRGBA(hex: 0x008300)
    case .chart7: ShadowRGBA(hex: 0x9085E9)
    case .chart8: ShadowRGBA(hex: 0xE66767)
    case .chartNeutral: ShadowRGBA(hex: 0x79808D)
    case .focusRing: ShadowRGBA(hex: 0x8283F0)
    case .focusFieldRing: ShadowRGBA(hex: 0x8283F0, alpha: 0.2)
    case .focusFieldRingError: ShadowRGBA(hex: 0xDC2626, alpha: 0.12)
    case .scrim: ShadowRGBA(hex: 0x000000, alpha: 0.72)
    case .glassFill: ShadowRGBA(hex: 0x28292E, alpha: 0.58)
    case .glassStroke: ShadowRGBA(hex: 0xFFFFFF, alpha: 0.16)
    case .glassEdge: ShadowRGBA(hex: 0x000000, alpha: 0.5)
    case .glassTint: ShadowRGBA(hex: 0x5B5CEB, alpha: 0.86)
    case .glassFillStrong: ShadowRGBA(hex: 0x222328, alpha: 0.84)
    case .glassFillClear: ShadowRGBA(hex: 0xFFFFFF, alpha: 0.08)
    case .glassDim: ShadowRGBA(hex: 0x000000, alpha: 0.38)
    case .glassSpecular: ShadowRGBA(hex: 0xFFFFFF, alpha: 0.18)
    case .glassTintSoft: ShadowRGBA(hex: 0x8283F0, alpha: 0.16)
    case .glassSheen: ShadowRGBA(hex: 0xFFFFFF, alpha: 0.03)
    case .glassRim: ShadowRGBA(hex: 0xFFFFFF, alpha: 0.28)
    case .glassRimSoft: ShadowRGBA(hex: 0xFFFFFF, alpha: 0.08)
    case .selectionRow: ShadowRGBA(hex: 0x5B5CEB)
    }
  }
}
