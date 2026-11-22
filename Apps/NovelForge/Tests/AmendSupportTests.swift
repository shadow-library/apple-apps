import Foundation
import NovelForgeCore
import ShadowAI
import ShadowAppShell
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForge

private struct AmendCredentials: ModelCredentialSource {
  func credential(for provider: ModelProviderKind) async -> ProviderCredential? {
    guard let origin = URL(string: provider == .anthropic ? "https://api.example.com" : "https://router.example.com") else { return nil }
    return ProviderCredential(origin: origin, secret: "sk-test")
  }
}

@MainActor
struct AmendWorld {
  static let prose = "Mara climbed the lighthouse stairs at dusk. She found the logbook open on the desk, its last page torn away."
  static let reply = ScriptedModelProvider.reply(
    String(decoding: CanonicalJSON.encode(["summary": "Mara finds the torn logbook.", "state": ["lastBeat": "Mara stares at the torn page."]]), as: UTF8.self))

  let store: VaultStore
  let novel: UUID
  let engine: JobEngine
  let provider: ScriptedModelProvider

  var context: NovelContext { NovelContext(store: store, novel: novel) }

  static func make(calls: [[ScriptedModelProvider.Step]] = []) async throws -> AmendWorld {
    let store = try NovelForgeStore.openInMemory()
    let novel = try await store.writeDomain { transaction throws(DomainError) in try Library.create(NewNovel(title: "Ashfall"), in: &transaction) }
    let provider = ScriptedModelProvider(calls: calls)
    let standardOrigin = try #require(URL(string: "https://api.example.com"))
    let routerOrigin = try #require(URL(string: "https://router.example.com"))
    let standard = try #require(ProviderBinding(origin: standardOrigin, provider: provider))
    let unrestrictedBinding = try #require(ProviderBinding(origin: routerOrigin, provider: provider))
    let consent = ConsentDisclosure.novelText
    let hosts = [standard.host, unrestrictedBinding.host]
    try await store.write { transaction in
      for host in hosts { try AIConsent.decide(.granted, provider: host, dataClass: consent.dataClass, summary: consent.id, atMillis: 1, in: &transaction) }
    }
    let engine = try JobEngine(
      store: store,
      router: { requestGuard in
        TaskRouter(
          configuration: TaskRouterConfiguration(provider: .anthropic, assignments: OpenRouterAssignments(unrestricted: "or/unrestricted")), anthropic: standard,
          openRouter: unrestrictedBinding, credentials: AmendCredentials(), store: store, requestGuard: requestGuard)
      }, consent: consent.requirement, clock: LeaseClock(trusted: nil), ageGate: AgeGate(passed: true))
    return AmendWorld(store: store, novel: novel, engine: engine, provider: provider)
  }

  func draft(_ body: String = AmendWorld.prose, isolated: Bool = false) async throws {
    let novel = novel
    _ = try await store.write { transaction in
      try ChapterDrafts.importDraft(novel: novel, chapter: 1, DraftImport(prose: body, isolated: isolated), base: nil, in: &transaction)
    }
  }

  func final(_ chapter: Int = 1, title: String = "Done", body: String = AmendWorld.prose) async throws {
    let novel = novel
    try await store.write { transaction in
      _ = try FinalChapterRecord(novel: novel, chapter: chapter, canon: Canon(title: title, body: body)).create(in: &transaction)
    }
  }

  func content(_ chapter: Int = 1) async throws -> ChapterContent {
    try await store.load(ChapterContent.self, ChapterLocator(novel: novel, chapter: chapter))
  }

  func source(_ chapter: Int = 1) async throws -> SummarySource? {
    let novel = novel
    return try await store.read { transaction in
      try SummarySource.load(novel: novel, chapter: chapter, copy: try DraftWorkingCopy.read(novel: novel, chapter: chapter, in: transaction.database), in: transaction)
    }
  }

  func summaryModel(_ summarizer: SummarizeModel.Summarizer? = nil) -> SummarizeModel {
    SummarizeModel(context: context, chapter: 1, summarizer: summarizer ?? SummarizeModel.summarizer(engine))
  }
}
