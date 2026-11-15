import ShadowDesignSystem
import SwiftUI

struct SheetPage: View {
  @State private var showsReadingSettings = false
  @State private var showsChapterDetails = false
  @State private var showsAllChapters = false
  @State private var showsRename = false

  var body: some View {
    ComponentPage(component: .sheet) {
      StateSection(
        "Partial sheet",
        note:
          "Medium and large detents with a grabber. At medium height the sheet floats on Liquid Glass; pulled to full height it turns opaque. Mac shows it as an attached sheet."
      ) {
        PresentationBackdrop(alignment: .bottomLeading) {
          Button("Reading settings…", systemImage: "textformat.size") { showsReadingSettings = true }
            .buttonStyle(.shadowGlass)
        }
      }
      StateSection(
        "Form sheet",
        note: "A focused task with Cancel and Save. iPad centres it over the scrim, Mac attaches it to the window with Save as the default button, iPhone shows it full height."
      ) {
        Button("Edit chapter details…") { showsChapterDetails = true }
          .buttonStyle(.shadowBordered)
      }
      StateSection("Scrollable large sheet", note: "Long content opens at the large detent on surface-raised and scrolls under the inline title.") {
        Button("All chapters…") { showsAllChapters = true }
          .buttonStyle(.shadowBordered)
      }
      StateSection(
        "Unsaved changes",
        note: "Edit the name, then try to close: swipe-to-dismiss is off while there are changes, and Cancel asks before discarding them."
      ) {
        Button("Rename chapter…") { showsRename = true }
          .buttonStyle(.shadowBordered)
      }
    }
    .sheet(isPresented: $showsReadingSettings) {
      ReadingSettingsSheet().shadowSheetStyle(.partial)
    }
    .sheet(isPresented: $showsChapterDetails) {
      ChapterDetailsSheet().shadowSheetStyle(.form)
    }
    .sheet(isPresented: $showsAllChapters) {
      AllChaptersSheet().shadowSheetStyle(.full)
    }
    .sheet(isPresented: $showsRename) {
      RenameChapterSheet().shadowSheetStyle(.form)
    }
    .catalogAutoPresent {
      if DemoPlatform.opensDetail {
        showsChapterDetails = true
      } else {
        showsReadingSettings = true
      }
    }
  }
}

struct ReadingSettingsSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var theme = ReadingTheme.sepia
  @State private var typeface = ReadingTypeface.newYork
  @State private var textSize = 0.45
  @State private var spacing = ReadingSpacing.normal
  @State private var margins = ReadingSpacing.normal
  @State private var scrollMode = true
  @State private var justified = false

  var body: some View {
    Form {
      Section {
        Picker("Theme", selection: $theme) {
          ForEach(ReadingTheme.allCases) { theme in Text(theme.title).tag(theme) }
        }
        .pickerStyle(.menu)
        Picker("Font", selection: $typeface) {
          ForEach(ReadingTypeface.allCases) { typeface in Text(typeface.title).tag(typeface) }
        }
        .pickerStyle(.menu)
        HStack(spacing: Spacing.space3) {
          Image(systemName: "textformat.size.smaller").accessibilityHidden(true)
          Slider(value: $textSize) { Text("Text size") }
          Image(systemName: "textformat.size.larger").accessibilityHidden(true)
        }
        .foregroundStyle(ShadowColor.textSecondary)
      } header: {
        ShadowSectionHeader("Text")
      }
      .modifier(SheetRowBackground())
      Section {
        Picker("Line spacing", selection: $spacing) {
          ForEach(ReadingSpacing.allCases) { spacing in Text(spacing.title).tag(spacing) }
        }
        Picker("Margins", selection: $margins) {
          ForEach(ReadingSpacing.allCases) { margins in Text(margins.title).tag(margins) }
        }
        Toggle("Justify text", isOn: $justified)
        Toggle("Scroll mode", isOn: $scrollMode)
      } header: {
        ShadowSectionHeader("Layout")
      } footer: {
        Text("Changes apply to every chapter of The Ninth Archive.")
      }
      .modifier(SheetRowBackground())
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .shadowSheetHeader(Text("Reading settings"), cancel: ShadowSheetCancel("Close") { dismiss() }, confirm: ShadowSheetConfirm("Done") { dismiss() })
  }
}

private struct SheetRowBackground: ViewModifier {
  func body(content: Content) -> some View {
    #if os(macOS)
      content
    #else
      content.listRowBackground(ShadowColor.surfaceCard)
    #endif
  }
}

private enum ReadingTypeface: String, CaseIterable, Identifiable {
  case newYork
  case sanFrancisco
  case atkinson

  var id: Self { self }

  var title: LocalizedStringKey {
    switch self {
    case .newYork: "New York"
    case .sanFrancisco: "SF Pro"
    case .atkinson: "Atkinson Hyperlegible"
    }
  }
}

private enum ReadingSpacing: String, CaseIterable, Identifiable {
  case compact
  case normal
  case relaxed

  var id: Self { self }

  var title: LocalizedStringKey {
    switch self {
    case .compact: "Compact"
    case .normal: "Normal"
    case .relaxed: "Relaxed"
    }
  }
}

private struct ChapterDetailsSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var title = "The Glass Stair"
  @State private var target = 3_000

  var body: some View {
    fields
      .shadowSheetHeader(Text("Chapter details"), cancel: ShadowSheetCancel("Cancel") { dismiss() }, confirm: ShadowSheetConfirm("Save") { dismiss() })
  }

  @ViewBuilder
  private var fields: some View {
    #if os(macOS)
      Form {
        TextField("Title", text: $title)
          .textFieldStyle(.roundedBorder)
        LabeledContent("Target") {
          HStack(spacing: Spacing.space2) {
            TextField("Target", value: $target, format: .number)
              .textFieldStyle(.roundedBorder)
              .monospacedDigit()
              .labelsHidden()
            Text("words").foregroundStyle(ShadowColor.textSecondary)
          }
        }
      }
      .formStyle(.columns)
      .frame(width: 320)
    #else
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.space5) {
          FieldRow(title: "Title") {
            TextField("Title", text: $title).shadowField()
          }
          FieldRow(title: "Chapter word-count target") {
            TextField("Chapter word-count target", value: $target, format: .number)
              .keyboardType(.numberPad)
              .shadowField()
          }
        }
        .padding(Spacing.space4)
      }
    #endif
  }
}

private struct AllChaptersSheet: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    List {
      Section {
        ForEach(DemoChapter.all) { chapter in
          ShadowListRow(
            title: Text(verbatim: chapter.title), subtitle: Text(verbatim: "\(chapter.heading) · \(chapter.wordCount) words"),
            value: Text(verbatim: chapter.status.rawValue))
        }
      }
    }
    .shadowListStyle(.grouped)
    .scrollContentBackground(.hidden)
    .frame(minHeight: 420)
    .shadowSheetHeader(Text("All chapters"), subtitle: Text("The Ninth Archive"), cancel: ShadowSheetCancel("Close") { dismiss() })
  }
}

private struct RenameChapterSheet: View {
  private static let original = "The Glass Stair"

  @Environment(\.dismiss) private var dismiss
  @State private var title = Self.original
  @State private var guardState = ShadowDismissGuard()

  var body: some View {
    form
      .onChange(of: title) { _, title in guardState.hasUnsavedChanges = title != Self.original }
      .shadowDismissGuard(
        $guardState, title: Text("Discard your changes?"), message: Text("The chapter keeps its current name."), discardTitle: "Discard changes",
        keepEditingTitle: "Keep editing"
      ) {
        dismiss()
      }
      .shadowSheetHeader(
        Text("Rename chapter"), subtitle: guardState.hasUnsavedChanges ? Text("Edited") : nil,
        cancel: ShadowSheetCancel("Cancel") { if guardState.requestDismiss() { dismiss() } },
        confirm: ShadowSheetConfirm("Save", isDisabled: !guardState.hasUnsavedChanges || title.isEmpty) { dismiss() })
  }

  @ViewBuilder
  private var form: some View {
    #if os(macOS)
      Form {
        TextField("Name", text: $title)
      }
      .formStyle(.columns)
      .frame(width: 320)
    #else
      ScrollView {
        FieldRow(title: "Name") {
          TextField("Name", text: $title).shadowField()
        }
        .padding(Spacing.space4)
      }
    #endif
  }
}
