import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

@testable import ShadowSync
@testable import ShadowSyncRuntime

@Suite("SyncMover", TestTimeLimit.standard)
struct SyncMoverTests {
  @Test
  func shouldWriteOneVerifiedBaseOfTheWholeMergedStateIntoTheNewLocation() async throws {
    let world = try await MoveWorld.synced()
    let engine = try await world.mover.started(on: world.old)
    let before = engine.replica
    guard case .moved(let replica, let location) = try await world.mover(engine: engine).run() else { throw RuntimeFixtureFailure("the move did not finish") }
    #expect(replica != before)
    #expect(location == world.newLocation)
    #expect(try world.mover.locations.load() == .attached(world.newLocation))
    #expect(try world.mover.journal.load() == nil)
    let keys = Set(try await world.new.listAll(prefix: "").map(\.key))
    let parts = keys.filter { if case .basePart(replica, upTo: 0, _, _, _) = VaultPath.classify($0) { true } else { false } }
    #expect(!parts.isEmpty)
    #expect(keys == parts.union([VaultPath.hint]))
    let base = try await MoveCheck.base(in: world.new, of: replica, ring: world.mover.ring)
    #expect(MoveCheck.noteKeys(base) == ["mover-early", "follower-early", "third-early"])
  }

  @Test
  func shouldRefuseATamperedCopyAndReplaceItWhenRunAgain() async throws {
    let world = try await MoveWorld.synced(new: TamperingProvider(count: 1))
    let engine = try await world.mover.started(on: world.old)
    await #expect {
      _ = try await world.mover(engine: engine).run()
    } throws: { error in
      guard case SyncMoveError.verificationFailed(let key) = error, case .basePart = VaultPath.classify(key) else { return false }
      return true
    }
    #expect(try await world.snapshot(of: world.old)[VaultPath.moveNotice] == nil)
    #expect(try world.mover.journal.load() != nil)
    guard case .moved(let replica, _) = try await world.mover(engine: engine).run() else { throw RuntimeFixtureFailure("the move did not finish") }
    #expect(MoveCheck.noteKeys(try await MoveCheck.base(in: world.new, of: replica, ring: world.mover.ring)).count == 3)
  }

  @Test
  func shouldLeaveTheOldLocationUnchangedExceptForTheNotice() async throws {
    let world = try await MoveWorld.synced()
    let engine = try await world.mover.started(on: world.old)
    let before = try await world.snapshot(of: world.old)
    _ = try await world.mover(engine: engine).run()
    var after = try await world.snapshot(of: world.old)
    let removed = after.removeValue(forKey: VaultPath.moveNotice)
    let notice = try #require(removed)
    #expect(after == before)
    let opened = try VaultMoveNoticeCodec.open(notice, vault: MoveWorld.vault) { world.mover.ring.key($0) }
    #expect(opened.targetLocation == world.newLocation)
  }

  @Test
  func shouldLetTheOtherReplicasFollowAsNewReplicasAndConverge() async throws {
    let world = try await MoveWorld.synced()
    _ = try await world.mover(engine: try await world.mover.started(on: world.old)).run()
    let moverNew = try await world.mover.started(on: world.new)
    let followerOld = try await world.follower.started(on: world.old)
    let thirdOld = try await world.third.started(on: world.old)
    let (followerBefore, thirdBefore) = (followerOld.replica, thirdOld.replica)
    let followerNew = try await world.follow(world.follower, from: followerOld)
    let thirdNew = try await world.follow(world.third, from: thirdOld)
    #expect(followerNew.replica != followerBefore)
    #expect(thirdNew.replica != thirdBefore)
    #expect(try world.follower.locations.load() == .attached(world.newLocation))
    for device in world.devices { try await device.write("\(device.name)-late", "after the move") }
    try await world.settle([moverNew, followerNew, thirdNew])
    let titles = try await world.mover.titles()
    #expect(titles.count == 6)
    #expect(try await world.follower.titles() == titles)
    #expect(try await world.third.titles() == titles)
  }

  @Test
  func shouldStopUploadingToTheOldLocationOnceTheNoticeIsSeenAlsoAfterARestart() async throws {
    let world = try await MoveWorld.synced()
    _ = try await world.mover(engine: try await world.mover.started(on: world.old)).run()
    let followerOld = try await world.follower.started(on: world.old)
    let notice = try #require(try await followerOld.download().moved)
    try await world.follower.write("follower-unsent", "kept for the new location")
    let before = try await world.snapshot(of: world.old)
    await MoveCheck.expectVaultMoved { _ = try await followerOld.upload() }
    let restarted = try await world.follower.started(on: world.old)
    #expect(try await restarted.recordedMove() == notice)
    await MoveCheck.expectVaultMoved { _ = try await restarted.compact(force: true) }
    await MoveCheck.expectVaultMoved { _ = try await restarted.sync() }
    #expect(try await world.snapshot(of: world.old) == before)
  }

  @Test
  func shouldCarryAFollowersUnsentChangesIntoTheNewLocation() async throws {
    let world = try await MoveWorld.synced()
    try await world.follower.write("follower-unsent", "written before the notice")
    _ = try await world.mover(engine: try await world.mover.started(on: world.old)).run()
    let moverNew = try await world.mover.started(on: world.new)
    let followerNew = try await world.follow(world.follower, from: try await world.follower.started(on: world.old))
    try await world.settle([moverNew, followerNew])
    #expect(try await world.mover.titles()["follower-unsent"] == "written before the notice")
  }

  @Test
  func shouldCarryAFollowersOwnChangesUploadedToTheOldLocationAfterTheSnapshot() async throws {
    let world = try await MoveWorld.synced()
    _ = try await world.mover(engine: try await world.mover.started(on: world.old)).run()
    let followerOld = try await world.follower.started(on: world.old)
    try await world.follower.write("follower-after", "uploaded to the old location")
    guard case .uploaded = try await followerOld.upload() else { throw RuntimeFixtureFailure("the late change was not uploaded") }
    let moverNew = try await world.mover.started(on: world.new)
    let followerNew = try await world.follow(world.follower, from: followerOld)
    try await world.settle([moverNew, followerNew])
    #expect(try await world.mover.titles()["follower-after"] == "uploaded to the old location")
  }

  @Test
  func shouldCarryAnotherDevicesLateChangeThatAFollowerReadBeforeFollowing() async throws {
    let world = try await MoveWorld.synced()
    _ = try await world.mover(engine: try await world.mover.started(on: world.old)).run()
    try await world.third.write("third-after", "uploaded after the snapshot")
    _ = try await world.third.started(on: world.old).upload()
    let moverNew = try await world.mover.started(on: world.new)
    let followerNew = try await world.follow(world.follower, from: try await world.follower.started(on: world.old))
    try await world.settle([moverNew, followerNew])
    #expect(try await world.mover.titles()["third-after"] == "uploaded after the snapshot")
  }

  /// The loss the user accepted: a change uploaded to the old location after the snapshot, read by no follower before it followed, is missing at the new
  /// location until its writer follows. The old location keeps it.
  @Test
  func shouldMissALateChangeOfAnotherDeviceUntilThatDeviceFollows() async throws {
    let world = try await MoveWorld.synced()
    _ = try await world.mover(engine: try await world.mover.started(on: world.old)).run()
    let moverNew = try await world.mover.started(on: world.new)
    let followerNew = try await world.follow(world.follower, from: try await world.follower.started(on: world.old))
    let thirdOld = try await world.third.started(on: world.old)
    try await world.third.write("third-after", "uploaded after the snapshot")
    guard case .uploaded = try await thirdOld.upload() else { throw RuntimeFixtureFailure("the late change was not uploaded") }
    try await world.settle([moverNew, followerNew])
    #expect(try await world.mover.titles()["third-after"] == nil)
    #expect(try await world.follower.titles()["third-after"] == nil)
    #expect(try await world.mover.titles() == world.follower.titles())
    #expect(!(try await world.old.listAll(prefix: VaultPath.segmentPrefix(thirdOld.replica))).isEmpty)
    let thirdNew = try await world.follow(world.third, from: thirdOld)
    try await world.settle([moverNew, followerNew, thirdNew])
    #expect(try await world.mover.titles()["third-after"] == "uploaded after the snapshot")
  }

  @Test(arguments: SyncMoveStep.allCases)
  func shouldFinishAMoveInterruptedAtAnyStep(_ step: SyncMoveStep) async throws {
    let world = try await MoveWorld.synced()
    let engine = try await world.mover.started(on: world.old)
    await #expect(throws: SyncMoveError.self) { _ = try await world.mover(engine: engine, crashAt: step).run() }
    let restarted = try await world.mover.started(on: world.old)
    guard case .moved = try await world.mover(engine: restarted).run() else { throw RuntimeFixtureFailure("the resumed move did not finish") }
    #expect(try world.mover.journal.load() == nil)
    let moverNew = try await world.mover.started(on: world.new)
    let followerNew = try await world.follow(world.follower, from: try await world.follower.started(on: world.old))
    try await world.settle([moverNew, followerNew])
    let titles = try await world.mover.titles()
    #expect(titles.count == 3)
    #expect(try await world.follower.titles() == titles)
  }

  @Test
  func shouldResumeWithTheStateAsItStandsWhenItChangedAfterTheInterruption() async throws {
    let world = try await MoveWorld.synced()
    await #expect(throws: SyncMoveError.self) { _ = try await world.mover(engine: try await world.mover.started(on: world.old), crashAt: .partsPut).run() }
    try await world.mover.write("mover-during", "written while the move was interrupted")
    guard case .moved = try await world.mover(engine: try await world.mover.started(on: world.old)).run() else { throw RuntimeFixtureFailure("the move did not finish") }
    let moverNew = try await world.mover.started(on: world.new)
    let followerNew = try await world.follow(world.follower, from: try await world.follower.started(on: world.old))
    try await world.settle([moverNew, followerNew])
    #expect(try await world.follower.titles()["mover-during"] == "written while the move was interrupted")
    #expect(try await world.follower.titles() == world.mover.titles())
  }

  @Test
  func shouldAbandonAMoveBeforeItsNoticeAndSyncOnAtTheOldLocation() async throws {
    let world = try await MoveWorld.synced()
    let engine = try await world.mover.started(on: world.old)
    let before = engine.replica
    await #expect(throws: SyncMoveError.self) { _ = try await world.mover(engine: engine, crashAt: .recorded).run() }
    try await world.mover(engine: engine).abandon()
    #expect(try world.mover.journal.load() == nil)
    #expect(try await world.snapshot(of: world.old)[VaultPath.moveNotice] == nil)
    let restarted = try await world.mover.started(on: world.old)
    #expect(restarted.replica != before)
    try await world.mover.write("mover-stayed", "still at the old location")
    let followerOld = try await world.follower.started(on: world.old)
    try await world.settle([restarted, followerOld])
    #expect(try await world.follower.titles()["mover-stayed"] == "still at the old location")
  }

  @Test
  func shouldRefuseToAbandonAMoveWhoseNoticeIsWritten() async throws {
    let world = try await MoveWorld.synced()
    let engine = try await world.mover.started(on: world.old)
    await #expect(throws: SyncMoveError.self) { _ = try await world.mover(engine: engine, crashAt: .noticePut).run() }
    await #expect {
      try await world.mover(engine: engine).abandon()
    } throws: { error in
      guard case SyncMoveError.alreadyMoved = error else { return false }
      return true
    }
    #expect(try world.mover.journal.load() != nil)
  }

  @Test
  func shouldLetTheFirstOfTwoConcurrentMovesWinAndTheOtherFollowIt() async throws {
    let world = try await MoveWorld.synced()
    let other = InMemoryStorageProvider()
    let otherLocation = SyncLocation(settings: RuntimeFixture.localFolder("other"), vault: MoveWorld.vault, account: nil)
    let followerOld = try await world.follower.started(on: world.old)
    await #expect(throws: SyncMoveError.self) {
      _ = try await world.mover(world.follower, engine: followerOld, target: otherLocation, targetProvider: other, crashAt: .recorded).run()
    }
    guard case .moved(let winner, _) = try await world.mover(engine: try await world.mover.started(on: world.old)).run() else {
      throw RuntimeFixtureFailure("the first move did not finish")
    }
    let outcome = try await world.mover(world.follower, engine: followerOld, target: otherLocation, targetProvider: other).run()
    guard case .superseded(let notice) = outcome else { throw RuntimeFixtureFailure("the second move was not superseded") }
    #expect(notice.to == winner)
    #expect(try world.follower.journal.load() == nil)
    await #expect {
      _ = try await world.follower(world.follower, engine: followerOld, target: otherLocation, targetProvider: other).run(notice)
    } throws: { error in
      guard case SyncMoveError.targetMissingVault = error else { return false }
      return true
    }
    guard case .moved = try await world.follower(world.follower, engine: followerOld).run(notice) else { throw RuntimeFixtureFailure("the loser did not follow") }
    let moverNew = try await world.mover.started(on: world.new)
    let followerNew = try await world.follower.started(on: world.new)
    try await world.follower.write("follower-late", "after losing the race")
    try await world.settle([moverNew, followerNew])
    #expect(try await world.mover.titles() == world.follower.titles())
    #expect(try await world.mover.titles().count == 4)
    #expect(!(try await other.listAll(prefix: "")).isEmpty)
  }

  @Test
  func shouldRefuseANewLocationThatAlreadyHoldsAVault() async throws {
    let target = InMemoryStorageProvider()
    _ = try await target.put(VaultPath.hint, data: VaultHint(vault: RuntimeFixture.vault("another-vault")).encoded(), condition: .ifAbsent)
    let world = try await MoveWorld.synced(new: target)
    let engine = try await world.mover.started(on: world.old)
    let before = engine.replica
    await #expect {
      _ = try await world.mover(engine: engine).run()
    } throws: { error in
      guard case SyncMoveError.targetHoldsVault = error else { return false }
      return true
    }
    #expect(engine.replica == before)
    #expect(try world.mover.journal.load() == nil)
    #expect(try await target.listAll(prefix: "").map(\.key) == [VaultPath.hint])
  }

  @Test
  func shouldRefuseAMoveWhenABlobDoesNotFitTheNewLocation() async throws {
    let target = InMemoryStorageProvider(maxObjectBytes: 64 * 1024)
    let world = try await MoveWorld.synced(new: target)
    try await MoveCheck.putBlob(Data(repeating: 7, count: 100 * 1024), in: world.old, ring: world.mover.ring)
    let engine = try await world.mover.started(on: world.old)
    await #expect {
      _ = try await world.mover(engine: engine).run()
    } throws: { error in
      guard case SyncMoveError.blobTooLarge(_, let size, let limit) = error else { return false }
      return size > limit && limit == 64 * 1024
    }
    #expect(try await target.listAll(prefix: "").isEmpty)
    #expect(try world.mover.journal.load() == nil)
  }

  @Test
  func shouldRefuseAMoveWhenTheNewLocationMayNotHoldTheStoresBlobs() async throws {
    let target = InMemoryStorageProvider(classPolicy: .iCloud)
    let world = try await MoveWorld.synced(new: target)
    try await MoveCheck.putBlob(Data(repeating: 5, count: 1024), in: world.old, ring: world.mover.ring)
    let engine = try await world.mover.started(on: world.old)
    await #expect {
      _ = try await world.mover(engine: engine).run()
    } throws: { error in
      guard case SyncMoveError.sync(.blob(.classRefused(.health))) = error else { return false }
      return true
    }
    #expect(try await target.listAll(prefix: "").isEmpty)
    #expect(try world.mover.journal.load() == nil)
  }

  @Test
  func shouldSplitTheBaseToTheNewLocationsLimitAndCopyItsBlobs() async throws {
    let limit = 4 * 1024
    let target = InMemoryStorageProvider(maxObjectBytes: limit)
    let world = try await MoveWorld.synced(new: target)
    for index in 0..<60 { try await world.mover.write("bulk-\(index)", (0..<4).map { _ in UUID().uuidString }.joined()) }
    let blob = try await MoveCheck.putBlob(Data(repeating: 3, count: 2 * 1024), in: world.old, ring: world.mover.ring)
    guard case .moved(let replica, _) = try await world.mover(engine: try await world.mover.started(on: world.old)).run() else {
      throw RuntimeFixtureFailure("the move did not finish")
    }
    let parts = try await target.listAll(prefix: VaultPath.basePrefix(replica))
    #expect(parts.count > 1)
    #expect(parts.allSatisfy { $0.size <= limit })
    #expect(try await target.get(blob) == world.old.get(blob))
    let followerNew = try await world.follow(world.follower, from: try await world.follower.started(on: world.old))
    _ = try await followerNew.sync()
    #expect(try await world.follower.titles().count == 63)
  }

  @Test
  func shouldIgnoreAForgedNoticeAndRefuseToMovePastIt() async throws {
    let world = try await MoveWorld.synced()
    let elsewhere = RuntimeFixture.vault("elsewhere")
    let key = try #require(world.mover.ring.writingKey())
    let notice = VaultMoveNotice(
      from: ReplicaID(UUID.v7()), to: ReplicaID(UUID.v7()), base: try #require(BaseReference(upTo: 0, tag: ContentTag.make(for: Data(), key: key), parts: 1)),
      frontier: [:], target: VaultMoveNotice.target(of: world.newLocation), movedMillis: 0)
    for forged in [Data("not a notice".utf8), try VaultMoveNoticeCodec.seal(notice, vault: elsewhere, with: key)] {
      _ = try await world.old.put(VaultPath.moveNotice, data: forged, condition: .overwrite)
      let followerOld = try await world.follower.started(on: world.old)
      #expect(try await followerOld.download().moved == nil)
      try await world.follower.write("follower-\(forged.count)", "still syncing here")
      guard case .uploaded = try await followerOld.upload() else { throw RuntimeFixtureFailure("a forged notice stopped uploads") }
      await #expect {
        _ = try await world.mover(engine: try await world.mover.started(on: world.old)).run()
      } throws: { error in
        guard case SyncMoveError.noticeUnreadable = error else { return false }
        return true
      }
    }
  }

  @Test
  func shouldIgnoreANoticeReplayedIntoTheNewLocation() async throws {
    let world = try await MoveWorld.synced()
    _ = try await world.mover(engine: try await world.mover.started(on: world.old)).run()
    let moverNew = try await world.mover.started(on: world.new)
    let followerNew = try await world.follow(world.follower, from: try await world.follower.started(on: world.old))
    try await world.settle([moverNew, followerNew])
    _ = try await world.new.put(VaultPath.moveNotice, data: try await world.old.get(VaultPath.moveNotice), condition: .ifAbsent)
    #expect(try await followerNew.download().moved == nil)
    try await world.follower.write("follower-late", "after the replay")
    guard case .uploaded = try await followerNew.upload() else { throw RuntimeFixtureFailure("a replayed notice stopped uploads") }
  }

  @Test
  func shouldRefuseToMoveAVaultAnotherDeviceAlreadyMoved() async throws {
    let world = try await MoveWorld.synced()
    _ = try await world.mover(engine: try await world.mover.started(on: world.old)).run()
    let otherLocation = SyncLocation(settings: RuntimeFixture.localFolder("other"), vault: MoveWorld.vault, account: nil)
    let other = InMemoryStorageProvider()
    await #expect {
      _ = try await world.mover(world.follower, engine: try await world.follower.started(on: world.old), target: otherLocation, targetProvider: other).run()
    } throws: { error in
      guard case SyncMoveError.alreadyMoved = error else { return false }
      return true
    }
    #expect(other.isUntouched)
  }

  @Test
  func shouldRefuseToFollowIntoALocationThatDoesNotHoldTheVault() async throws {
    let world = try await MoveWorld.synced()
    _ = try await world.mover(engine: try await world.mover.started(on: world.old)).run()
    let followerOld = try await world.follower.started(on: world.old)
    let notice = try #require(try await followerOld.download().moved)
    let empty = InMemoryStorageProvider()
    await #expect {
      _ = try await world.follower(world.follower, engine: followerOld, targetProvider: empty).run(notice)
    } throws: { error in
      guard case SyncMoveError.targetMissingVault = error else { return false }
      return true
    }
    #expect(try world.follower.journal.load() == nil)
    #expect(try world.follower.locations.load() == .attached(world.oldLocation))
  }

  @Test
  func shouldKeepRelayedChangesStampedAsTheyWereThroughAClockCorrection() async throws {
    let target = ServerTimeStorageProvider(wrapping: InMemoryStorageProvider()) { Date() }
    let world = try await MoveWorld.synced(new: target)
    _ = try await world.mover(engine: try await world.mover.started(on: world.old)).run()
    try await world.third.write("shared", "older, uploaded after the snapshot")
    _ = try await world.third.started(on: world.old).upload()
    try await Task.sleep(for: .milliseconds(20))
    let moverNew = try await world.mover.started(on: world.new)
    try await world.mover.write("shared", "newer, written at the new location")
    _ = try await moverNew.sync()
    world.follower.setOffset(.seconds(600))
    try await world.follower.write("follower-ahead", "stamped by a clock ten minutes fast")
    let followerOld = try await world.follower.started(on: world.old)
    let followerNew = try await world.follow(world.follower, from: followerOld)
    let before = followerNew.replica
    try await world.settle([followerNew, moverNew])
    #expect(followerNew.replica != before)
    #expect(try await world.mover.titles()["shared"] == "newer, written at the new location")
    #expect(try await world.follower.titles()["shared"] == "newer, written at the new location")
    #expect(try await world.mover.titles()["follower-ahead"] == "stamped by a clock ten minutes fast")
  }

  @Test
  func shouldUploadTheMoversUnsentChangesAtTheOldLocationBeforeItMoves() async throws {
    let world = try await MoveWorld.synced()
    try await world.mover.write("mover-unsent", "not yet uploaded")
    let engine = try await world.mover.started(on: world.old)
    let replica = engine.replica
    let before = try await world.old.listAll(prefix: VaultPath.segmentPrefix(replica)).count
    _ = try await world.mover(engine: engine).run()
    #expect(try await world.old.listAll(prefix: VaultPath.segmentPrefix(replica)).count == before + 1)
    let followerNew = try await world.follow(world.follower, from: try await world.follower.started(on: world.old))
    _ = try await followerNew.sync()
    #expect(try await world.follower.titles()["mover-unsent"] == "not yet uploaded")
  }

  @Test
  func shouldRefuseToSealAChangeStampedBeyondTheReaderLimit() async throws {
    let world = try await MoveWorld.synced()
    world.mover.setOffset(.seconds(2 * 24 * 60 * 60))
    try await world.mover.write("mover-ahead", "stamped two days ahead")
    world.mover.trustedClock.record(serverDate: Date())
    await #expect {
      _ = try await world.mover(engine: try await world.mover.started(on: world.old)).run()
    } throws: { error in
      guard case SyncMoveError.sync(.clockAhead) = error else { return false }
      return true
    }
    #expect(try await world.snapshot(of: world.old)[VaultPath.moveNotice] == nil)
    #expect(try await world.new.listAll(prefix: "").isEmpty)
  }

  @Test
  func shouldRefuseToSealAKindTheNewLocationMayNotHold() async throws {
    let world = try await MoveWorld.synced(new: InMemoryStorageProvider(classPolicy: .iCloud))
    guard let key = EntityKey("weight") else { throw RuntimeFixtureFailure("weight is not an entity key") }
    try await world.mover.store.write { transaction in _ = try transaction.set(EntityRef(kind: MoveWorld.vital, key: key), ["value": 80]) }
    await #expect {
      _ = try await world.mover(engine: try await world.mover.started(on: world.old)).run()
    } throws: { error in
      guard case SyncMoveError.sync(.syncClassRefused(let kind, .health)) = error else { return false }
      return kind == MoveWorld.vital
    }
    #expect(try await world.snapshot(of: world.old)[VaultPath.moveNotice] == nil)
    #expect(try await world.new.listAll(prefix: "").isEmpty)
  }

  @Test
  func shouldCloseAMoveThroughAnAttachmentToTheNewLocationAfterItsLocationWasSaved() async throws {
    let world = try await MoveWorld.synced()
    await #expect(throws: SyncMoveError.self) { _ = try await world.mover(engine: try await world.mover.started(on: world.old), crashAt: .locationSaved).run() }
    #expect(try world.mover.locations.load() == .attached(world.newLocation))
    let moverNew = try await world.mover.started(on: world.new)
    let mover = SyncMover(
      engine: moverNew, attachment: world.mover.attachment(world.newLocation, provider: world.new), target: world.newLocation, targetProvider: world.new,
      locations: world.mover.locations)
    #expect(try await mover.run() == .moved(replica: moverNew.replica, location: world.newLocation))
    #expect(try world.mover.journal.load() == nil)
  }

  @Test
  func shouldCloseAFollowThroughTheNewLocationAfterItsLocationWasSaved() async throws {
    let world = try await MoveWorld.synced()
    _ = try await world.mover(engine: try await world.mover.started(on: world.old)).run()
    let followerOld = try await world.follower.started(on: world.old)
    let notice = try #require(try await followerOld.download().moved)
    await #expect(throws: SyncMoveError.self) { _ = try await world.follower(world.follower, engine: followerOld, crashAt: .locationSaved).run(notice) }
    let followerNew = try await world.follower.started(on: world.new)
    let follower = SyncMoveFollower(
      engine: followerNew, source: world.newLocation, target: world.newLocation, targetProvider: world.new, locations: world.follower.locations)
    #expect(try await follower.run(notice) == .moved(replica: followerNew.replica, location: world.newLocation))
    #expect(try world.follower.journal.load() == nil)
  }

  @Test(arguments: SyncMoveFollowStep.allCases)
  func shouldFinishAFollowInterruptedAtAnyStep(_ step: SyncMoveFollowStep) async throws {
    let world = try await MoveWorld.synced()
    try await world.follower.write("follower-unsent", "written before the notice")
    _ = try await world.mover(engine: try await world.mover.started(on: world.old)).run()
    let followerOld = try await world.follower.started(on: world.old)
    let notice = try #require(try await followerOld.download().moved)
    await #expect(throws: SyncMoveError.self) { _ = try await world.follower(world.follower, engine: followerOld, crashAt: step).run(notice) }
    let restarted = try await world.follower.started(on: world.old)
    guard case .moved = try await world.follower(world.follower, engine: restarted).run(notice) else { throw RuntimeFixtureFailure("the follow did not finish") }
    let followerNew = try await world.follower.started(on: world.new)
    let moverNew = try await world.mover.started(on: world.new)
    try await world.settle([moverNew, followerNew])
    #expect(try await world.mover.titles()["follower-unsent"] == "written before the notice")
    #expect(try await world.mover.titles() == world.follower.titles())
  }

  @Test
  func shouldRelayOnceWhenAFollowStopsAfterRelaying() async throws {
    let world = try await MoveWorld.synced()
    _ = try await world.mover(engine: try await world.mover.started(on: world.old)).run()
    try await world.third.write("third-after", "uploaded after the snapshot")
    _ = try await world.third.started(on: world.old).upload()
    let relays = RelayCount()
    let crashing = try await world.follower.started(on: world.old) { step throws(SyncError) in
      relays.note()
      throw .corruptState("injected crash after \(step)")
    }
    let notice = try #require(try await crashing.download().moved)
    await #expect(throws: SyncMoveError.self) { _ = try await world.follower(world.follower, engine: crashing).run(notice) }
    let pending = try await world.follower.store.pendingChanges(limit: .max).count
    let counting = try await world.follower.started(on: world.old) { _ throws(SyncError) in relays.note() }
    guard case .moved = try await world.follower(world.follower, engine: counting).run(notice) else { throw RuntimeFixtureFailure("the follow did not finish") }
    #expect(relays.count == 1)
    #expect(pending > 0)
    let moverNew = try await world.mover.started(on: world.new)
    try await world.settle([moverNew, try await world.follower.started(on: world.new)])
    #expect(try await world.mover.titles()["third-after"] == "uploaded after the snapshot")
  }

  @Test
  func shouldFinishAMoveAfterAReplicaChangeOfAnotherCauseInBetween() async throws {
    let world = try await MoveWorld.synced()
    await #expect(throws: SyncMoveError.self) { _ = try await world.mover(engine: try await world.mover.started(on: world.old), crashAt: .journaled).run() }
    let journaled = try #require(try world.mover.journal.load()).from
    try world.mover.forgetMarker()
    let restarted = try await world.mover.started(on: world.old)
    #expect(restarted.replica != journaled)
    guard case .moved = try await world.mover(engine: restarted).run() else { throw RuntimeFixtureFailure("the move did not finish") }
    let moverNew = try await world.mover.started(on: world.new)
    let followerNew = try await world.follow(world.follower, from: try await world.follower.started(on: world.old))
    try await world.mover.write("mover-late", "after the move")
    try await world.settle([moverNew, followerNew])
    #expect(try await world.follower.titles()["mover-late"] == "after the move")
    #expect(try await world.mover.titles() == world.follower.titles())
  }

  @Test
  func shouldFinishAFollowAfterAReplicaChangeOfAnotherCauseInBetween() async throws {
    let world = try await MoveWorld.synced()
    _ = try await world.mover(engine: try await world.mover.started(on: world.old)).run()
    let followerOld = try await world.follower.started(on: world.old)
    let notice = try #require(try await followerOld.download().moved)
    await #expect(throws: SyncMoveError.self) { _ = try await world.follower(world.follower, engine: followerOld, crashAt: .journaled).run(notice) }
    try world.follower.forgetMarker()
    let restarted = try await world.follower.started(on: world.old)
    await MoveCheck.expectVaultMoved { _ = try await restarted.upload() }
    guard case .moved = try await world.follower(world.follower, engine: restarted).run(notice) else { throw RuntimeFixtureFailure("the follow did not finish") }
    let moverNew = try await world.mover.started(on: world.new)
    let followerNew = try await world.follower.started(on: world.new)
    try await world.follower.write("follower-late", "after the follow")
    try await world.settle([moverNew, followerNew])
    #expect(try await world.mover.titles()["follower-late"] == "after the follow")
    #expect(try await world.mover.titles() == world.follower.titles())
  }

  @Test
  func shouldLetAFollowerThatCannotReachTheNewLocationStayAtTheOldOne() async throws {
    let world = try await MoveWorld.synced()
    _ = try await world.mover(engine: try await world.mover.started(on: world.old)).run()
    let followerOld = try await world.follower.started(on: world.old)
    let notice = try #require(try await followerOld.download().moved)
    await #expect(throws: SyncMoveError.self) { _ = try await world.follower(world.follower, engine: followerOld, crashAt: .journaled).run(notice) }
    try world.follower(world.follower, engine: followerOld).abandon()
    #expect(try world.follower.journal.load() == nil)
    try await followerOld.forgetMove()
    #expect(try await followerOld.recordedMove() == nil)
    try await world.follower.write("follower-stays", "at the old location")
    guard case .uploaded = try await followerOld.sync().upload else { throw RuntimeFixtureFailure("the follower did not upload after staying") }
    #expect(try await followerOld.download().moved == nil)
    #expect(try world.follower.locations.load() == .attached(world.oldLocation))
  }

  @Test
  func shouldPointAFollowAtAnotherReachOfTheNewLocationBeforeItIsSaved() async throws {
    let world = try await MoveWorld.synced()
    _ = try await world.mover(engine: try await world.mover.started(on: world.old)).run()
    let followerOld = try await world.follower.started(on: world.old)
    let notice = try #require(try await followerOld.download().moved)
    await #expect(throws: SyncMoveError.self) { _ = try await world.follower(world.follower, engine: followerOld, crashAt: .followed).run(notice) }
    let elsewhere = SyncLocation(settings: RuntimeFixture.localFolder("new-mounted-elsewhere"), vault: MoveWorld.vault, account: nil)
    guard case .moved(_, let location) = try await world.follower(world.follower, engine: followerOld, target: elsewhere).run(notice) else {
      throw RuntimeFixtureFailure("the retargeted follow did not finish")
    }
    #expect(location == elsewhere)
    #expect(try world.follower.locations.load() == .attached(elsewhere))
  }

  @Test
  func shouldRelayAChangeOfAReplicaTheMoverHeldAFileOf() async throws {
    let world = try await MoveWorld.synced()
    let thirdOld = try await world.third.started(on: world.old)
    try await world.third.write("z-early", "held back from the mover")
    guard case .uploaded = try await thirdOld.upload() else { throw RuntimeFixtureFailure("the third device did not upload") }
    let held = try #require(try await world.old.listAll(prefix: VaultPath.segmentPrefix(thirdOld.replica)).map(\.key).max())
    let view = CorruptingReadProvider(wrapping: world.old, corrupting: [held])
    let later = try #require(HLCTimestamp(wallMillis: Int64(Date().timeIntervalSince1970 * 1_000) + 60_000, counter: 0, replica: thirdOld.replica))
    let elsewhere = ChangeRecord(
      id: UUID.v7(), clock: later, schema: MoveWorld.registry.version, entity: RuntimeFixture.note, key: try #require(EntityKey("z-later")), kind: .set,
      fields: ["title": "reached the mover another way"])
    _ = try await world.mover.store.applyRemote([elsewhere.canonicalBytes()])
    let moverOld = try await world.mover.started(on: view)
    guard case .moved = try await world.mover(engine: moverOld, sourceProvider: view).run() else { throw RuntimeFixtureFailure("the move did not finish") }
    #expect(try await world.mover.titles()["z-early"] == nil)
    let moverNew = try await world.mover.started(on: world.new)
    let followerNew = try await world.follow(world.follower, from: try await world.follower.started(on: world.old))
    try await world.settle([moverNew, followerNew])
    #expect(try await world.mover.titles()["z-early"] == "held back from the mover")
  }

  @Test
  func shouldUploadAtTheOldLocationAfterStayingWithRelayedChangesQueued() async throws {
    let world = try await MoveWorld.synced()
    _ = try await world.mover(engine: try await world.mover.started(on: world.old)).run()
    try await world.third.write("third-after", "uploaded after the snapshot")
    _ = try await world.third.started(on: world.old).upload()
    let crashing = try await world.follower.started(on: world.old) { step throws(SyncError) in throw .corruptState("injected crash after \(step)") }
    let notice = try #require(try await crashing.download().moved)
    let before = try await world.follower.store.pendingChanges(limit: .max).count
    await #expect(throws: SyncMoveError.self) { _ = try await world.follower(world.follower, engine: crashing).run(notice) }
    #expect(try await world.follower.store.pendingChanges(limit: .max).count > before)
    try world.follower(world.follower, engine: crashing).abandon()
    let staying = try await world.follower.started(on: world.old)
    try await staying.forgetMove()
    try await world.follower.write("follower-stays", "written after staying")
    guard case .uploaded = try await staying.upload() else { throw RuntimeFixtureFailure("the follower did not upload after staying") }
    _ = try await world.third.started(on: world.old).download()
    #expect(try await world.third.titles()["follower-stays"] == "written after staying")
  }

  @Test
  func shouldRefuseUploadsAfterTheNoticeEvenWhenTheReplicaChangesOutsideADownload() async throws {
    let world = try await MoveWorld.synced()
    _ = try await world.mover(engine: try await world.mover.started(on: world.old)).run()
    let followerOld = try await world.follower.started(on: world.old)
    let before = followerOld.replica
    _ = try #require(try await followerOld.download().moved)
    try world.follower.forgetMarker()
    let restarted = try await world.follower.started(on: world.old)
    #expect(restarted.replica != before)
    try await world.follower.write("follower-after", "must wait for the follow")
    let snapshot = try await world.snapshot(of: world.old)
    await MoveCheck.expectVaultMoved { _ = try await restarted.upload() }
    #expect(try await world.snapshot(of: world.old) == snapshot)
  }
}

final class RelayCount: Sendable {
  private let value = Mutex(0)

  var count: Int { value.withLock { $0 } }

  func note() {
    value.withLock { $0 += 1 }
  }
}

enum MoveCheck {
  static func expectVaultMoved(_ body: () async throws -> Void) async {
    await #expect {
      try await body()
    } throws: { error in
      guard case SyncError.vaultMoved = error else { return false }
      return true
    }
  }

  static func base(in provider: any StorageProvider, of replica: ReplicaID, ring: KeyRing) async throws -> BaseFile {
    var parts: [BasePart] = []
    for object in try await provider.listAll(prefix: VaultPath.basePrefix(replica)) {
      parts.append(try BaseCodec.openPart(try await provider.get(object.key), at: object.key, vault: MoveWorld.vault) { ring.key($0) })
    }
    return try BaseCodec.assemble(parts) { ring.key($0) }
  }

  static func noteKeys(_ file: BaseFile) -> Set<String> {
    Set(
      file.lines.compactMap { line in
        guard let json = try? CanonicalJSON.decode(line), let record = try? ChangeRecord(json: json), record.entity == RuntimeFixture.note else { return nil }
        return record.key.rawValue
      })
  }

  @discardableResult
  static func putBlob(_ content: Data, in provider: any StorageProvider, ring: KeyRing) async throws -> ObjectKey {
    guard let key = ring.writingKey() else { throw RuntimeFixtureFailure("the ring holds no key") }
    let objectKey = VaultPath.blobPart(name: BlobName.make(for: content, key: key), part: 1, parts: 1)
    _ = try await provider.put(objectKey, data: try VaultFile.seal(content, path: objectKey.rawValue, vault: MoveWorld.vault, key: key), condition: .ifAbsent)
    return objectKey
  }
}
