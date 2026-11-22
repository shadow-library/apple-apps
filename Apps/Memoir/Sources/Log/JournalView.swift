import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// `features/quick-logs/journal-screen.tsx`: write today's entry, find an earlier one, and see the writing streak and mood beside them.
struct JournalView: View {
  @State private var model: JournalModel
  @State private var selection: TextSelection?

  init(context: MemoirScreenContext) {
    _model = State(initialValue: JournalModel(context: context))
  }

  var body: some View {
    LogLoadable(state: model.overview.state, failureTitle: Text("The journal couldn’t be loaded", tableName: "Log")) { overview in
      ScrollView {
        ShadowAdaptiveColumns {
          VStack(alignment: .leading, spacing: Spacing.space4) {
            editor(overview)
            entries(overview)
          }
          rail(overview)
        }
        .padding(Spacing.space4)
      }
    }
    .navigationTitle(Text("Journal", tableName: "Log"))
    .shadowScreen(.pushed)
    .task { await model.observe() }
  }

  private func editor(_ overview: JournalOverview) -> some View {
    @Bindable var model = model
    return ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        if let today = overview.words.last?.date {
          Text(verbatim: LogFormat.dayName(today)).shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
        }
        moodPicker
        toolbar
        TextEditor(text: $model.text, selection: $selection)
          .frame(minHeight: 200)
          .shadowField()
          .disabled(model.isSaving)
          .accessibilityLabel(Text("Journal entry", tableName: "Log"))
          .overlay(alignment: .topLeading) {
            if model.text.isEmpty {
              Text("Write as much or as little as you like. One line counts.", tableName: "Log")
                .foregroundStyle(ShadowColor.textPlaceholder).padding(Spacing.space3).allowsHitTesting(false)
            }
          }
        HStack(spacing: Spacing.space3) {
          Button {
            Task { await model.save() }
          } label: {
            Text("Save entry", tableName: "Log")
          }
          .buttonStyle(.shadowFilled)
          .disabled(!model.canSave)
          .keyboardShortcut(.return, modifiers: .command)
          Group {
            if let mood = model.mood {
              Text("Mood: \(LogFormat.moodLabel(mood))", tableName: "Log")
            } else {
              Text("Mood is optional", tableName: "Log")
            }
          }
          .shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
        }
        LogSaveFeedback(failureTitle: Text("Entry not saved", tableName: "Log"), failure: model.failure, confirmation: model.confirmation)
        EntryCapNote(advisory: model.advisory)
      }
    }
  }

  private var moodPicker: some View {
    HStack(spacing: Spacing.space2) {
      ForEach(JournalEntryRecord.moods, id: \.self) { mood in
        let isSelected = model.mood == mood
        Button {
          model.toggleMood(mood)
        } label: {
          VStack(spacing: Spacing.space1) {
            Text(verbatim: LogFormat.moodGlyph(mood)).shadowFont(.title3)
            Text(verbatim: LogFormat.moodLabel(mood)).shadowFont(.caption)
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(isSelected ? .shadowTinted : .shadowPlain)
        .disabled(model.isSaving)
        .accessibilityLabel(Text(verbatim: LogFormat.moodLabel(mood)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("Mood", tableName: "Log"))
  }

  private var toolbar: some View {
    ShadowFlowLayout {
      ForEach(MarkdownTool.allCases, id: \.self) { tool in
        Button {
          run(tool)
        } label: {
          Text(verbatim: tool.glyph).shadowFont(.headline)
        }
        .buttonStyle(.shadowBordered)
        .disabled(model.isSaving)
        .accessibilityLabel(Text(verbatim: tool.label))
      }
      Text("Markdown-lite · **bold**, _italic_, lists, quotes", tableName: "Log").shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
    }
  }

  private func run(_ tool: MarkdownTool) {
    let text = model.text
    var range = text.endIndex..<text.endIndex
    if case .selection(let selected) = selection?.indices { range = selected }
    let start = text.utf16.distance(from: text.startIndex, to: range.lowerBound)
    let end = text.utf16.distance(from: text.startIndex, to: range.upperBound)
    let edit = model.apply(tool, selectionStart: start, selectionEnd: end)
    let edited = model.text
    let lower = String.Index(utf16Offset: edit.selectionStart, in: edited)
    let upper = String.Index(utf16Offset: edit.selectionEnd, in: edited)
    selection = TextSelection(range: lower..<upper)
  }

  private func entries(_ overview: JournalOverview) -> some View {
    @Bindable var model = model
    let matching = model.entries(in: overview)
    let visible = matching.prefix(model.visibleCount)
    let query = model.search.trimmingCharacters(in: .whitespacesAndNewlines)
    return ShadowCard {
      VStack(alignment: .leading, spacing: Spacing.space3) {
        Group {
          if query.isEmpty {
            Text("\(overview.entries.count) entries", tableName: "Log")
          } else {
            Text("\(matching.count) of \(overview.entries.count) entries", tableName: "Log")
          }
        }
        .shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
        TextField(text: $model.search, prompt: Text("Search entries", tableName: "Log")) { Text("Search journal entries", tableName: "Log") }
          .shadowField()
        if matching.isEmpty {
          if query.isEmpty {
            ShadowContentUnavailable(Text("No entries yet", tableName: "Log"), message: Text("The first one can be a single line.", tableName: "Log"))
          } else {
            ShadowContentUnavailable(
              Text("Nothing matches “\(query)”", tableName: "Log"), kind: .noResults, message: Text("Try a shorter word.", tableName: "Log"))
          }
        }
        ForEach(visible, id: \.entry.id) { summary in
          VStack(alignment: .leading, spacing: Spacing.space1) {
            Text(verbatim: LogFormat.shortDate(summary.entry.date)).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
            Text(verbatim: summary.excerpt).shadowFont(.body).foregroundStyle(ShadowColor.textPrimary)
            Text(verbatim: "\(summary.entry.mood.map(LogFormat.moodLabel) ?? LogFormat.moodLabel(0)) · \(LogFormat.words(summary.wordCount))")
              .shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
          }
          .accessibilityElement(children: .combine)
          Divider()
        }
        if matching.count > visible.count {
          Button {
            model.showMore()
          } label: {
            Text("Show more", tableName: "Log")
          }
          .buttonStyle(.shadowBordered)
        }
        if overview.unreadable > 0 {
          Text("\(overview.unreadable) entries were written by a newer version of Memoir and can’t be shown here.", tableName: "Log")
            .shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
        }
      }
    }
  }

  private func rail(_ overview: JournalOverview) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space4) {
      ShadowCard {
        VStack(alignment: .leading, spacing: Spacing.space3) {
          Text("Writing", tableName: "Log").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
          ShadowStatistic(Text("Current streak", tableName: "Log"), value: Text("\(overview.writingStreakDays) days", tableName: "Log"))
          LogDayChart(LogDayChart.Point.points(overview.words) { Double($0) }, label: Text("Last 28 days of writing", tableName: "Log"), height: 48) {
            Text(LogFormat.words(Int($0)))
          }
          Text("Last 28 days · \(overview.words.count { $0.value != nil }) written", tableName: "Log").shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
        }
      }
      ShadowCard {
        VStack(alignment: .leading, spacing: Spacing.space3) {
          Text("Mood over the month", tableName: "Log").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
          LogDayChart(LogDayChart.Point.points(overview.moods) { Double($0) }, label: Text("Mood over the month", tableName: "Log"), height: 80) {
            Text(verbatim: LogFormat.moodLabel(Int($0)))
          }
          Text(verbatim: LogFormat.moodNote(overview.moods)).shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
        }
      }
      if let earlier = overview.onThisDay {
        ShadowCard {
          VStack(alignment: .leading, spacing: Spacing.space2) {
            Text("On this day", tableName: "Log").shadowFont(.headline).foregroundStyle(ShadowColor.textPrimary)
            Text(verbatim: "\(earlier.year): “\(earlier.excerpt)”").shadowFont(.subheadline).foregroundStyle(ShadowColor.textSecondary)
          }
        }
      }
    }
  }
}

#Preview {
  NavigationStack {
    if let context = try? MemoirScreenContext.inMemory() { JournalView(context: context) }
  }
}
