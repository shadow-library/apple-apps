import Foundation
import ShadowSync
import ShadowTestSupport

@testable import ShadowSyncCloudKit

struct CloudKitKeyError: Error {
  let raw: String
}

enum CloudKitFixture {
  static func provider(_ fake: FakeCloudKitZone, store: any CloudKitStateStore = InMemoryCloudKitStateStore(), tuning: CloudKitTuning = CloudKitTuning())
    -> CloudKitStorageProvider
  {
    CloudKitStorageProvider(client: fake, stateStore: store, tuning: tuning)
  }

  static func key(_ raw: String) throws -> ObjectKey {
    guard let key = ObjectKey(raw) else { throw CloudKitKeyError(raw: raw) }
    return key
  }

  static func data(_ count: Int, salt: Int = 0) -> Data {
    let blockSize = 4096
    let pattern = Data((0..<blockSize).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ salt) })
    var data = Data(capacity: count)
    var block = 0
    while data.count < count {
      var chunk = pattern.prefix(count - data.count)
      chunk[chunk.startIndex] = UInt8(truncatingIfNeeded: block)
      if chunk.count > 1 { chunk[chunk.startIndex + 1] = UInt8(truncatingIfNeeded: block >> 8) }
      data.append(chunk)
      block += 1
    }
    return data
  }

  static func keys(_ provider: CloudKitStorageProvider, prefix: String = "") async throws -> [String] {
    try await provider.listAll(prefix: prefix).map(\.key.rawValue)
  }

  /// The stream's first element, or nil when none arrives in time, so a missing event fails the test instead of hanging it.
  static func first<Element: Sendable>(_ stream: AsyncStream<Element>, within limit: Duration = .seconds(10)) async -> Element? {
    await withTaskGroup(of: Element?.self) { group in
      group.addTask { await stream.first { _ in true } }
      group.addTask {
        try? await Task.sleep(for: limit)
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
  }

  static func record(path: String, data: Data, name: CloudKitRecordName? = nil) throws -> CloudKitObjectRecord {
    let recordName = try name ?? CloudKitRecordLayout.recordName(of: key(path))
    return CloudKitObjectRecord(name: recordName, path: path, size: data.count, payload: .inline(data))
  }
}
