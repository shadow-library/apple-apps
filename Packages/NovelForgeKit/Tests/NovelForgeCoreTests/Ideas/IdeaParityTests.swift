import Testing

@testable import NovelForgeCore

struct IdeaIdParityTests {
  private static let cases = Result { try IdeaIdCase.load() }

  @Test func shouldIdentifyEveryIdeaAsTheReference() throws {
    let identity = try #require(IdeaIdentity.shared)
    for (position, item) in try Self.cases.get().enumerated() {
      let ops = try parseOps(item.ops)
      #expect(ops.map(identity.ideaId(of:)) == item.ideaIds, "case \(position): ideaId")
    }
  }

  @Test func shouldLabelEveryIdeaAsTheReference() throws {
    for (position, item) in try Self.cases.get().enumerated() {
      let labels = try parseOps(item.ops).map(ideaLabel)
      #expect(labels.count == item.labels.count)
      for (label, expected) in zip(labels, item.labels) {
        #expect(label?.jsEquals(expected ?? "") ?? (expected == nil), "case \(position): \(String(describing: label)) vs \(String(describing: expected))")
      }
    }
  }

  @Test func shouldStampContentOpsAndClearActionOps() throws {
    let identity = try #require(IdeaIdentity.shared)
    for (position, item) in try Self.cases.get().enumerated() {
      let stamped = identity.stampIdeaIds(try parseOps(item.ops))
      #expect(stamped.map(\.metadata.ideaId) == item.stamped, "case \(position): stamped")
    }
  }

  @Test func shouldCoverEveryOperationKind() throws {
    var kinds = Set<OpType>()
    for item in try Self.cases.get() { kinds.formUnion(try parseOps(item.ops).map(\.type)) }
    #expect(kinds == Set(OpType.allCases))
  }
}

struct IdeaFilterParityTests {
  private static let cases = Result { try IdeaFilterCase.load() }

  @Test func shouldFilterRejectedIdeasAsTheReference() throws {
    let identity = try #require(IdeaIdentity.shared)
    var dropping = 0
    for (position, item) in try Self.cases.get().enumerated() {
      let input = try item.input
      let split = WritePolicy.split(input)
      let label = "case \(position)"
      #expect(IdeaStrings.equal(identity.filterableIdeaIds(split), item.filterable), "\(label): filterable")
      let result = identity.dropRejectedIdeas(split, rejected: Set(item.rejected.map { JSString($0) }), current: input.state)
      #expect(IdeaStrings.equal(result.dropped, item.dropped), "\(label): dropped")
      #expect(result.split.ops == item.keptIndexes.map { split.ops[$0] }, "\(label): ops")
      #expect(result.split.dispositions.map(\.encoded) == item.dispositions, "\(label): dispositions")
      #expect(result.split.dispositions.map(\.index) == Array(result.split.ops.indices), "\(label): indexes")
      #expect(result.split.held.rawValue == item.held, "\(label): held")
      #expect(result.split.sources.map(\.rawValue) == item.sources, "\(label): sources")
      #expect(result.split.direct.count == item.directCount && result.split.cards.count == item.cardCount, "\(label): sides")
      #expect((result.split == split) == item.unchanged, "\(label): unchanged")
      if !result.dropped.isEmpty { dropping += 1 }
    }
    #expect(dropping > 300)
  }

  @Test func shouldNeverTurnACardIntoADirectOp() throws {
    let identity = try #require(IdeaIdentity.shared)
    for (position, item) in try Self.cases.get().enumerated() {
      let input = try item.input
      let split = WritePolicy.split(input)
      let result = identity.dropRejectedIdeas(split, rejected: Set(item.rejected.map { JSString($0) }), current: input.state)
      let before = Dictionary(uniqueKeysWithValues: zip(split.ops.indices, split.dispositions.map(\.side)))
      let kept = Set(item.keptIndexes)
      #expect(result.split.dispositions.map(\.side) == split.dispositions.indices.filter(kept.contains).map { before[$0] }, "case \(position)")
      #expect(!result.split.dispositions.contains { $0.encoded == "c:held_for_review" } || split.dispositions.contains { $0.encoded == "c:held_for_review" })
    }
  }

  @Test func shouldNeverDropAnOpTheAuthorsWordsBack() throws {
    let identity = try #require(IdeaIdentity.shared)
    for (position, item) in try Self.cases.get().enumerated() {
      let input = try item.input
      let split = WritePolicy.split(input)
      let everything = Set(split.ops.map { JSString(identity.ideaId(of: $0)) })
      let result = identity.dropRejectedIdeas(split, rejected: everything, current: input.state)
      let backed = split.dispositions.enumerated().filter { _, disposition in
        switch disposition {
        case .direct(_, let source): source == .quoted
        case .card(_, let reason, _): [.justDiscussing, .manualMode, .heldForReview, .dependsOnCard].contains(reason)
        }
      }
      for (index, _) in backed { #expect(result.split.ops.contains(split.ops[index]), "case \(position): op \(index)") }
    }
  }
}

struct IdeaRejectionParityTests {
  private static let fixture = Result { try RejectionFixture.load() }

  @Test func shouldJudgeEveryScopeAsTheReference() throws {
    let fixture = try Self.fixture.get()
    for (position, item) in fixture.scopes.enumerated() {
      let context = fixture.contexts[item.context].context
      #expect(rejectionInScope(try item.entry, context) == item.inScope, "case \(position)")
    }
    for scope in LedgerRejectionScope.allCases {
      #expect(fixture.scopes.contains { $0.scope == scope.rawValue && $0.inScope }, "no in-scope \(scope)")
      #expect(fixture.scopes.contains { $0.scope == scope.rawValue && !$0.inScope }, "no lapsed \(scope)")
    }
  }

  @Test func shouldAnchorEveryScopeAsTheReference() throws {
    let fixture = try Self.fixture.get()
    for (position, item) in fixture.anchors.enumerated() {
      let anchor = rejectionAnchor(item.scope, fixture.contexts[item.context].context, refs: item.refs)
      #expect((anchor?.json.jsonText ?? "null").jsEquals(item.anchor), "case \(position)")
    }
  }

  @Test func shouldNameTheRefsToLoadAsTheReference() throws {
    for (position, item) in try Self.fixture.get().refs.enumerated() {
      #expect(IdeaStrings.equal(rejectionStateRefs(for: try parseLedgerEntries(item.entries), refs: item.refs), item.wanted), "case \(position)")
    }
  }

  @Test func shouldSelectActiveRejectionsAsTheReferenceQueries() throws {
    var rejecting = 0
    for (position, item) in try Self.fixture.get().ledger.enumerated() {
      let entries = try parseLedgerEntries(item.entries).filter { $0.ideaId != nil }
      let volumes = try parseLedgerVolumes(item.volumes)
      let rejected = activeRejectedIdeas(item.ideaIds, entries: entries, volumes: volumes, artifactStates: [:])
      #expect(rejected == Set(item.rejected.map { JSString($0) }), "case \(position): rejected")
      if !rejected.isEmpty { rejecting += 1 }
    }
    #expect(rejecting > 5)
  }

  @Test func shouldDropLapsedRejectionsAsTheReference() throws {
    for (position, item) in try Self.fixture.get().ledger.enumerated() {
      let entries = try parseLedgerEntries(item.entries)
      let volumes = try parseLedgerVolumes(item.volumes)
      let indexed = entries.enumerated().map { (index: $0, entry: $1) }
      let kept = withoutLapsedRejections(indexed, rejection: \.entry, volumes: volumes, artifactStates: [:]).map(\.index)
      #expect(kept == item.keptIndexes, "case \(position)")
    }
  }
}

struct NegationEchoParityTests {
  private static let fixture = Result { try NegationFixture.load() }

  @Test func shouldFindEchoesAsTheReference() throws {
    let detector = try #require(NegationEchoDetector.shared)
    var found = 0
    for (position, item) in try Self.fixture.get().echoes.enumerated() {
      let echoes = detector.findNegationEchoes(before: item.before, after: item.after, options: NegationEchoOptions(exempt: Set(item.exempt.map { JSString($0) })))
      #expect(echoes.count == item.echoes.count, "case \(position): count")
      for (echo, expected) in zip(echoes, item.echoes) {
        #expect(IdeaStrings.equal(echo.terms, expected.terms), "case \(position): terms \(echo.terms) vs \(expected.terms)")
        #expect(echo.excerpt.jsEquals(expected.excerpt), "case \(position): excerpt")
      }
      if !echoes.isEmpty { found += 1 }
    }
    #expect(found > 100)
  }

  @Test func shouldFindRequestedNegationsAsTheReference() throws {
    let detector = try #require(NegationEchoDetector.shared)
    var found = 0
    for (position, item) in try Self.fixture.get().requests.enumerated() {
      let terms = detector.requestedNegations(item.message)
      #expect(IdeaStrings.equal(terms, item.terms), "case \(position): \(terms) vs \(item.terms)")
      if !terms.isEmpty { found += 1 }
    }
    #expect(found > 20)
  }
}
