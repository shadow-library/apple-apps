import Foundation
import NovelForgeCore
import Testing

@testable import NovelForge

@Suite("ChapterGrouping")
struct ChapterGroupingTests {
  private func volume(_ key: String, _ ordinal: Int, state: VolumeState = .notStarted, first: Int? = nil, last: Int? = nil) -> VolumeSummary {
    VolumeSummary(key: key, ordinal: ordinal, title: nil, objective: nil, state: state, planFirst: first, planLast: last)
  }

  @Test("should return one ungrouped list when there are no volumes")
  func ungrouped() {
    let groups = ChapterGrouping.group(volumes: [], chapters: [3, 1, 2])

    #expect(groups.count == 1)
    #expect(groups[0].volume == nil)
    #expect(groups[0].chapters == [1, 2, 3])
  }

  @Test("should place chapters in the volume whose range holds them")
  func byRange() {
    let volumes = [volume("b", 2, first: 4, last: 6), volume("a", 1, first: 1, last: 3)]

    let groups = ChapterGrouping.group(volumes: volumes, chapters: [1, 2, 4, 5])

    #expect(groups.map(\.key) == ["a", "b"])
    #expect(groups.map(\.chapters) == [[1, 2], [4, 5]])
    #expect(groups.map(\.number) == [1, 2])
  }

  @Test("should put an unclaimed chapter past every range into the active volume")
  func pastRanges() {
    let volumes = [volume("a", 1, first: 1, last: 3), volume("b", 2, state: .active, first: 4, last: 5)]

    let groups = ChapterGrouping.group(volumes: volumes, chapters: [1, 6])

    #expect(groups.map(\.chapters) == [[1], [6]])
  }

  @Test("should put an unclaimed chapter inside a gap into the volume before it")
  func inGap() {
    let volumes = [volume("a", 1, first: 1, last: 2), volume("b", 2, first: 6, last: 8)]

    let groups = ChapterGrouping.group(volumes: volumes, chapters: [4])

    #expect(groups.map(\.chapters) == [[4], []])
  }

  @Test("should fall back to the first volume when none has a range")
  func noRanges() {
    let groups = ChapterGrouping.group(volumes: [volume("a", 1), volume("b", 2)], chapters: [1, 2])

    #expect(groups.map(\.chapters) == [[1, 2], []])
  }
}

@Suite("ProseBlocks")
struct ProseBlocksTests {
  @Test("should split paragraphs, headings, scene breaks and quotes")
  func blocks() {
    let blocks = ProseBlocks.parse("# Title\n\nFirst line\nsecond line.\n\n***\n\n> quoted\n\n- one\n- two")

    #expect(
      blocks == [.heading(level: 1, text: "Title"), .paragraph("First line\nsecond line."), .rule, .quote("quoted"), .list(["one", "two"])])
  }

  @Test("should return no blocks for blank text")
  func blank() {
    #expect(ProseBlocks.parse(" \n\n ").isEmpty)
  }

  @Test("should show raw HTML as text and never keep a script link")
  func safe() {
    let blocks = ProseBlocks.parse("<script>x</script> [go](javascript:alert(1))")

    #expect(blocks == [.paragraph("\\<script>x\\</script> go")])
    let attributed = ProseBlocks.attributed("[a](javascript:x) [b](https://example.com)")
    let links = attributed.runs.compactMap(\.link)
    #expect(links == [URL(string: "https://example.com")!])
  }

  @Test("should drop a link whose scheme is not web or mail")
  func schemeFilter() {
    #expect(!ProseBlocks.isSafe(URL(string: "file:///etc/passwd")!))
    #expect(!ProseBlocks.isSafe(URL(string: "relative/path")!))
    #expect(ProseBlocks.isSafe(URL(string: "mailto:a@b.c")!))
    #expect(ProseBlocks.isSafe(URL(string: "HTTPS://example.com")!))
  }
}

@Suite("DraftFile")
struct DraftFileTests {
  @Test("should decode UTF-8 with and without a byte order mark")
  func utf8() throws {
    #expect(try DraftFile.decode(Data("Plain".utf8)) == "Plain")
    #expect(try DraftFile.decode(Data([0xEF, 0xBB, 0xBF] + Array("Marked".utf8))) == "Marked")
  }

  @Test("should refuse binary data")
  func binary() {
    #expect(throws: DraftFileError.notText) { try DraftFile.decode(Data([0x41, 0x00, 0x42])) }
  }

  @Test("should decode UTF-16 of either byte order with its mark")
  func utf16() throws {
    let text = "Héllo 😀"
    let little = Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!
    let big = Data([0xFE, 0xFF]) + text.data(using: .utf16BigEndian)!

    #expect(try DraftFile.decode(little) == text)
    #expect(try DraftFile.decode(big) == text)
  }

  @Test("should refuse UTF-32 and files that are not UTF-8 with a clear reason")
  func unsupported() {
    let utf32 = Data([0xFF, 0xFE, 0x00, 0x00]) + "Hi".data(using: .utf32LittleEndian)!
    let latin1 = "Héllo".data(using: .isoLatin1)!

    #expect(throws: DraftFileError.unsupportedEncoding) { try DraftFile.decode(utf32) }
    #expect(throws: DraftFileError.unsupportedEncoding) { try DraftFile.decode(Data([0x00, 0x00, 0xFE, 0xFF, 0x00, 0x00, 0x00, 0x41])) }
    #expect(throws: DraftFileError.unsupportedEncoding) { try DraftFile.decode(latin1) }
  }

  @Test("should refuse an empty or oversized file and a missing one")
  func files() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let empty = directory.appendingPathComponent("empty.md")
    let large = directory.appendingPathComponent("large.txt")
    let good = directory.appendingPathComponent("good.md")
    try Data("  \n".utf8).write(to: empty)
    try Data(count: DraftFile.maximumBytes + 1).write(to: large)
    try Data("Chapter text.".utf8).write(to: good)

    #expect(throws: DraftFileError.empty) { try DraftFile.read(from: empty) }
    #expect(throws: DraftFileError.tooLarge) { try DraftFile.read(from: large) }
    #expect(throws: DraftFileError.unreadable) { try DraftFile.read(from: directory.appendingPathComponent("none.md")) }
    #expect(try DraftFile.read(from: good) == "Chapter text.")
  }
}

@MainActor
@Suite("ChapterEditorModel")
struct ChapterEditorModelTests {
  private func draft(_ revision: String, body: String) -> ChapterContent.Draft {
    ChapterContent.Draft(revision: revision, title: nil, body: body, summary: nil, source: .handEdited, working: nil)
  }

  private func editor(_ draft: ChapterContent.Draft) throws -> ChapterEditorModel {
    let store = try NovelForgeStore.openInMemory()
    return ChapterEditorModel(chapter: 1, draft: draft, service: ReaderService(store: store, novel: UUID()), autosaveDelay: .seconds(3600))
  }

  @Test("should follow a newer version silently while the text is clean")
  func followsWhenClean() throws {
    let editor = try editor(draft("r1", body: "old"))

    editor.reconcile(with: draft("r2", body: "new"))

    #expect(editor.text.body == "new")
    #expect(editor.base == "r2")
    #expect(editor.status == .idle)
  }

  @Test("should wait for a choice when a newer version arrives over unsaved text")
  func conflictsWhenDirty() throws {
    let editor = try editor(draft("r1", body: "old"))
    editor.text.body = "mine"

    editor.reconcile(with: draft("r2", body: "theirs"))

    #expect(editor.status == .conflict)
    #expect(editor.text.body == "mine")
    #expect(editor.needsAttention)
    let replaced = editor.takeTheirs()
    #expect(replaced?.body == "mine")
    #expect(editor.text.body == "theirs")
    #expect(editor.status == .idle)
    editor.restore(try #require(replaced))
    #expect(editor.text.body == "mine")
  }

  @Test("should keep my text by resting on the newer revision")
  func keepMine() throws {
    let editor = try editor(draft("r1", body: "old"))
    editor.text.body = "mine"
    editor.reconcile(with: draft("r2", body: "theirs"))

    editor.keepMine()

    #expect(editor.base == "r2")
    #expect(editor.status == .idle)
    #expect(editor.text.body == "mine")
  }

  @Test("should lock on a final chapter and keep the text")
  func locks() throws {
    let editor = try editor(draft("r1", body: "old"))
    editor.text.body = "mine"

    editor.reconcileFinal()

    #expect(editor.status == .locked)
    #expect(!editor.isEditable)
    #expect(editor.text.body == "mine")
  }

  @Test("should open on this device's working copy over the head")
  func opensOnWorkingCopy() throws {
    let held = ChapterContent.Draft(
      revision: "r1", title: nil, body: "head", summary: nil, source: .handEdited, working: ChapterText(title: "", body: "autosaved"))

    let editor = try editor(held)

    #expect(editor.text.body == "autosaved")
    #expect(!editor.isDirty)
  }
}
