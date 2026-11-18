import ShadowAI
import Testing

@testable import NovelForgeCore

@Suite("Chapter route")
struct ChapterRouteTests {
  private struct Fixture: Decodable {
    struct ModeRow: Decodable {
      let plan: String
      let isolated: Bool?
      let mode: ModelContentMode
    }

    struct ContainmentRow: Decodable {
      let mode: ModelContentMode
      let raised: Bool
      let contained: Bool
      let keys: [String]
    }

    struct TableRow: Decodable {
      let role: String
      let aiRole: String
      let group: String
    }

    struct ScopeRow: Decodable {
      let role: String
      let scope: String
    }

    struct SpecMode: Decodable {
      let mode: ModelContentMode
      let expected: ModelContentMode
    }

    struct SpecContainment: Decodable {
      struct Result: Decodable {
        let generator: String?
        let isolated: Bool?
      }

      let mode: ModelContentMode
      let raised: Bool
      let result: Result
    }

    struct Spec: Decodable {
      let expectedRoles: [String: String]
      let specModes: [SpecMode]
      let specContainment: [SpecContainment]
    }

    let roles: [String]
    let contentModes: [ModeRow]
    let containment: [ContainmentRow]
    let table: [TableRow]
    let scopes: [ScopeRow]
    let inputs: [InputRow]
    let spec: Spec
  }

  private let fixture: Fixture

  init() throws {
    fixture = try ReferenceFixture.decode(from: "chapter-route/chapter-route.json")
  }

  @Test
  func shouldCoverEveryReferenceRole() {
    #expect(fixture.roles == ChapterRole.allCases.map(\.rawValue))
    #expect(fixture.table.map(\.role) == fixture.roles)
  }

  @Test
  func shouldMapEveryRoleToTheReferenceModelRoleAndTheShadowAITask() throws {
    for row in fixture.table {
      let role = try #require(ChapterRole(rawValue: row.role))
      #expect(role.aiRole == row.aiRole, "\(row.role)")
      #expect(role.aiRole == fixture.spec.expectedRoles[row.role], "\(row.role)")
      #expect(role.modelTask.rawValue == row.group, "\(row.role)")
    }
  }

  @Test
  func shouldTakeThePlansModeUnlessTheChapterIsIsolated() {
    for row in fixture.contentModes {
      let plan = ModelContentMode(rawValue: row.plan)
      #expect(chapterContentMode(ChapterModeSource(planMode: plan, isolated: row.isolated ?? false)) == row.mode, "\(row.plan) \(String(describing: row.isolated))")
    }
  }

  @Test
  func shouldReproduceTheReferenceSpecModes() {
    #expect(fixture.spec.specModes.allSatisfy { $0.mode == $0.expected })
    #expect(chapterContentMode(ChapterModeSource(planMode: .standard)) == .standard)
    #expect(chapterContentMode(ChapterModeSource(planMode: .unrestricted)) == .unrestricted)
    #expect(chapterContentMode(ChapterModeSource()) == .standard)
    #expect(chapterContentMode(ChapterModeSource(planMode: .standard, isolated: true)) == .unrestricted)
  }

  @Test
  func shouldIsolateUnrestrictedChaptersAndRaisedCallsOnly() {
    for row in fixture.containment {
      let actual = chapterContainment(mode: row.mode, raised: row.raised)
      #expect((actual != nil) == row.contained, "\(row.mode) \(row.raised)")
      #expect(row.keys == (row.contained ? ["generator", "isolated"] : []))
    }
  }

  @Test
  func shouldReproduceTheReferenceSpecContainment() {
    for row in fixture.spec.specContainment {
      let actual = chapterContainment(mode: row.mode, raised: row.raised)
      #expect((actual == .isolatedUnrestricted) == (row.result.generator == "unrestricted" && row.result.isolated == true))
      #expect((actual == nil) == (row.result.generator == nil))
    }
  }

  @Test
  func shouldScopeEveryRolesOutputAsTheReferenceDoes() {
    for row in fixture.scopes {
      #expect(outputScope(role: row.role).rawValue == row.scope, "\(row.role)")
    }
    for role in ChapterRole.allCases {
      let expected = fixture.scopes.first { $0.role == role.aiRole }?.scope
      #expect(role.outputScope.rawValue == expected, "\(role)")
    }
  }

  @Test
  func shouldScreenWriterInputsAsTheReferenceDoes() {
    #expect(!fixture.inputs.isEmpty)
    for row in fixture.inputs {
      #expect(sameScreens(inputScreens(row.input), row.screens), "\(row.input.entries.map(\.key))")
    }
  }
}
