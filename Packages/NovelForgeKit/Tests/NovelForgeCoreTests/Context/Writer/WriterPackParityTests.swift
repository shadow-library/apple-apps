import Foundation
import Testing

@testable import NovelForgeCore

struct WriterPackParityTests {
  private static let fixture = WriterPackFixture.shared

  private func expectOutcome(
    _ outcome: Result<WriterPack, WriterPackError>, _ expected: WriterPackFixture.Expected, _ name: String, sourceLocation: SourceLocation = #_sourceLocation
  ) {
    switch outcome {
    case .success(let pack):
      #expect(expected.error == nil, "\(name): the reference failed with \(expected.error?.message ?? "")", sourceLocation: sourceLocation)
      if expected.error == nil { expectSamePack(pack, expected, name, sourceLocation: sourceLocation) }
    case .failure(let error):
      #expect(expected.error?.code == error.code, "\(name): \(error.errorDescription ?? error.code)", sourceLocation: sourceLocation)
      #expect(writerPackFailureMessage(error) == expected.error?.message, "\(name): message", sourceLocation: sourceLocation)
    }
  }

  @Test func shouldAssembleEachWorldAsForChapterDoes() throws {
    for scenario in try Self.fixture.get().scenarios {
      let spec = scenario.spec
      let outcome = Result { () throws(WriterPackError) in try WriterPackAssembler.assemble(try! spec.world(), chapter: spec.chapter, options: spec.options).pack }
      expectOutcome(outcome, scenario.expected, spec.name)
    }
  }

  @Test func shouldAssembleTheVaultAsForChapterDoes() async throws {
    for scenario in try Self.fixture.get().scenarios where scenario.spec.storable {
      let spec = scenario.spec
      let store = try await WriterPackVault.build(spec)
      let load = try await WriterPackVault.load(store, chapter: spec.chapter)
      #expect(load.unreadable.isEmpty, "\(spec.name): unreadable \(load.unreadable)")
      let window = (spec.chapter - 3)...(spec.chapter - 1)
      let read = spec.drafts.filter { window.contains($0.chapter) }.sorted { $0.chapter < $1.chapter }
      #expect(load.world.drafts.map(\.chapter) == read.map(\.chapter), "\(spec.name): drafts read")
      #expect(load.world.drafts.map { $0.staleReason != nil } == read.map(\.stale), "\(spec.name): stale drafts")
      let outcome = await Result { () async throws(WriterPackError) in try await store.writerPack(novel: WriterPackVault.novel, chapter: spec.chapter, options: spec.options).pack }
      expectOutcome(outcome, scenario.expected, "\(spec.name) (vault)")
    }
  }

  @Test func shouldFailOversizedReservationsWithTheReferenceMessage() throws {
    let fixture = try Self.fixture.get()
    #expect(fixture.defaultBudget == WriterPackOptions.defaultBudget)
    for fit in fixture.fits {
      let reservations = fit.reservations.map { WriterReservation(name: $0.name, tokens: $0.tokens, cap: $0.cap, fromPlan: $0.fromPlan) }
      do {
        try assertWriterContextFits(reservations, budgetTokens: fit.budgetTokens)
        #expect(fit.error == nil, "fits: \(fit.error?.message ?? "")")
      } catch {
        #expect(writerPackFailureMessage(error) == fit.error?.message)
      }
    }
  }

  @Test func shouldCoverEveryKindOfScenario() throws {
    let scenarios = try Self.fixture.get().scenarios
    let packs = scenarios.compactMap(\.expected.sections)
    #expect(scenarios.filter(\.spec.storable).count >= 30)
    #expect(scenarios.contains { $0.expected.error != nil && $0.spec.storable })
    #expect(scenarios.contains { $0.spec.permissive && $0.expected.error == nil })
    #expect(packs.contains { $0.contains { $0.key == "open_canon" } })
    #expect(packs.contains { $0.contains { $0.key == "completed_volumes" } })
    #expect(packs.contains { $0.contains { $0.key == "continuation_state" } })
    #expect(packs.contains { $0.contains { $0.key == "character_state" } })
    #expect(packs.contains { $0.contains { $0.key == "relationships" } })
    #expect(packs.contains { $0.contains { $0.key == "hidden_constraints" } })
    #expect(packs.contains { $0.contains { $0.rendered.contains(ChatPack.noApprovedBridge) } })
    #expect(scenarios.contains { !($0.expected.omitted ?? []).isEmpty })
    #expect(scenarios.contains { !($0.expected.withheldRefs ?? []).isEmpty })
    #expect(scenarios.contains { scenario in scenario.spec.drafts.contains { $0.chapter > scenario.spec.chapter || $0.chapter < scenario.spec.chapter - 3 } })
    #expect(try Self.fixture.get().fits.contains { fit in fit.reservations.filter(\.fromPlan).reduce(0) { $0 + $1.tokens } * 2 == fit.reservations.reduce(0) { $0 + $1.tokens } })
  }
}
