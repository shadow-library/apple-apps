import Foundation
import Testing

@testable import NovelForgeCore

@Suite("Stored zip", .timeLimit(.minutes(2)))
struct StoredZipTests {
  private func entry(_ name: String, _ text: String) -> ZipEntry { ZipEntry(name: name, data: Data(text.utf8)) }

  @Test func shouldComputeTheStandardCRC32CheckValue() {
    #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    #expect(CRC32.checksum(Data()) == 0)
  }

  @Test func shouldReadBackWhatItWrote() throws {
    let entries = [entry("chapters/0001.md", "One."), entry("empty.md", ""), entry("日本語/ünï 🌊.md", "Text"), entry("manifest.json", "{}")]
    #expect(try ZipReading.entries(StoredZip.write(entries)) == entries)
  }

  @Test func shouldWriteAnEmptyArchiveAsOneEndRecord() throws {
    let archive = try StoredZip.write([])
    #expect(archive.count == 22)
    #expect(try ZipReading.entries(archive).isEmpty)
  }

  @Test func shouldWriteTheSameBytesForTheSameEntries() throws {
    let entries = (1...40).map { entry("chapters/\(String(format: "%04d", $0)).md", String(repeating: "Line \($0).\n", count: $0)) }
    #expect(try StoredZip.write(entries) == StoredZip.write(entries))
  }

  @Test func shouldKeepEntryOrderAndRawBytes() throws {
    let binary = ZipEntry(name: "b.bin", data: Data((0...255).map(UInt8.init)))
    let entries = [entry("z.md", "z"), binary, entry("a.md", "a")]
    #expect(try ZipReading.entries(StoredZip.write(entries)).map(\.name) == ["z.md", "b.bin", "a.md"])
    #expect(try ZipReading.entries(StoredZip.write(entries))[1] == binary)
  }

  @Test func shouldRefuseMoreEntriesThanAPlainArchiveHolds() throws {
    let tooMany = (0..<65536).map { ZipEntry(name: "f\($0)", data: Data()) }
    #expect(throws: ExportError.archiveTooManyEntries(count: 65536)) { try StoredZip.write(tooMany) }
    let limit = (0..<65535).map { ZipEntry(name: "f\($0)", data: Data()) }
    #expect(try ZipReading.entries(StoredZip.write(limit)).count == 65535)
  }

  @Test func shouldRefuseAnEntryOrArchiveBeyondTheSizeLimit() {
    let limits = ZipLimits(entries: 10, bytes: 100)
    #expect(throws: ExportError.archiveEntryTooLarge(name: "big", bytes: 101)) { try StoredZip.write([ZipEntry(name: "big", data: Data(count: 101))], limits: limits) }
    #expect(throws: ExportError.archiveTooLarge(bytes: 120)) {
      try StoredZip.write([ZipEntry(name: "a", data: Data(count: 20)), ZipEntry(name: "b", data: Data(count: 20))], limits: limits)
    }
  }

  @Test func shouldKeepTheStandardLimitsBelowZip64() {
    #expect(ZipLimits.standard.entries == 65535)
    #expect(ZipLimits.standard.bytes == 0xFFFF_FFFE)
  }

  @Test func shouldRefuseEmptyOversizedAndDuplicateNames() {
    #expect(throws: ExportError.archiveNameInvalid("")) { try StoredZip.write([ZipEntry(name: "", data: Data())]) }
    let long = String(repeating: "a", count: 65536)
    #expect(throws: ExportError.archiveNameInvalid(long)) { try StoredZip.write([ZipEntry(name: long, data: Data())]) }
    #expect(throws: ExportError.archiveDuplicateName("a.md")) { try StoredZip.write([ZipEntry(name: "a.md", data: Data()), ZipEntry(name: "a.md", data: Data())]) }
  }

  @Test func shouldBeAcceptedByTheSystemUnzipWhenItIsInstalled() throws {
    let unzip = "/usr/bin/unzip"
    try #require(FileManager.default.isExecutableFile(atPath: unzip), "unzip is not installed")
    let entries = [entry("chapters/0001.md", String(repeating: "Tide. ", count: 5000)), entry("日本語 ünï.md", "Text"), entry("manifest.json", "{\n  \"a\": 1\n}")]
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stored-zip-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = directory.appendingPathComponent("test.novel")
    try StoredZip.write(entries).write(to: archive)

    let test = try run(unzip, ["-t", archive.path])
    #expect(test.status == 0)
    #expect(test.output.contains("No errors detected"))

    // Apple's unzip mangles UTF-8 names on extraction, so only the ASCII entries are extracted; -t above still checks them all.
    let plain = entries.filter { $0.name.utf8.allSatisfy { $0 < 0x80 } }
    let plainArchive = directory.appendingPathComponent("plain.novel")
    try StoredZip.write(plain).write(to: plainArchive)
    let extracted = directory.appendingPathComponent("out")
    #expect(try run(unzip, ["-q", plainArchive.path, "-d", extracted.path]).status == 0)
    for item in plain {
      #expect(try Data(contentsOf: extracted.appendingPathComponent(item.name)) == item.data)
    }
  }

  private func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: output, as: UTF8.self))
  }
}
