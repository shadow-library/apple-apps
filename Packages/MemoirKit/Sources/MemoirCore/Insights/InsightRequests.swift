import Foundation
import ShadowAI
import ShadowCore
import ShadowJobs
import ShadowStore

public enum InsightRequestStatus: Sendable, Hashable {
  case queued
  case running
  case succeeded
  case cancelled
  case failed(code: String)
}

/// What the calls an insight's attempts made cost so far; a call whose figure has not arrived, or whose ledger entry has not synced, is counted apart.
public struct InsightCost: Sendable, Hashable {
  public let cost: Cost
  public let pendingCalls: Int

  public init(cost: Cost, pendingCalls: Int) {
    self.cost = cost
    self.pendingCalls = pendingCalls
  }

  public static let zero = InsightCost(cost: .zero, pendingCalls: 0)
}

/// One question or night as the owner asked it: its latest run, with its status at the read's instant.
public struct InsightRequest: Sendable, Hashable, Identifiable {
  public let job: EntityRef
  public let kind: InsightJobKind
  public let target: InsightJobTarget
  public let question: String
  public let run: Int
  public let status: InsightRequestStatus
  /// When its first attempt started, as the attempt's lease clock read it.
  public let startedMillis: Int64?
  public let cost: InsightCost

  public var id: EntityRef { job }

  /// The id its result is stored under, in whichever store holds it.
  public var resultID: UUID { InsightRecord<GeneralMetric>.id(forJob: job) }
}

/// The latest run of every insight job in the vault, newest first, as of `now`. Liveness is read against `now`, so a running request turns queued when
/// its lease lapses with no write; observing the store does not notice that, so a screen reads again at `changesAt`.
public struct InsightRequestListing: Sendable, Hashable {
  public let requests: [InsightRequest]
  /// The earliest live lease expiry after `now`; nil when nothing runs.
  public let changesAt: Date?
}

public enum InsightRequests {
  public static func listing(in store: VaultStore, at now: LeaseInstant) async throws(InsightError) -> InsightRequestListing {
    do {
      return try await store.read { transaction in try listing(in: transaction, at: now) }
    } catch {
      throw .converting(error)
    }
  }

  public static func listing(in transaction: ReadTransaction, at now: LeaseInstant) throws(StoreError) -> InsightRequestListing {
    var latest: [String: (job: InsightJob, snapshot: JobSnapshot)] = [:]
    for (ref, _) in try transaction.states(ofKind: JobSchema.jobKind) {
      let loaded: JobSnapshot?
      do {
        loaded = try JobSnapshot.load(ref, in: transaction)
      } catch {
        continue
      }
      guard let snapshot = loaded, let job = try? InsightJob(snapshot.job) else { continue }
      let slot = "\(job.kind.rawValue)|\(job.target.text)"
      if let held = latest[slot], held.snapshot.job.request.key.run >= snapshot.job.request.key.run { continue }
      latest[slot] = (job, snapshot)
    }
    let ledger = Dictionary(try Ledger.entries(in: transaction).map { ($0.id, $0) }) { first, _ in first }
    let requests = latest.values.map { job, snapshot in
      InsightRequest(
        job: job.ref, kind: job.kind, target: job.target, question: job.question, run: snapshot.job.request.key.run, status: status(snapshot, at: now),
        startedMillis: snapshot.attempts.first?.start.started.millis, cost: cost(of: snapshot, ledger: ledger))
    }
    let expiries = latest.values.flatMap { $0.snapshot.attempts.filter { $0.isLive(at: now) }.compactMap(\.lease?.expires) }
    return InsightRequestListing(
      requests: requests.sorted { ($0.startedMillis ?? .min, $0.job.key.rawValue) > ($1.startedMillis ?? .min, $1.job.key.rawValue) },
      changesAt: expiries.min().map { Date(timeIntervalSince1970: Double($0) / 1000) })
  }

  static func status(_ snapshot: JobSnapshot, at now: LeaseInstant) -> InsightRequestStatus {
    switch JobStatus(snapshot, at: now) {
    case .queued: .queued
    case .running: .running
    case .succeeded: .succeeded
    case .cancelled: .cancelled
    case .failed(_, let failure): .failed(code: failure?.code ?? "jobs.step_failed")
    }
  }

  static func cost(of snapshot: JobSnapshot, ledger: [UUID: ModelCallEntry]) -> InsightCost {
    var total = Cost.zero
    var pending = 0
    for call in Set(snapshot.attempts.flatMap(\.calls)) {
      guard let entry = ledger[call], entry.costSource != .pending else {
        pending += 1
        continue
      }
      total = total + Cost(nanoUSD: max(entry.cost?.nanoUSD ?? 0, 0))
    }
    return InsightCost(cost: total, pendingCalls: pending)
  }
}
