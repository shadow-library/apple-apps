import Foundation
import ShadowTestSupport

@testable import ShadowSyncCloudKit

/// Delegates to a fake zone but, once armed for an operation, holds that operation's next answer (or failure) after the zone computed it,
/// until released.
final class GatedZone: CloudKitZoneClient {
  private actor Gate {
    private var armed: Set<FakeCloudKitZone.Operation> = []
    private var held: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?

    func arm(_ operation: FakeCloudKitZone.Operation) {
      armed.insert(operation)
    }

    func pass(_ operation: FakeCloudKitZone.Operation) async {
      guard armed.remove(operation) != nil else { return }
      arrival?.resume()
      arrival = nil
      await withCheckedContinuation { held = $0 }
    }

    func waitForArrival() async {
      guard held == nil else { return }
      await withCheckedContinuation { arrival = $0 }
    }

    func release() {
      held?.resume()
      held = nil
    }
  }

  let fake: FakeCloudKitZone
  private let gate = Gate()

  init(_ fake: FakeCloudKitZone) {
    self.fake = fake
  }

  var configuration: CloudKitConfiguration { fake.configuration }

  func arm(_ operation: FakeCloudKitZone.Operation = .fetchChanges) async { await gate.arm(operation) }
  func waitUntilHeld() async { await gate.waitForArrival() }
  func release() async { await gate.release() }

  func ensureZone() async throws(CloudKitZoneError) { try await fake.ensureZone() }

  func fetchChanges(since token: CloudKitChangeToken?) async throws(CloudKitZoneError) -> CloudKitChangeBatch {
    try await held(.fetchChanges) { () async throws(CloudKitZoneError) in try await fake.fetchChanges(since: token) }
  }

  func fetch(_ names: [CloudKitRecordName]) async throws(CloudKitZoneError) -> [CloudKitRecordName: Result<CloudKitObjectRecord, CloudKitZoneError>] {
    try await held(.fetch) { () async throws(CloudKitZoneError) in try await fake.fetch(names) }
  }

  func save(_ records: [CloudKitObjectRecord], mode: CloudKitSaveMode) async throws(CloudKitZoneError) -> [CloudKitRecordName: Result<CloudKitRecordSummary, CloudKitZoneError>] {
    try await fake.save(records, mode: mode)
  }

  func delete(_ names: [CloudKitRecordName]) async throws(CloudKitZoneError) -> [CloudKitRecordName: Result<Void, CloudKitZoneError>] {
    try await fake.delete(names)
  }

  func accountStatus() async throws(CloudKitZoneError) -> CloudKitAccountStatus { try await fake.accountStatus() }

  func currentUserRecordName() async throws(CloudKitZoneError) -> String { try await fake.currentUserRecordName() }

  private func held<T>(_ operation: FakeCloudKitZone.Operation, _ body: () async throws(CloudKitZoneError) -> T) async throws(CloudKitZoneError) -> T {
    let result: Result<T, CloudKitZoneError>
    do throws(CloudKitZoneError) {
      result = .success(try await body())
    } catch {
      result = .failure(error)
    }
    await gate.pass(operation)
    return try result.get()
  }

  func events() -> AsyncStream<CloudKitZoneEvent> { fake.events() }
}
