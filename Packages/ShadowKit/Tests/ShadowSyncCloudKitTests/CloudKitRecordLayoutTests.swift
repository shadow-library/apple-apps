import Foundation
import ShadowSync
import ShadowTestSupport
import Testing

@testable import ShadowSyncCloudKit

@Suite("CloudKitRecordLayout", TestTimeLimit.standard)
struct CloudKitRecordLayoutTests {
  private static let inline = CloudKitRecordLayout.inlineLimit
  private static let part = CloudKitRecordLayout.partBytes
  private static let max = CloudKitRecordLayout.maxObjectBytes
  private static let splits: [(Int, [Int]?)] = [
    (0, nil), (1, nil), (inline, nil), (inline + 1, [inline + 1]), (part, [part]), (part + 1, [part, 1]), (2 * part + 1, [part, part, 1]),
    (max, [part, part, part, part, max - 4 * part]),
  ]

  @Test("should pin the wire layout")
  func pinsLayout() {
    #expect(CloudKitRecordLayout.recordType == "VaultObject")
    #expect(CloudKitRecordLayout.pathField == "path")
    #expect(CloudKitRecordLayout.sizeField == "size")
    #expect(CloudKitRecordLayout.bytesField == "bytes")
    #expect(CloudKitRecordLayout.partsField == "parts")
    #expect(CloudKitRecordLayout.nameDomain == "com.shadow.library.shadowsynccloudkit.record-name")
    #expect(Self.inline == 524_288)
    #expect(Self.part == 16_777_216)
    #expect(Self.max == 75_497_472)
  }

  @Test("should name a record o- and the lowercase SHA-256 of the domain, a zero byte and the key")
  func namesRecords() throws {
    #expect(CloudKitRecordLayout.recordName(of: try CloudKitFixture.key("a")).rawValue == "o-895eebb439dee91d36c3c92d0945822068a82bca2685be7709c1e3112329ddac")
    #expect(CloudKitRecordLayout.recordName(of: try CloudKitFixture.key("abc")).rawValue == "o-82023c677f9ab48845e2586f8d562d47cd851a236d8d32fe13d003fb45e17d38")
  }

  @Test(
    "should keep objects up to 512 KiB inline and split larger ones into 16 MiB parts",
    arguments: splits)
  func splitsPayloads(size: Int, parts: [Int]?) {
    let data = CloudKitFixture.data(size)
    let payload = CloudKitRecordLayout.payload(of: data, inlineLimit: Self.inline, partBytes: Self.part)
    switch payload {
    case .inline(let bytes):
      #expect(parts == nil)
      #expect(bytes == data)
    case .parts(let chunks):
      #expect(chunks.map(\.count) == parts)
      #expect(chunks.reduce(Data(), +) == data)
    }
  }

  @Test("should round-trip objects at every boundary through the fake zone, never sending a part or an inline value past its limit")
  func roundTripsBoundaries() async throws {
    let fake = FakeCloudKitZone()
    fake.configureLimits {
      $0.maxInlineBytes = Self.inline
      $0.maxAssetBytes = Self.part
    }
    let provider = CloudKitFixture.provider(fake)
    for (index, size) in [0, Self.inline, Self.inline + 1, Self.part, Self.part + 1, 3 * Self.part + 7, Self.max].enumerated() {
      let key = try CloudKitFixture.key("big/\(index)")
      let data = CloudKitFixture.data(size, salt: index)
      _ = try await provider.put(key, data: data, condition: .overwrite)
      #expect(try await provider.get(key) == data)
      let stored = try #require(fake.storedRecord(CloudKitRecordLayout.recordName(of: key)))
      #expect(stored.size == size)
      if size <= Self.inline {
        #expect(stored.payload == .inline(data))
      } else {
        guard case .parts(let parts) = stored.payload else {
          Issue.record("an object above the inline limit must be stored as parts")
          continue
        }
        #expect(parts.count == (size + Self.part - 1) / Self.part)
      }
    }
    let over = try CloudKitFixture.key("big/over")
    await #expect(throws: StorageError.tooLarge(over, limit: Self.max)) { try await provider.put(over, data: Data(count: Self.max + 1), condition: .overwrite) }
    #expect(fake.storedRecord(CloudKitRecordLayout.recordName(of: over)) == nil)
  }

  @Test("should replace a parted object with an inline one on overwrite")
  func overwritesLayouts() async throws {
    let fake = FakeCloudKitZone()
    var tuning = CloudKitTuning()
    tuning.inlineLimit = 4
    tuning.partBytes = 3
    let provider = CloudKitFixture.provider(fake, tuning: tuning)
    let key = try CloudKitFixture.key("swap")
    _ = try await provider.put(key, data: Data([1, 2, 3, 4, 5, 6, 7]), condition: .overwrite)
    #expect(fake.storedRecord(CloudKitRecordLayout.recordName(of: key))?.payload == .parts([Data([1, 2, 3]), Data([4, 5, 6]), Data([7])]))
    _ = try await provider.put(key, data: Data([9]), condition: .overwrite)
    #expect(try await provider.get(key) == Data([9]))
    #expect(try await provider.listAll(prefix: "") == [StorageObject(key: key, size: 1)])
  }

  @Test("should refuse a record whose parts do not add up to its size, or which holds another path")
  func verifiesRecords() async throws {
    let fake = FakeCloudKitZone()
    let provider = CloudKitFixture.provider(fake)
    let short = try CloudKitFixture.key("short")
    fake.seed(CloudKitObjectRecord(name: CloudKitRecordLayout.recordName(of: short), path: "short", size: 10, payload: .parts([Data(count: 4), Data(count: 4)])))
    await #expect(throws: StorageError.underlying("The iCloud record for short holds 8 of 10 bytes.")) { try await provider.get(short) }
    let squatted = try CloudKitFixture.key("squatted")
    fake.seed(try CloudKitFixture.record(path: "other", data: Data([1]), name: CloudKitRecordLayout.recordName(of: squatted)))
    await #expect(throws: StorageError.keyConflict(squatted)) { try await provider.get(squatted) }
  }

  @Test("should refuse as too large an object CloudKit finds too large for one record")
  func mapsRecordLimit() async throws {
    let fake = FakeCloudKitZone()
    fake.configureLimits { $0.maxInlineBytes = 10 }
    let provider = CloudKitFixture.provider(fake)
    let key = try CloudKitFixture.key("wide")
    await #expect(throws: StorageError.tooLarge(key, limit: Self.max)) { try await provider.put(key, data: Data(count: 11), condition: .overwrite) }
  }
}
