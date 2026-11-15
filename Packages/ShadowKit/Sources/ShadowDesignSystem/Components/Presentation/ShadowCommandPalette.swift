import Accessibility
import SwiftUI

nonisolated public struct ShadowCommandPaletteMetrics: Hashable, Sendable {
  public let width: CGFloat
  public let cornerRadius: CGFloat
  public let fieldHeight: CGFloat
  public let rowHeight: CGFloat
  public let rowCornerRadius: CGFloat
  public let horizontalPadding: CGFloat
  public let listPadding: CGFloat
  public let maximumResultsHeight: CGFloat
  public let topInset: CGFloat
  let fieldStyle: ShadowTextStyle
  let rowStyle: ShadowTextStyle
  let headerStyle: ShadowTextStyle
  let detailStyle: ShadowTextStyle

  public init(density: ShadowDensity = .current) {
    switch density {
    case .touch:
      width = 600
      cornerRadius = Radius.panel
      fieldHeight = 56
      rowHeight = ShadowMetrics.rowTouch
      rowCornerRadius = Radius.xl
      horizontalPadding = Spacing.space4
      listPadding = Spacing.space2
      maximumResultsHeight = 420
      topInset = Spacing.space10 * 2
      fieldStyle = .iosTitle3
      rowStyle = .iosBody
      headerStyle = .iosSubheadline
      detailStyle = .iosFootnote
    case .compact:
      width = 560
      cornerRadius = Radius.xl
      fieldHeight = 44
      rowHeight = ShadowMetrics.controlMacSm
      rowCornerRadius = Radius.md
      horizontalPadding = Spacing.space3
      listPadding = Spacing.space2
      maximumResultsHeight = 320
      topInset = Spacing.space10 * 2
      fieldStyle = .macTitle3
      rowStyle = .macBody
      headerStyle = .macFootnote
      detailStyle = .macFootnote
    }
  }
}

public struct ShadowCommandPalette: View {
  private let sections: [ShadowCommandSection]
  @Binding private var query: String
  private let prompt: LocalizedStringKey
  private let emptyTitle: LocalizedStringKey
  private let focusesSearchOnAppear: Bool
  private let onClose: () -> Void

  @State private var index: ShadowCommandIndex?
  @State private var results: [ShadowCommandResultSection]?
  @State private var cursor = ShadowCommandCursor()
  @State private var resultsHeight: CGFloat?
  @FocusState private var isSearchFocused: Bool
  @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverRunning
  @Environment(\.shadowHoverEffectsEnabled) private var hoverEffectsEnabled

  public init(
    sections: [ShadowCommandSection],
    query: Binding<String>,
    prompt: LocalizedStringKey,
    emptyTitle: LocalizedStringKey,
    focusesSearchOnAppear: Bool = true,
    onClose: @escaping () -> Void
  ) {
    self.sections = sections
    _query = query
    self.prompt = prompt
    self.emptyTitle = emptyTitle
    self.focusesSearchOnAppear = focusesSearchOnAppear
    self.onClose = onClose
  }

  public var body: some View {
    let metrics = ShadowCommandPaletteMetrics()
    VStack(spacing: 0) {
      searchField(metrics)
      Rectangle()
        .fill(ShadowColor.borderSubtle)
        .frame(height: 1)
      if let results {
        if results.isEmpty {
          empty(metrics)
        } else {
          resultList(results, metrics: metrics)
        }
      }
    }
    .frame(maxWidth: metrics.width)
    .shadowGlass(.dense, in: RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous))
    .shadowElevation(.glass)
    .task { if focusesSearchOnAppear { isSearchFocused = true } }
    .onChange(of: ShadowCommandSignature(sections), initial: true) {
      index = ShadowCommandIndex(sections)
      refresh(resetsSelection: false)
    }
    .onChange(of: query) { refresh(resetsSelection: true) }
    .onChange(of: cursor.selection) { _, selection in announce(selection) }
  }

  private func searchField(_ metrics: ShadowCommandPaletteMetrics) -> some View {
    HStack(spacing: Spacing.space2) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(ShadowColor.textSecondary)
        .accessibilityHidden(true)
      TextField(prompt, text: $query)
        .textFieldStyle(.plain)
        .foregroundStyle(ShadowColor.textPrimary)
        .focused($isSearchFocused)
        .focusEffectDisabled()
        .autocorrectionDisabled()
        #if os(iOS) || os(visionOS)
          .textInputAutocapitalization(.never)
        #endif
        .submitLabel(.go)
        .onSubmit(runSelection)
        .onKeyPress(.downArrow) {
          cursor.moveDown()
          return .handled
        }
        .onKeyPress(.upArrow) {
          cursor.moveUp()
          return .handled
        }
        #if os(macOS)
          .onExitCommand(perform: onClose)
        #else
          .onKeyPress(.escape) {
            onClose()
            return .handled
          }
        #endif
      Text(verbatim: "esc")
        .shadowFont(.caption)
        .foregroundStyle(ShadowColor.textTertiary)
        .padding(.horizontal, Spacing.space1)
        .padding(.vertical, Spacing.space05)
        .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(ShadowColor.borderDefault))
        .accessibilityHidden(true)
    }
    .shadowFont(metrics.fieldStyle)
    .fontWeight(.regular)
    .padding(.horizontal, metrics.horizontalPadding)
    .frame(minHeight: metrics.fieldHeight)
  }

  private func resultList(_ results: [ShadowCommandResultSection], metrics: ShadowCommandPaletteMetrics) -> some View {
    ScrollViewReader { proxy in
      ScrollView {
        rows(results, metrics: metrics)
          .onGeometryChange(for: CGFloat.self, of: \.size.height) { resultsHeight = $0 }
      }
      .scrollBounceBehavior(.basedOnSize)
      .frame(height: min(resultsHeight ?? metrics.maximumResultsHeight, metrics.maximumResultsHeight))
      .onChange(of: cursor.selection) { _, selection in
        guard let selection else { return }
        proxy.scrollTo(selection)
      }
    }
  }

  private func rows(_ results: [ShadowCommandResultSection], metrics: ShadowCommandPaletteMetrics) -> some View {
    LazyVStack(alignment: .leading, spacing: 0) {
      ForEach(results) { section in
        Text(verbatim: section.title)
          .shadowFont(metrics.headerStyle)
          .foregroundStyle(ShadowColor.textSecondary)
          .padding(.horizontal, metrics.horizontalPadding - metrics.listPadding)
          .padding(.top, Spacing.space2)
          .padding(.bottom, Spacing.space1)
          .accessibilityAddTraits(.isHeader)
        ForEach(section.results) { result in
          Button {
            run(result.command)
          } label: {
            ShadowCommandRow(result: result, isSelected: cursor.selection == result.id, metrics: metrics)
          }
          .buttonStyle(.plain)
          .onHover { isHovered in if isHovered && hoverEffectsEnabled { cursor.select(result.id) } }
          .accessibilityAddTraits(cursor.selection == result.id ? .isSelected : [])
          .id(result.id)
        }
      }
    }
    .padding(metrics.listPadding)
    .accessibilityElement(children: .contain)
  }

  private func empty(_ metrics: ShadowCommandPaletteMetrics) -> some View {
    VStack(spacing: Spacing.space2) {
      Image(systemName: "magnifyingglass")
        .shadowFont(.title2)
        .foregroundStyle(ShadowColor.textTertiary)
        .accessibilityHidden(true)
      Text(emptyTitle)
        .shadowFont(metrics.rowStyle)
        .foregroundStyle(ShadowColor.textSecondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, Spacing.space8)
    .accessibilityElement(children: .combine)
  }

  private var flatResults: [ShadowCommandResult] { results?.flatMap(\.results) ?? [] }

  private func refresh(resetsSelection: Bool) {
    guard let index else { return }
    let results = index.sections(matching: query)
    self.results = results
    let ids = results.flatMap { $0.results.map(\.id) }
    if resetsSelection {
      cursor = ShadowCommandCursor(ids: ids)
    } else {
      cursor.reconcile(with: ids)
    }
  }

  private func runSelection() {
    guard let selection = cursor.selection, let result = flatResults.first(where: { $0.id == selection }) else { return }
    run(result.command)
  }

  private func run(_ command: ShadowCommand) {
    onClose()
    command.perform()
  }

  private func announce(_ selection: String?) {
    guard isVoiceOverRunning, let selection else { return }
    guard let command = flatResults.first(where: { $0.id == selection })?.command else { return }
    AccessibilityNotification.Announcement(command.title).post()
  }
}

nonisolated struct ShadowCommandSignature: Hashable {
  let value: Int

  init(_ sections: [ShadowCommandSection]) {
    var hasher = Hasher()
    for section in sections {
      hasher.combine(section.id)
      hasher.combine(section.title)
      for command in section.commands {
        hasher.combine(command.id)
        hasher.combine(command.title)
        hasher.combine(command.subtitle)
        hasher.combine(command.keywords)
      }
    }
    value = hasher.finalize()
  }
}

struct ShadowCommandRow: View {
  let result: ShadowCommandResult
  let isSelected: Bool
  let metrics: ShadowCommandPaletteMetrics

  private var isFilled: Bool { isSelected && ShadowDensity.current == .compact }

  var body: some View {
    let command = result.command
    HStack(spacing: Spacing.space2) {
      Image(systemName: command.systemImage)
        .frame(width: metrics.rowHeight * 0.75)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 0) {
        Text(ShadowCommandHighlight.attributed(command.title, offsets: result.match.matchedOffsets, highlight: isFilled ? nil : ShadowColor.accentText))
          .lineLimit(1)
        if let subtitle = command.subtitle {
          Text(verbatim: subtitle)
            .shadowFont(metrics.detailStyle)
            .foregroundStyle(isFilled ? ShadowColor.onAccent : ShadowColor.textSecondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: Spacing.space2)
      if let shortcut = command.shortcut {
        Text(verbatim: ShadowShortcutGlyphs.string(for: shortcut))
          .monospacedDigit()
          .foregroundStyle(isFilled ? ShadowColor.onAccent : ShadowColor.textTertiary)
          .accessibilityHidden(true)
      } else if isSelected {
        Image(systemName: "return")
          .foregroundStyle(isFilled ? ShadowColor.onAccent : ShadowColor.textTertiary)
          .accessibilityHidden(true)
      }
    }
    .shadowFont(metrics.rowStyle)
    .foregroundStyle(isFilled ? ShadowColor.onAccent : ShadowColor.textPrimary)
    .padding(.horizontal, metrics.horizontalPadding - metrics.listPadding)
    .frame(minHeight: metrics.rowHeight)
    .background {
      if isSelected {
        RoundedRectangle(cornerRadius: metrics.rowCornerRadius, style: .continuous)
          .fill(isFilled ? ShadowColor.selectionRow : ShadowColor.bgHover)
      }
    }
    .contentShape(.rect)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: command.title))
    .accessibilityValue(command.subtitle.map { Text(verbatim: $0) } ?? Text(verbatim: ""))
  }
}

nonisolated enum ShadowCommandHighlight {
  static func attributed(_ title: String, offsets: [Int], highlight: Color?) -> AttributedString {
    var attributed = AttributedString(title)
    guard !offsets.isEmpty else { return attributed }
    let matched = Set(offsets)
    var index = attributed.characters.startIndex
    var offset = 0
    while index < attributed.characters.endIndex {
      let next = attributed.characters.index(after: index)
      if matched.contains(offset) {
        attributed[index..<next].inlinePresentationIntent = .stronglyEmphasized
        if let highlight { attributed[index..<next].foregroundColor = highlight }
      }
      index = next
      offset += 1
    }
    return attributed
  }
}

public struct ShadowCommandSearchResults: View {
  private struct Row: Identifiable {
    let result: ShadowCommandResult
    let sectionTitle: String
    var id: String { result.id }
  }

  private let sections: [ShadowCommandSection]
  private let query: String

  public init(sections: [ShadowCommandSection], query: String) {
    self.sections = sections
    self.query = query
  }

  public var body: some View {
    let rows = ShadowCommandFilter.sections(sections, matching: query).flatMap { section in section.results.map { Row(result: $0, sectionTitle: section.title) } }
    ForEach(rows) { row in
      let command = row.result.command
      Button {
        command.perform()
      } label: {
        ShadowListRow(
          title: Text(ShadowCommandHighlight.attributed(command.title, offsets: row.result.match.matchedOffsets, highlight: ShadowColor.accentText)),
          subtitle: Text(verbatim: command.subtitle ?? row.sectionTitle)
        ) {
          ShadowSymbolTile(systemImage: command.systemImage, tint: .neutral)
        } trailing: {
          EmptyView()
        }
      }
      .buttonStyle(.shadowRow)
    }
  }
}

extension View {
  public func shadowCommandPalette(
    isPresented: Binding<Bool>,
    sections: [ShadowCommandSection],
    prompt: LocalizedStringKey,
    emptyTitle: LocalizedStringKey,
    shortcutTitle: LocalizedStringKey,
    shortcut: KeyboardShortcut = KeyboardShortcut("k", modifiers: .command),
    focusesSearchOnPresent: Bool = true
  ) -> some View {
    modifier(
      ShadowCommandPaletteModifier(
        isPresented: isPresented, sections: sections, prompt: prompt, emptyTitle: emptyTitle, shortcutTitle: shortcutTitle, shortcut: shortcut,
        focusesSearchOnPresent: focusesSearchOnPresent))
  }
}

private struct ShadowCommandPaletteModifier: ViewModifier {
  @Binding var isPresented: Bool
  let sections: [ShadowCommandSection]
  let prompt: LocalizedStringKey
  let emptyTitle: LocalizedStringKey
  let shortcutTitle: LocalizedStringKey
  let shortcut: KeyboardShortcut
  let focusesSearchOnPresent: Bool

  @State private var query = ""
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    let metrics = ShadowCommandPaletteMetrics()
    content
      .background {
        Button(shortcutTitle) { isPresented.toggle() }
          .keyboardShortcut(shortcut)
          .opacity(0)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
      .overlay(alignment: .top) {
        ZStack(alignment: .top) {
          if isPresented {
            Color.clear
              .contentShape(.rect)
              .onTapGesture(perform: close)
              .accessibilityHidden(true)
            ShadowCommandPalette(
              sections: sections, query: $query, prompt: prompt, emptyTitle: emptyTitle, focusesSearchOnAppear: focusesSearchOnPresent, onClose: close
            )
            .padding(.horizontal, Spacing.space4)
            .padding(.top, metrics.topInset)
            .accessibilityAddTraits(.isModal)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.96, anchor: .top).combined(with: .opacity))
          }
        }
        .animation(.shadow(.normal, reduceMotion: reduceMotion), value: isPresented)
      }
      .onChange(of: isPresented) { _, isPresented in if !isPresented { query = "" } }
  }

  private func close() {
    isPresented = false
  }
}
