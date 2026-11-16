import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowSync

private let vault = ReplicaFixture.vault
private let previous = ReplicaFixture.replica("01936f3e-3333-7333-8333-333333333333")
private let reason = RemintReason.unknownSegment(ReplicaFixture.point(9, 9))
private let claimSteps: [ReplicaLifecycleStep] = [.claimMinted, .claimMarked]
private let remintSteps: [ReplicaLifecycleStep] = [.remintMoved, .remintDeclared, .remintMarked]
private let tokenSteps: [ReplicaLifecycleStep] = [.remintTokenRecorded, .remintTokenClaimed, .remintPrepared, .remintMoved, .remintDeclared, .remintMarked]
private let secondCrashes: [ReplicaLifecycleStep?] = [nil] + ReplicaLifecycleStep.allCases

private struct ReplicaCrashHost {
  let marker: DeviceMarker
  let device: ReplicaDevice
  let minter = ReplicaMinter()

  init(_ keychain: InMemoryKeychain, _ name: String, _ device: ReplicaDevice = ReplicaFixture.phone) {
    marker = ReplicaFixture.marker(keychain, name)
    self.device = device
  }
}

private enum ReplicaCrashOperation {
  case bootstrap
  case remint
}

private enum ReplicaCrashAttempt {
  case crashed
  case finished(ReplicaBootstrap?)
}

private struct ReplicaCrashOutcome {
  let store: VaultStore
  let directory: ReplicaDirectory
  let records: [ChangeRecord]
}

private func claimed(_ url: URL, _ host: ReplicaCrashHost) async throws -> ReplicaID {
  let store = try ReplicaFixture.open(.file(url))
  _ = try await ReplicaFixture.lifecycle(store, marker: host.marker, device: host.device).bootstrap()
  try await store.write { transaction in _ = try transaction.set(EntityRef(kind: ReplicaFixture.note, key: ReplicaFixture.key("n1")), ["title": "kept"]) }
  return store.replica
}

private func fresh(_ url: URL) async throws {
  let store = try ReplicaFixture.open(.file(url))
  try await store.write { transaction in _ = try transaction.set(EntityRef(kind: ReplicaFixture.note, key: ReplicaFixture.key("n1")), ["title": "kept"]) }
}

private func attempt(_ url: URL, _ host: ReplicaCrashHost, crashAt step: ReplicaLifecycleStep?, _ operation: ReplicaCrashOperation) async throws -> ReplicaCrashAttempt {
  let store = try ReplicaFixture.open(.file(url))
  let lifecycle = ReplicaFixture.lifecycle(store, marker: host.marker, device: host.device, minter: host.minter, crashAt: step)
  do {
    switch operation {
    case .bootstrap: return .finished(try await lifecycle.bootstrap())
    case .remint:
      _ = try await lifecycle.remint(reason: reason)
      return .finished(nil)
    }
  } catch {
    guard error.code == ReplicaFixture.crash.code else { throw error }
    return .crashed
  }
}

private func crash(_ url: URL, _ host: ReplicaCrashHost, at step: ReplicaLifecycleStep, _ operation: ReplicaCrashOperation) async throws {
  guard case .crashed = try await attempt(url, host, crashAt: step, operation) else { throw ReplicaFixtureFailure("step \(step) was never reached") }
}

private func settle(_ url: URL, _ host: ReplicaCrashHost, expect expected: ReplicaBootstrap, live: Set<ReplicaID> = []) async throws -> ReplicaCrashOutcome {
  let store = try ReplicaFixture.open(.file(url))
  let lifecycle = ReplicaFixture.lifecycle(store, marker: host.marker, device: host.device, minter: host.minter)
  #expect(try await lifecycle.bootstrap() == expected)
  #expect(try await lifecycle.bootstrap() == .alreadyRunning)
  #expect(host.marker.status(vault: vault, replica: store.replica) == .matches)
  #expect(try await lifecycle.selfCheck(listing: []) == .pass)
  let directory = try await lifecycle.directory()
  let active = directory.replicas.filter { $0.state == .active }.map(\.replica)
  #expect(active.allSatisfy { live.union([store.replica]).contains($0) }, "an active replica has no writer")
  return ReplicaCrashOutcome(store: store, directory: directory, records: try await ReplicaFixture.records(store))
}

private func recover(_ url: URL, _ host: ReplicaCrashHost, crashAt second: ReplicaLifecycleStep?, expect expected: ReplicaBootstrap, live: Set<ReplicaID> = []) async throws
  -> ReplicaCrashOutcome
{
  guard case .finished(let result) = try await attempt(url, host, crashAt: second, .bootstrap) else { return try await settle(url, host, expect: expected, live: live) }
  #expect(result == expected)
  return try await settle(url, host, expect: .alreadyRunning, live: live)
}

private func stateWrites(_ outcome: ReplicaCrashOutcome, _ replica: ReplicaID, _ state: String) -> Int {
  ReplicaFixture.replicaRecords(outcome.records, for: replica).filter { $0.fields["state"] == .string(state) }.count
}

private func expectClaimed(_ outcome: ReplicaCrashOutcome) {
  #expect(outcome.directory.replicas.map(\.replica) == [outcome.store.replica])
  #expect(stateWrites(outcome, outcome.store.replica, "active") == 1)
  #expect(outcome.records.contains { $0.entity == ReplicaFixture.note })
}

private func expectMoved(_ outcome: ReplicaCrashOutcome, from old: ReplicaID, alsoActive others: Set<ReplicaID> = [], successor: ReplicaID? = nil) {
  let new = outcome.store.replica
  #expect(new != old)
  #expect(Set(outcome.directory.replicas.map(\.replica)).subtracting(others) == [old, new])
  #expect(outcome.directory.entry(for: old)?.state == .retired && outcome.directory.entry(for: old)?.successor == (successor ?? new))
  #expect(outcome.directory.entry(for: new)?.state == .active)
  #expect(stateWrites(outcome, new, "active") == 1 && stateWrites(outcome, old, "retired") == 1)
  #expect(outcome.records.contains { $0.entity == ReplicaFixture.note })
}

@Suite("ReplicaLifecycle crash recovery")
struct ReplicaLifecycleCrashTests {
  @Test("should settle a first claim interrupted after any step, and after a second crash during recovery", arguments: claimSteps)
  func shouldFinishClaim(_ step: ReplicaLifecycleStep) async throws {
    for second in secondCrashes {
      let directory = ReplicaTemporaryDirectory()
      let url = directory.database("phone")
      let host = ReplicaCrashHost(InMemoryKeychain(), "phone")
      try host.marker.claim(vault: vault, replica: previous)
      try await fresh(url)
      try await crash(url, host, at: step, .bootstrap)
      let outcome = try await recover(url, host, crashAt: second, expect: .claimed(previous: previous))
      expectClaimed(outcome)
      #expect(host.minter.all.last == outcome.store.replica)
      if second == nil { #expect(host.minter.all.count == (step == .claimMinted ? 2 : 1)) }
    }
  }

  @Test("should give each device its own id when a database is copied after a first claim stopped at any step", arguments: claimSteps)
  func shouldSplitInterruptedClaim(_ step: ReplicaLifecycleStep) async throws {
    let directory = ReplicaTemporaryDirectory()
    let keychain = InMemoryKeychain()
    let phone = ReplicaCrashHost(keychain, "phone")
    let mac = ReplicaCrashHost(keychain, "mac", ReplicaFixture.mac)
    try await fresh(directory.database("phone"))
    try await crash(directory.database("phone"), phone, at: step, .bootstrap)
    try ReplicaFixture.copyDatabase(from: directory.database("phone"), to: directory.database("mac"))
    let onMac = try await settle(directory.database("mac"), mac, expect: .claimed(previous: nil))
    let onPhone = try await settle(directory.database("phone"), phone, expect: .claimed(previous: nil))
    #expect(onMac.store.replica != onPhone.store.replica)
    #expect(!phone.minter.all.contains(onMac.store.replica) && !mac.minter.all.contains(onPhone.store.replica))
    expectClaimed(onMac)
    expectClaimed(onPhone)
  }

  @Test("should leave the replica running when a re-mint stops before its store transaction")
  func shouldKeepReplicaWhenRemintStopsEarly() async throws {
    let directory = ReplicaTemporaryDirectory()
    let url = directory.database("phone")
    let host = ReplicaCrashHost(InMemoryKeychain(), "phone")
    let old = try await claimed(url, host)
    try await crash(url, host, at: .remintPrepared, .remint)
    let outcome = try await settle(url, host, expect: .alreadyRunning)
    #expect(outcome.store.replica == old && host.minter.all.count == 1)
    #expect(outcome.directory.replicas.map(\.replica) == [old] && !outcome.directory.isRetired(old))
  }

  @Test("should finish a re-mint interrupted after any later step on its own device, also after a second crash", arguments: remintSteps)
  func shouldFinishRemint(_ step: ReplicaLifecycleStep) async throws {
    for second in secondCrashes {
      let directory = ReplicaTemporaryDirectory()
      let url = directory.database("phone")
      let host = ReplicaCrashHost(InMemoryKeychain(), "phone")
      let old = try await claimed(url, host)
      try await crash(url, host, at: step, .remint)
      let new = try #require(host.minter.all.first)
      let outcome = try await recover(url, host, crashAt: second, expect: .reminted(from: old, reason: reason))
      #expect(host.minter.all == [new] && outcome.store.replica == new)
      expectMoved(outcome, from: old)
    }
  }

  @Test("should refuse a second re-mint while one is unfinished and let bootstrap finish it")
  func shouldRefuseRemintDuringMove() async throws {
    let directory = ReplicaTemporaryDirectory()
    let url = directory.database("phone")
    let host = ReplicaCrashHost(InMemoryKeychain(), "phone")
    let old = try await claimed(url, host)
    try await crash(url, host, at: .remintDeclared, .remint)
    let store = try ReplicaFixture.open(.file(url))
    let lifecycle = ReplicaFixture.lifecycle(store, marker: host.marker, minter: host.minter)
    let error = await #expect(throws: ReplicaLifecycleError.self) { try await lifecycle.remint(reason: .retired) }
    #expect(error?.code == "replica-lifecycle.bootstrap-required")
    #expect(host.minter.all.count == 1)
    expectMoved(try await settle(url, host, expect: .reminted(from: old, reason: reason)), from: old)
  }

  @Test("should finish the re-mint of a copied database interrupted after any step with its original reason, also after a second crash", arguments: tokenSteps)
  func shouldFinishCopyRemint(_ step: ReplicaLifecycleStep) async throws {
    for second in secondCrashes {
      let directory = ReplicaTemporaryDirectory()
      let keychain = InMemoryKeychain()
      let phone = ReplicaCrashHost(keychain, "phone")
      let old = try await claimed(directory.database("phone"), phone)
      try ReplicaFixture.copyDatabase(from: directory.database("phone"), to: directory.database("mac"))
      let url = directory.database("mac")
      let mac = ReplicaCrashHost(keychain, "mac", ReplicaFixture.mac)
      try await crash(url, mac, at: step, .bootstrap)
      let outcome = try await recover(url, mac, crashAt: second, expect: .reminted(from: old, reason: .markerMissing), live: [old])
      #expect(mac.minter.all.last == outcome.store.replica)
      expectMoved(outcome, from: old)
    }
  }

  @Test("should give a third device its own id when a copy being re-minted is copied on at any step", arguments: tokenSteps)
  func shouldSplitCopyOfCopy(_ step: ReplicaLifecycleStep) async throws {
    let directory = ReplicaTemporaryDirectory()
    let keychain = InMemoryKeychain()
    let phone = ReplicaCrashHost(keychain, "phone")
    let mac = ReplicaCrashHost(keychain, "mac", ReplicaFixture.mac)
    let tablet = ReplicaCrashHost(keychain, "tablet", ReplicaDevice(name: "Tablet", platform: "iPadOS", appVersion: "1.0"))
    let old = try await claimed(directory.database("phone"), phone)
    try ReplicaFixture.copyDatabase(from: directory.database("phone"), to: directory.database("mac"))
    try await crash(directory.database("mac"), mac, at: step, .bootstrap)
    try ReplicaFixture.copyDatabase(from: directory.database("mac"), to: directory.database("tablet"))
    let partial = Set(mac.minter.all)

    let onTablet = try await settle(directory.database("tablet"), tablet, expect: .reminted(from: old, reason: .markerMissing), live: partial.union([old]))
    let onMac = try await settle(directory.database("mac"), mac, expect: .reminted(from: old, reason: .markerMissing), live: [old])
    let onPhone = try await settle(directory.database("phone"), phone, expect: .alreadyRunning)
    #expect(Set([old, onMac.store.replica, onTablet.store.replica]).count == 3)
    #expect(onPhone.store.replica == old)
    expectMoved(onMac, from: old)
    // Copied after the Mac declared its successor: a successor is first-writer-wins, so the tablet's later re-mint cannot re-point `old`.
    let declared = [ReplicaLifecycleStep.remintDeclared, .remintMarked].contains(step)
    expectMoved(onTablet, from: old, alsoActive: [onMac.store.replica], successor: declared ? onMac.store.replica : nil)
    #expect(onTablet.directory.replicas.allSatisfy { [old, onMac.store.replica, onTablet.store.replica].contains($0.replica) })
  }

  @Test("should re-mint again on another device when a database leaves mid-move, and finish the move on the original device")
  func shouldRemintCopyCarryingUnfinishedMove() async throws {
    let directory = ReplicaTemporaryDirectory()
    let keychain = InMemoryKeychain()
    let phone = ReplicaCrashHost(keychain, "phone")
    let mac = ReplicaCrashHost(keychain, "mac", ReplicaFixture.mac)
    let old = try await claimed(directory.database("phone"), phone)
    try await crash(directory.database("phone"), phone, at: .remintMoved, .remint)
    try ReplicaFixture.copyDatabase(from: directory.database("phone"), to: directory.database("mac"))
    let moved = try #require(phone.minter.all.first)

    let copy = try await settle(directory.database("mac"), mac, expect: .reminted(from: old, reason: .markerMissing))
    #expect(mac.minter.all == [copy.store.replica] && copy.store.replica != moved)
    expectMoved(copy, from: old)
    #expect(copy.directory.entry(for: moved) == nil)

    let original = try await settle(directory.database("phone"), phone, expect: .reminted(from: old, reason: reason))
    #expect(phone.minter.all == [moved] && original.store.replica == moved)
    expectMoved(original, from: old)
  }
}
