import Foundation
import ShadowAI
import ShadowCore
import ShadowJobs
import ShadowStore

/// Why a refresh reads nothing (chapter-canon-refresh.service.ts:23, :69-78): `superseded` is a canon another device finalized first, which its own job refreshes.
enum RefreshSettled: String, Sendable {
  case notFinal = "not_final"
  case isolated
  case alreadyRefreshed = "already_refreshed"
  case superseded
}

struct RefreshSubject: Sendable {
  let novel: NovelRecord
  let mode: ContentMode
  let rows: RefreshRows
  /// Every page and record the refresh read, live or not, as `loadArtifactStates` keys them.
  let baseline: ArtifactStates
}

enum RefreshReading: Sendable {
  case settled(RefreshSettled)
  case subject(RefreshSubject)
}

enum RefreshRead {
  /// chapter-canon-refresh.service.ts:68-78 and :170-218: one read for the material and the baseline, so an edit landing between them conflicts at apply instead
  /// of being overwritten by a fix written from older text. A part of the Story Bible this device cannot read refuses the refresh.
  static func read(_ store: VaultStore, novel: UUID, chapter: Int, canonDigest: String) async throws -> RefreshReading {
    do {
      return try await store.read { transaction in try reading(novel: novel, chapter: chapter, canonDigest: canonDigest, in: transaction) }
    } catch {
      throw PlanCall.unwrapped(error)
    }
  }

  private static func reading(novel: UUID, chapter: Int, canonDigest: String, in transaction: ReadTransaction) throws -> RefreshReading {
    guard let final = try RefreshRecords.finalChapter(novel: novel, chapter: chapter, in: transaction) else { return .settled(.notFinal) }
    guard final.canonDigest.utf8.elementsEqual(canonDigest.utf8) else { return .settled(.superseded) }
    if try RefreshRecords.refreshed(novel: novel, chapter: chapter, canonDigest: canonDigest, in: transaction) { return .settled(.alreadyRefreshed) }
    if final.canon.isolated { return .settled(.isolated) }
    guard case .readable(let entry) = try NovelRecord.read(id: novel, in: transaction), !entry.isRemoved else { throw CanonRefreshError.novelUnavailable }
    guard let mode = entry.record.contentMode.known else { throw CanonRefreshError.contentModeUnknown(entry.record.contentMode.rawValue) }

    var unreadable = [String]()
    let pages = try PageRecord.indexedListing(novel: novel, in: transaction)
    if pages.unreadable > 0 { unreadable.append("pages") }
    let entities = try EntityRecord.indexedListing(novel: novel, in: transaction)
    if entities.unreadable > 0 { unreadable.append("entities") }
    let secrets = try SecretRecord.indexedListing(novel: novel, in: transaction)
    if secrets.unreadable > 0 { unreadable.append("secrets") }
    guard unreadable.isEmpty else { throw CanonRefreshError.refsUnreadable(unreadable) }
    let disclosed = try ReaderDisclosure.load(novel, in: transaction)

    let documents = pages.live.map { RefreshDocumentRow(section: $0.section.rawValue, slug: $0.slug, body: $0.content.body) }.sorted { left, right in
      left.section.jsEquals(right.section) ? JSText.codeUnitPrecedes(left.slug, right.slug) : JSText.codeUnitPrecedes(left.section, right.section)
    }
    let records = entities.live.map { entity in
      RefreshEntityRow(
        entityKey: entity.entity, type: entity.type.rawValue, name: entity.name, status: entity.status, motivation: entity.motivation, notes: entity.notes,
        body: entity.body)
    }.sorted { left, right in
      left.type.jsEquals(right.type) ? JSText.codeUnitPrecedes(left.entityKey, right.entityKey) : JSText.codeUnitPrecedes(left.type, right.type)
    }
    // A disclosure this device cannot derive leaves the fact a secret, the stricter reading.
    let facts = secrets.live.map { secret in
      let fact = DisclosureFact(secret: secret, disclosedInChapter: disclosed.chapter(of: secret.secret).value ?? nil)
      return RefreshFactRow(
        factKey: fact.factKey, text: fact.text, writerNote: fact.writerNote, terms: fact.terms, allowedClues: fact.allowedClues, revealChapter: fact.revealChapter,
        disclosedInChapter: fact.disclosedInChapter, source: fact.source)
    }.sorted { JSText.codeUnitPrecedes($0.factKey, $1.factKey) }

    let text = final.text
    let rows = RefreshRows(
      documents: documents, entities: records, facts: facts,
      chapter: RefreshChapterRow(number: chapter, title: text.title, summary: text.summary, content: text.body),
      reviewItems: try reviewItems(of: final.canon, novel: novel, chapter: chapter, in: transaction))
    let refs = documents.map(\.label) + records.map(\.label)
    let baseline = ArtifactStates(try ArtifactStateLoader.states(refs: refs, novel: novel, in: transaction))
    return .subject(RefreshSubject(novel: entry.record, mode: mode, rows: rows, baseline: baseline))
  }

  /// chapter-canon-refresh.service.ts:199-210: the answered items of the review the canon applied, its summary left out, in position order; the answers come
  /// along the chain that ends at that review, as the gate read them. A canon that applied no review answered nothing.
  private static func reviewItems(of canon: Canon, novel: UUID, chapter: Int, in transaction: ReadTransaction) throws -> [RefreshReviewItem] {
    guard let bound = canon.review?.id else { return [] }
    guard case .readable(let review) = try FinalizeReviewRecord.read(id: bound, in: transaction) else { throw CanonRefreshError.reviewUnreadable(chapter: chapter) }
    let reads = try FinalizeReviewRecord.listing(novel: novel, chapter: chapter, in: transaction).entries
    let chain = FinalizeReviewChain.chain(reads, head: review.record.draftRevision)
    let applied = chain.last?.record.id == bound ? chain : [review]
    let answers = try FinalizeReviewChain.answers(to: applied, novel: novel, chapter: chapter, in: transaction)
    guard let resolved = FinalizeReviewChain.resolve(chain: applied, answers: answers) else { return [] }
    return resolved.items.sorted { $0.stored.position < $1.stored.position }.compactMap { item in
      guard let answered = item.item, answered.category != .summary, let decision = answered.decision else { return nil }
      return RefreshReviewItem(claim: answered.claim, decision: decision)
    }
  }
}

enum RefreshCall {
  /// chapter-canon-refresh.service.ts:87-107: the reference's audit role groups with review (defaults.ts:53), as continuity does, and its plugin policy is the
  /// novel's own class with no plugins natively (plugin-policy.service.ts:69-71), so an unrestricted novel's refresh is routed unrestricted (model-router.service.ts:375-378)
  /// and screened for the hard line by `context.call`. A chapter with no title, summary or prose is not sent: no update can stand without a verified quote of it
  /// (bible-audit-report.ts:258). Nil when nothing was found.
  static func report(_ subject: RefreshSubject, in context: JobStepContext) async throws -> RefreshCheckpoint? {
    let (novel, chapter) = (context.target.novel, context.target.chapter)
    let material = RefreshMaterialRender.render(subject.rows)
    let chapterRef = "chapter:\(chapter)"
    guard !(material.sources[JSString(chapterRef)] ?? "").isEmpty else { return nil }
    guard let rule = QuoteRule.shared else { throw CanonRefreshError.quoteRuleUnavailable }
    let route: ChapterCallRoute
    do {
      route = try ChapterCallRouter.route(
        ChapterCallSource(novel: novel, chapter: chapter, role: .continuity, plan: ChapterPlanContent(body: "", contentMode: .known(subject.mode)), isolated: false),
        unrestrictedAvailable: context.unrestrictedAvailable)
    } catch {
      throw CanonRefreshError.route(error)
    }
    let prompt = canonRefreshRequest(material: material.bible, chapterProse: material.chapter)
    let result: StructuredResult
    do {
      result = try await context.call(
        route, pace: subject.novel.costTier.known?.pace ?? .steady,
        screening: OrderedJSONObject([("material", .string(material.bible)), ("chapterProse", .string(material.chapter))]),
        request: { call in prompt.modelRequest(model: call.route.model, maxOutputTokens: call.route.maxOutputTokens, effort: call.route.effort) },
        name: canonRefreshSchemaName, schema: JSONValue(schema: canonRefreshConstrainedSchema), review: canonRefreshReview())
    } catch {
      throw CanonRefreshError.call(error)
    }
    guard let output = try? OrderedJSON(parsing: String(decoding: result.json, as: UTF8.self)), let updates = RefreshUpdate.updates(in: output) else {
      throw CanonRefreshError.outputUnreadable
    }
    let built = try build(updates, chapterRef: chapterRef, material: material, rows: subject.rows, rule: rule)
    guard !built.findings.isEmpty else { return nil }
    let changeSet = try built.changeSet.map { op throws(CanonRefreshError) -> JSONValue in
      guard let stored = OrderedJSON.object(op.fields).storable else { throw .unstorable }
      return stored
    }
    let refs = changeSetRefs(built.changeSet)
    let baseline = ArtifactStates(Dictionary(refs.map { (JSString($0), subject.baseline[$0] ?? .missing) }) { first, _ in first })
    // chapter-canon-refresh.service.ts:107; the report's `copy` is this summary in full, and the card's summary its first 300 code units (:120).
    let copy = "Chapter \(chapter): \(renderRefreshSummary(built.findings, checkedCopy: material.checked.copy))"
    return RefreshCheckpoint(findings: built.findings.map(\.json), checked: material.checked.json, copy: copy, changeSet: changeSet, baseline: baseline)
  }

  // chapter-canon-refresh.service.ts:96-104
  static func build(_ updates: [RefreshUpdate], chapterRef: String, material: RefreshMaterial, rows: RefreshRows, rule: QuoteRule) throws -> BuiltRefreshReport {
    var current = [JSString: [String: OrderedJSON]]()
    for document in rows.documents { current[JSString(document.label)] = ["body": document.body.map(OrderedJSON.string) ?? .null] }
    for entity in rows.entities {
      let fields: [(String, String?)] = [
        ("type", entity.type), ("name", entity.name), ("status", entity.status), ("motivation", entity.motivation), ("notes", entity.notes), ("body", entity.body),
      ]
      current[JSString(entity.label)] = Dictionary(uniqueKeysWithValues: fields.map { ($0.0, $0.1.map(OrderedJSON.string) ?? .null) })
    }
    let labels: [String] = rows.documents.map(\.label) + rows.entities.map(\.label)
    let secrets: [RefreshSecret] = rows.facts.filter(\.isSecret).map { RefreshSecret(text: $0.text, terms: $0.terms) }
    let input = RefreshReportInput(
      updates: updates, chapterRef: chapterRef, sources: material.sources, partial: material.partial, existingRefs: Set(labels.map { JSString($0) }),
      current: current, secrets: secrets)
    do {
      return try RefreshReportBuilder(rule: rule).build(input)
    } catch let error as ChangeSetError {
      throw CanonRefreshError.changeSet(error)
    } catch let error as DisclosureError {
      throw CanonRefreshError.disclosure(error)
    }
  }
}
