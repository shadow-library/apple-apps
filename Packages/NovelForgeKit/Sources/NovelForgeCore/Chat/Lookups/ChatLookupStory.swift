import Foundation
import GRDB
import ShadowStore
import ShadowText

extension ChatLookupReader {
  // tools/get-plot-threads.tool.ts:18; the reference leaves the order to the database, the vault lists by key
  func plotThreads(status: ThreadStatus?) throws(ChatLookupFailure) -> String {
    let tables = [IndexedRecord.databaseTableName]
    let report = try query { () throws(StoreError) in try ReadFaults(novel: novel, reading: tables, in: transaction) }
    guard report.blocking(tables).isEmpty else { throw ChatLookupFailure() }
    let listing = try query { () throws(StoreError) in try ThreadRecord.indexedListing(novel: novel, in: transaction) }
    let threads = listing.live.filter { thread in status.map { thread.status.state.rawValue.jsEquals($0.rawValue) } ?? true }.sorted {
      JSText.codeUnitPrecedes($0.thread, $1.thread)
    }
    guard !threads.isEmpty else { return "No plot threads found." }
    return threads.map { thread in
      let closed = thread.status.state.known == .open ? nil : thread.status.chapter
      let payoff = ChatPack.payoffLabel(window: thread.payoffWindow, milestoneKey: thread.payoffMilestone, volumeKey: thread.payoffVolume)
      let dormant = thread.dormant ? ", dormant on purpose" : ""
      let span = "ch \(thread.openedChapter.map(String.init) ?? "?")–\(closed.map(String.init) ?? "?")"
      return "\(thread.thread) (\(thread.status.state.rawValue), \(span), pays off: \(payoff)\(dormant)): \(thread.summary ?? "")"
    }.joined(separator: "\n")
  }

  // tools/get-canon-facts.tool.ts:16; a fault in the reader disclosure reads as nothing disclosed, which withholds more
  func canonFacts(keys: [String]) throws(ChatLookupFailure) -> String {
    let disclosure = try query { () throws(StoreError) in try ReaderDisclosure.load(novel, in: transaction) }
    let planned = try plannedChapters()
    var found: [(key: String, block: String)] = []
    var seen = Set<JSString>()
    for key in keys where seen.insert(JSString(key.precomposedStringWithCanonicalMapping)).inserted {
      switch try query({ () throws(StoreError) in try SecretRecord.readHead(SecretRecord.ref(novel: novel, secret: key), in: transaction) }) {
      case .absent: continue
      case .unreadable: found.append((key, "**\(key)**: \(Self.notAvailable)"))
      case .readable(let entry):
        if entry.isRemoved { continue }
        let secret = entry.record
        found.append((secret.secret, Self.canonBlock(secret, disclosedIn: disclosure.chapter(of: secret.secret).value.flatMap { $0 }, planned: planned)))
      }
    }
    let present = Set(found.map { JSString($0.key.precomposedStringWithCanonicalMapping) })
    var blocks = found.sorted { JSText.codeUnitPrecedes($0.key, $1.key) }.map(\.block)
    let missing = keys.filter { !present.contains(JSString($0.precomposedStringWithCanonicalMapping)) }
    if !missing.isEmpty { blocks.append("Not found: \(missing.joined(separator: ", "))") }
    return blocks.joined(separator: "\n\n")
  }

  private static func canonBlock(_ secret: SecretRecord, disclosedIn chapter: Int?, planned: Planned) -> String {
    let unlock = secret.unlock.flatMap { UnlockCondition(validating: OrderedJSON($0)) }.map { $0.all.map(describeUnlockTerm).joined(separator: " and ") }
    let reveal: String
    switch planned {
    case .unavailable: reveal = "Planned reveal: \(notAvailable)"
    case .chapters(let chapters): reveal = chapters[JSString(secret.secret)].map { "Planned reveal: ch \($0)" } ?? ""
    }
    let terms = secret.cluesAndTerms?.terms ?? []
    let clues = secret.cluesAndTerms?.clues ?? []
    return [
      "**\(secret.secret)**: \(secret.text)",
      chapter.map { "Reader knows since ch \($0)" } ?? "Unlocks: \(unlock ?? "no condition set")",
      reveal,
      ChatPack.present(secret.writerNote).map { "Cover note for the writer: \($0)" } ?? "",
      terms.isEmpty ? "" : "Give-away terms: \(terms.joined(separator: " | "))",
      clues.isEmpty ? "" : "Allowed clues: \(clues.joined(separator: " | "))",
    ].filter { !$0.isEmpty }.joined(separator: "\n")
  }

  fileprivate enum Planned {
    case unavailable
    case chapters([JSString: Int])
  }

  // plan-state.ts:85: the chapter whose plan currently schedules each fact's reveal
  fileprivate func plannedChapters() throws(ChatLookupFailure) -> Planned {
    let tables = [PlanWorldEntry.databaseTableName]
    let report = try query { () throws(StoreError) in try ReadFaults(novel: novel, reading: tables, in: transaction) }
    guard report.blocking(tables).isEmpty else { return .unavailable }
    let stored = try query { () throws(StoreError) in try transaction.query { database in try PlanWorldEntry.filter(Column("novel") == novel).fetchOne(database) } }
    guard let stored, let world = try? JSONDecoder().decode(NovelPlanWorld.self, from: stored.world) else { return stored == nil ? .chapters([:]) : .unavailable }
    let facts = world.facts.map { RevealFact(factKey: $0.fact, revealChapter: $0.revealChapter, unlock: $0.unlock, source: $0.source ?? .manual) }
    var chapters: [JSString: Int] = [:]
    for planned in factPlannedChapters(facts, world.planWorld) {
      if let chapter = planned.chapter { chapters[JSString(planned.factKey)] = chapter }
    }
    return .chapters(chapters)
  }
}
