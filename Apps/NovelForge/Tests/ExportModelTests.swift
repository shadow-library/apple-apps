import Foundation
import NovelForgeCore
import ShadowAppShell
import ShadowTestSupport
import Testing

@testable import NovelForge

@MainActor
@Suite("ExportModel")
struct ExportModelTests {
  @Test("should export the manuscript as the bytes the core produces")
  func exportsTheManuscript() async throws {
    let world = try await AmendWorld.make()
    try await world.final(1, title: "One", body: "First chapter.")
    try await world.final(2, title: "Two", body: "Second chapter.")
    let model = ExportModel(context: world.context)

    await model.prepare(.manuscript, title: "Ashfall")

    let expected = try await world.store.exportManuscript(novel: world.novel)
    #expect(model.prepared?.document.data == Data(expected.utf8) && model.isExporting && model.prepared?.filename == "Ashfall.md")
    #expect(expected.contains("First chapter.") && expected.contains("Second chapter."))
    model.finish()
    #expect(!model.isExporting && model.prepared == nil)
  }

  @Test("should export the .novel package as the core's bytes under the core's filename")
  func exportsThePackage() async throws {
    let world = try await AmendWorld.make()
    try await world.final(1, title: "One", body: "First chapter.")
    let model = ExportModel(context: world.context)

    await model.prepare(.package, title: "Ashfall")

    let package = try await world.store.exportPackage(novel: world.novel)
    #expect(model.prepared?.document.data == package.bytes && model.prepared?.filename == package.filename && model.prepared?.type == ExportDocument.novelPackage)
  }

  @Test("should refuse a novel with nothing to export with EXP_001 and its headline")
  func refusesAnEmptyNovel() async throws {
    let world = try await AmendWorld.make()
    let model = ExportModel(context: world.context)

    await model.prepare(.package, title: "Ashfall")

    #expect(!model.isExporting && model.failure?.detail == "EXP_001" && model.failure?.headline == ExportErrors.headline(code: "EXP_001"))
    model.dismissFailure()
    #expect(model.failure == nil)
  }

  @Test("should make a safe file name from a title")
  func namesTheFile() {
    #expect(ExportModel.filename("A/B: C?", extension: "md") == "A B C.md")
    #expect(ExportModel.filename("  ", extension: "md") == "Novel.md")
  }

  @Test("should send nothing to a model while exporting")
  func exportsWithoutAModel() async throws {
    let world = try await AmendWorld.make()
    try await world.final()
    let model = ExportModel(context: world.context)

    await model.prepare(.manuscript, title: "Ashfall")
    await model.prepare(.package, title: "Ashfall")

    #expect(world.provider.requests.isEmpty)
  }
}
