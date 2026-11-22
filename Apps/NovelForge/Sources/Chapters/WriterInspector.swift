import Foundation
import NovelForgeCore
import Observation
import ShadowAppShell
import ShadowCore
import ShadowDesignSystem
import ShadowStore
import SwiftUI

nonisolated struct WriterRun: Equatable, Sendable {
  let key: String
  let attempts: [WriterSnapshotSummary]

  var role: WriterAttemptRole { attempts.first.map { $0.role == .repair ? .draft : $0.role } ?? .draft }
  var started: Date { attempts.first?.recordedAt ?? .distantPast }
}

// apps/novel-forge-web/src/lib/writers-view.ts:4-94
enum WriterDisplay {
  static func runs(_ snapshots: [WriterSnapshotSummary]) -> [WriterRun] {
    var order = [String]()
    var grouped = [String: [WriterSnapshotSummary]]()
    for snapshot in snapshots {
      let kind =
        switch snapshot.role {
        case .passage, .revise, .rewrite: "\(snapshot.role.rawValue):\(snapshot.id.uuidString)"
        case .draft, .repair: "write"
        }
      let key = "\(snapshot.revision):\(kind)"
      if grouped[key] == nil { order.append(key) }
      grouped[key, default: []].append(snapshot)
    }
    return order.map { key in
      WriterRun(key: key, attempts: grouped[key, default: []].sorted { ($0.attempt, $0.recordedAt) < ($1.attempt, $1.recordedAt) })
    }.sorted { $0.started > $1.started }
  }

  static func label(_ role: WriterAttemptRole) -> String {
    switch role {
    case .draft: String(localized: "First draft", table: "Costs")
    case .repair: String(localized: "Repair", table: "Costs")
    case .rewrite: String(localized: "Rewrite", table: "Costs")
    case .revise: String(localized: "Revision", table: "Costs")
    case .passage: String(localized: "Passage rewrite", table: "Costs")
    }
  }

  // Deviation: the reference labels a run "<role> · version N" (writers-view.ts:38); revisions are opaque hashes here, so it is "<role> · <time>".
  static func runLabel(_ run: WriterRun) -> String {
    String(localized: "\(label(run.role)) · \(ChatReplyTag.time(run.started))", table: "Costs")
  }

  static func what(_ snapshot: WriterSnapshotSummary, of total: Int) -> String {
    switch snapshot.role {
    case .repair:
      total > 1 && snapshot.attempt == total
        ? String(localized: "The repair: the earlier attempt's draft plus the check's note — this became the chapter.", table: "Costs")
        : String(localized: "The repair: the earlier attempt's draft plus the check's note.", table: "Costs")
    case .draft:
      total > 1 && snapshot.attempt < total
        ? String(localized: "First draft. A check found a problem, so it was repaired.", table: "Costs")
        : String(localized: "First draft, written from the plan.", table: "Costs")
    case .passage: String(localized: "A rewrite of one passage you selected, with the rest of the chapter for context.", table: "Costs")
    case .revise: String(localized: "A revision of the whole chapter from your note.", table: "Costs")
    case .rewrite: String(localized: "A rewrite of the whole chapter.", table: "Costs")
    }
  }

  static func messageLabel(_ role: String) -> String {
    switch role {
    case "system": String(localized: "Instructions", table: "Costs")
    case "user": String(localized: "Material and request", table: "Costs")
    case "assistant": String(localized: "Earlier reply", table: "Costs")
    default: role
    }
  }

  nonisolated struct KeptBack: Equatable, Sendable {
    let secrecy: [String]
    let budget: [String]
  }

  static func keptBack(_ value: JSONValue) -> KeptBack {
    guard let fields = value.objectValue else { return KeptBack(secrecy: [], budget: []) }
    let withheld = fields["withheldForSecrecy"]?.objectValue ?? [:]
    let secrecy = withheld.sorted { $0.key < $1.key }.compactMap { field, count -> String? in
      guard let count = count.intValue, count > 0 else { return nil }
      return String(localized: "\(Int(count)) passages withheld from \(fieldLabel(field))", table: "Costs")
    }
    let budget = (fields["omittedForBudget"]?.arrayValue ?? []).compactMap { $0.objectValue }.map {
      $0["key"]?.stringValue ?? String(localized: "a section", table: "Costs")
    }
    return KeptBack(secrecy: secrecy, budget: budget)
  }

  private static func fieldLabel(_ field: String) -> String {
    switch field {
    case "prose": String(localized: "earlier prose", table: "Costs")
    case "summary": String(localized: "chapter summaries", table: "Costs")
    case "state": String(localized: "where things stand", table: "Costs")
    case "entity": String(localized: "characters and places", table: "Costs")
    case "reference": String(localized: "references", table: "Costs")
    case "bible_page": String(localized: "Story Bible pages", table: "Costs")
    case "heading": String(localized: "headings", table: "Costs")
    case "plan": String(localized: "the plan", table: "Costs")
    case "style": String(localized: "the style guide", table: "Costs")
    case "writer_line": String(localized: "writer notes", table: "Costs")
    case "knowledge": String(localized: "what characters know", table: "Costs")
    case "note": String(localized: "your notes", table: "Costs")
    case "plugin": String(localized: "plugin material", table: "Costs")
    default: field.replacingOccurrences(of: "_", with: " ")
    }
  }
}

@MainActor
@Observable
final class WriterInspectorModel {
  struct Reader: Sendable {
    let attempts: @Sendable () async throws -> [WriterSnapshotSummary]
    let view: @Sendable (UUID) async throws -> WriterSnapshotView?

    static func store(_ store: VaultStore, novel: UUID, chapter: Int) -> Reader {
      Reader(
        attempts: { try await store.writerSnapshots(novel: novel, chapter: chapter) },
        view: { id in try await store.writerSnapshot(id, novel: novel, chapter: chapter) })
    }
  }

  private let reader: Reader
  private(set) var runs = Loadable<[WriterRun]>.loading
  private(set) var detail = Loadable<WriterSnapshotView?>.loading
  private var runKey: String?
  private var attemptID: UUID?

  init(reader: Reader) {
    self.reader = reader
  }

  var run: WriterRun? {
    guard let runs = runs.value else { return nil }
    return runs.first { $0.key == runKey } ?? runs.first
  }

  var attempt: WriterSnapshotSummary? {
    guard let run else { return nil }
    return run.attempts.first { $0.id == attemptID } ?? run.attempts.last
  }

  func load() async {
    do {
      let attempts = try await reader.attempts()
      runs = .loaded(WriterDisplay.runs(attempts))
    } catch {
      runs = .failed(PresentedError(error))
    }
    await loadDetail()
  }

  func select(run key: String) async {
    runKey = key
    attemptID = nil
    await loadDetail()
  }

  func select(attempt id: UUID) async {
    attemptID = id
    await loadDetail()
  }

  private func loadDetail() async {
    guard let attempt else {
      detail = .loaded(nil)
      return
    }
    detail = .loading
    do {
      let view = try await reader.view(attempt.id)
      guard self.attempt?.id == attempt.id else { return }
      detail = .loaded(view)
    } catch {
      guard self.attempt?.id == attempt.id else { return }
      detail = .failed(PresentedError(error))
    }
  }
}

/// apps/novel-forge-web/src/features/chapter-workspace/WritersView.tsx:22-108; only the device that made a call keeps what it sent.
struct WriterInspector: View {
  @State private var model: WriterInspectorModel

  init(context: NovelContext, chapter: Int) {
    _model = State(initialValue: WriterInspectorModel(reader: .store(context.store, novel: context.novel, chapter: chapter)))
  }

  init(model: WriterInspectorModel) {
    _model = State(initialValue: model)
  }

  var body: some View {
    content
      .task { await model.load() }
  }

  @ViewBuilder
  private var content: some View {
    switch model.runs {
    case .loading:
      ProgressView().frame(maxWidth: .infinity, minHeight: 200)
    case .failed(let error):
      ShadowContentUnavailable(Text("Unavailable", tableName: "Costs"), kind: .error, message: error.text).frame(maxWidth: .infinity, minHeight: 200)
    case .loaded(let runs) where runs.isEmpty:
      ShadowContentUnavailable(
        Text("Nothing stored on this device", tableName: "Costs"), systemImage: "doc.text.magnifyingglass",
        message: Text("The writer's view keeps exactly what the AI writer was sent, on the device that wrote this chapter.", tableName: "Costs")
      )
      .frame(maxWidth: .infinity, minHeight: 200)
    case .loaded(let runs):
      loaded(runs)
    }
  }

  private func loaded(_ runs: [WriterRun]) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space4) {
      if runs.count > 1, let run = model.run { runPicker(runs, selected: run) }
      if let run = model.run, run.attempts.count > 1, let attempt = model.attempt { attemptPicker(run, selected: attempt) }
      if let attempt = model.attempt, let total = model.run?.attempts.count {
        Text(verbatim: WriterDisplay.what(attempt, of: total)).shadowFont(.body)
      }
      detail
      safeguards
    }
  }

  private func runPicker(_ runs: [WriterRun], selected: WriterRun) -> some View {
    Picker(selection: Binding(get: { selected.key }, set: { key in Task { await model.select(run: key) } })) {
      ForEach(runs, id: \.key) { run in Text(verbatim: WriterDisplay.runLabel(run)).tag(run.key) }
    } label: {
      Text("Writing run", tableName: "Costs")
    }
  }

  private func attemptPicker(_ run: WriterRun, selected: WriterSnapshotSummary) -> some View {
    Picker(selection: Binding(get: { selected.id }, set: { id in Task { await model.select(attempt: id) } })) {
      ForEach(run.attempts, id: \.id) { attempt in Text("Attempt \(attempt.attempt)", tableName: "Costs").tag(attempt.id) }
    } label: {
      Text("Attempt", tableName: "Costs")
    }
    .pickerStyle(.segmented)
  }

  @ViewBuilder
  private var detail: some View {
    switch model.detail {
    case .loading:
      ProgressView().frame(maxWidth: .infinity, minHeight: 120)
    case .failed(let error):
      ShadowContentUnavailable(Text("Unavailable", tableName: "Costs"), kind: .error, message: error.text).frame(maxWidth: .infinity, minHeight: 120)
    case .loaded(nil):
      ShadowContentUnavailable(
        Text("This attempt is no longer kept", tableName: "Costs"), systemImage: "doc.text.magnifyingglass",
        message: Text("Only the current version and the two before it keep what was sent.", tableName: "Costs")
      )
      .frame(maxWidth: .infinity, minHeight: 120)
    case .loaded(let view?):
      WriterAttemptView(view: view, total: model.run?.attempts.count ?? 1)
    }
  }

  private var safeguards: some View {
    ShadowGroupedSection {
      VStack(alignment: .leading, spacing: Spacing.space2) {
        safeguard(Text("1 · Kept back.", tableName: "Costs"), Text("A locked secret's truth isn't in the material at all — the app enforces this.", tableName: "Costs"))
        safeguard(
          Text("2 · Give-away words scrubbed.", tableName: "Costs"),
          Text("Words that would give a secret away are removed from what the writer reads. This catches the words, not every paraphrase.", tableName: "Costs"))
        safeguard(
          Text("3 · Checked after.", tableName: "Costs"),
          Text("A checker that knows the secrets reads the chapter and flags an unplanned disclosure. Allowed clues are fine.", tableName: "Costs"))
      }
      .padding(Spacing.space3)
    } header: {
      Text("The three safeguards", tableName: "Costs").shadowFont(.headline)
    }
  }

  private func safeguard(_ title: Text, _ text: Text) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      title.shadowFont(.subheadline)
      text.shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
    }
  }
}

private struct WriterAttemptView: View {
  let view: WriterSnapshotView
  let total: Int

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space4) {
      if view.summary.isolated {
        ShadowCallout(
          Text("Walled off", tableName: "Costs"),
          message: Text("This is an unrestricted chapter, so what the writer was sent isn't shown here.", tableName: "Costs"), intent: .warning
        ) { EmptyView() }
      } else {
        meta
        given
        keptBack
      }
    }
  }

  private var meta: some View {
    let attempt = view.summary.attempt
    let text =
      view.planRevision.map { plan in
        String(localized: "Stored at writing time · attempt \(attempt) of \(total) · plan version \(String(plan.prefix(8)))", table: "Costs")
      } ?? String(localized: "Stored at writing time · attempt \(attempt) of \(total)", table: "Costs")
    return Text(verbatim: text).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
  }

  private var given: some View {
    ShadowGroupedSection {
      ForEach(Array(view.messages.enumerated()), id: \.offset) { index, message in
        if index > 0 { Divider() }
        DisclosureGroup {
          Text(verbatim: message.content)
            .shadowFont(.monoBody)
            .foregroundStyle(ShadowColor.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Spacing.space2)
        } label: {
          Text("\(WriterDisplay.messageLabel(message.role)) · \(message.content.count) characters", tableName: "Costs")
        }
        .padding(Spacing.space3)
      }
    } header: {
      Text("Given", tableName: "Costs").shadowFont(.headline)
    }
  }

  private var keptBack: some View {
    let kept = WriterDisplay.keptBack(view.keptBack)
    let cut = kept.budget.isEmpty ? String(localized: "none", table: "Costs") : kept.budget.joined(separator: ", ")
    return ShadowGroupedSection {
      VStack(alignment: .leading, spacing: Spacing.space1) {
        if kept.secrecy.isEmpty {
          Text("Nothing locked needed withholding", tableName: "Costs")
        } else {
          ForEach(kept.secrecy, id: \.self) { line in Text(verbatim: line) }
        }
        Text(verbatim: String(localized: "Cut for space: \(cut)", table: "Costs"))
          .foregroundStyle(ShadowColor.textSecondary)
      }
      .shadowFont(.footnote)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(Spacing.space3)
    } header: {
      Text("Kept from the writer", tableName: "Costs").shadowFont(.headline)
    }
  }
}

struct ChapterDetailsSheet: View {
  enum Tab: Hashable {
    case writer
    case cost
  }

  let context: NovelContext
  let chapter: Int
  @State private var tab = Tab.writer
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.space4) {
      Picker(selection: $tab) {
        Text("Writer's view", tableName: "Costs").tag(Tab.writer)
        Text("Cost", tableName: "Costs").tag(Tab.cost)
      } label: {
        Text("Chapter details", tableName: "Costs")
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      ScrollView {
        switch tab {
        case .writer: WriterInspector(context: context, chapter: chapter)
        case .cost: RunCharges(context: context, chapter: chapter)
        }
      }
    }
    .shadowSheetHeader(
      Text("Chapter details", tableName: "Costs"), subtitle: Text("Chapter \(chapter)", tableName: "Costs"),
      cancel: ShadowSheetCancel(Text("Done", tableName: "Costs"), systemImage: "checkmark") { dismiss() }
    )
    .shadowSheetStyle(.full)
  }
}

private struct ChapterDetailsModifier: ViewModifier {
  let context: NovelContext
  let chapter: Int
  @State private var presented = false

  func body(content: Content) -> some View {
    content
      .toolbar {
        ToolbarItem {
          Button {
            presented = true
          } label: {
            Label(title: { Text("Details", tableName: "Costs") }, icon: { Image(systemName: "info.circle") })
          }
          .shadowBarItem()
        }
      }
      .sheet(isPresented: $presented) { ChapterDetailsSheet(context: context, chapter: chapter) }
  }
}

extension View {
  func chapterDetails(context: NovelContext, chapter: Int) -> some View {
    modifier(ChapterDetailsModifier(context: context, chapter: chapter))
  }
}
