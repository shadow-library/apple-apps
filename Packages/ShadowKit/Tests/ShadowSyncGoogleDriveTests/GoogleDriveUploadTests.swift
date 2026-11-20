import Foundation
import ShadowCore
import ShadowSync
import Synchronization
import Testing

@testable import ShadowSyncGoogleDrive

@Suite("GoogleDriveProvider uploads", TestTimeLimit.quick)
struct GoogleDriveUploadTests {
  private static let total = 600 * 1024

  private static func resumableTuning() -> GoogleDriveTuning {
    var tuning = GoogleDriveTuning()
    tuning.multipartLimit = 1024
    tuning.chunkBytes = 256 * 1024
    return tuning
  }

  @Test("should create a small object with one multipart request in the app data folder")
  func shouldSendMultipartBody() async throws {
    let fake = FakeGoogleDrive()
    let provider = try DriveFixture.provider(fake)
    let key = try DriveFixture.key("replicas/r1/seg/1-4-x")
    let data = Data("\r\n--not-the-boundary\r\n\u{0}\u{1}".utf8)
    _ = try await provider.put(key, data: data, condition: .overwrite)

    let request = try #require(fake.requests(.multipart).first)
    #expect(request.method == "POST")
    #expect(FakeGoogleDrive.parameters(request.url)["fields"] == "id,name,size,version,modifiedTime,trashed,appProperties")
    let contentType = try #require(request.contentType)
    #expect(contentType.hasPrefix("multipart/related; boundary=shadow-"))
    let boundary = String(contentType.dropFirst("multipart/related; boundary=".count))
    #expect(request.body.starts(with: Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)))
    #expect(request.body.suffix(boundary.utf8.count + 8) == Data("\r\n--\(boundary)--\r\n".utf8))
    let parts = try #require(FakeGoogleDrive.multipartParts(request.body, boundary: boundary))
    #expect(parts.map(\.headers) == ["Content-Type: application/json; charset=UTF-8", "Content-Type: application/octet-stream"])
    let metadata = String(decoding: parts[0].content, as: UTF8.self)
    let expected =
      #"{"appProperties":{"com.shadow.library.shadowsyncgoogledrive.vault":"Novel Forge"},"#
      + #""mimeType":"application/octet-stream","name":"replicas/r1/seg/1-4-x","parents":["appDataFolder"]}"#
    #expect(metadata == expected)
    #expect(parts[1].content == data)
    #expect(fake.files(named: key.rawValue).map(\.data) == [data])
  }

  @Test("should choose a multipart boundary that does not occur in the object")
  func shouldAvoidCollidingBoundary() async throws {
    let fake = FakeGoogleDrive()
    let candidates = Mutex(["collide", "fresh"])
    var tuning = GoogleDriveTuning()
    tuning.makeBoundary = { candidates.withLock { $0.removeFirst() } }
    let provider = try DriveFixture.provider(fake, tuning: tuning)
    let data = Data("payload --collide payload".utf8)
    _ = try await provider.put(DriveFixture.key("a"), data: data, condition: .overwrite)

    #expect(fake.requests(.multipart).first?.contentType == "multipart/related; boundary=fresh")
    #expect(fake.files(named: "a").map(\.data) == [data])
  }

  @Test("should upload a large object in chunks that are multiples of 256 KiB")
  func shouldChunkResumableUpload() async throws {
    let fake = FakeGoogleDrive()
    let provider = try DriveFixture.provider(fake, tuning: Self.resumableTuning())
    let data = DriveFixture.bytes(Self.total)
    let receipt = try await provider.put(DriveFixture.key("base/b/0"), data: data, condition: .overwrite)

    let start = try #require(fake.requests(.resumableStart).first)
    #expect(start.method == "POST")
    #expect(FakeGoogleDrive.parameters(start.url)["uploadType"] == "resumable")
    #expect(fake.requests(.chunk).map(\.contentRange) == ["bytes 0-262143/614400", "bytes 262144-524287/614400", "bytes 524288-614399/614400"])
    #expect(fake.requests(.chunk).allSatisfy { $0.authorization == "Bearer access-0" })
    #expect(fake.files(named: "base/b/0").map(\.data) == [data])
    let modified = try #require(fake.files(named: "base/b/0").first?.modifiedTime)
    #expect(abs(try #require(receipt.serverTime).timeIntervalSince(modified)) < 1)
  }

  @Test("should resume a dropped chunk from the bytes Drive kept")
  func shouldResumeDroppedChunk() async throws {
    let fake = FakeGoogleDrive()
    let provider = try DriveFixture.provider(fake, tuning: Self.resumableTuning())
    fake.inject(.partialChunk(100_000), on: .chunk)
    let data = DriveFixture.bytes(Self.total, salt: 9)
    _ = try await provider.put(DriveFixture.key("base/c/0"), data: data, condition: .overwrite)

    #expect(
      fake.requests(.chunk).map(\.contentRange) == [
        "bytes 0-262143/614400", "bytes */614400", "bytes 100000-362143/614400", "bytes 362144-614399/614400",
      ])
    #expect(fake.files(named: "base/c/0").map(\.data) == [data])
  }

  @Test("should ask for the upload status after a server error and continue")
  func shouldResumeAfterServerError() async throws {
    let fake = FakeGoogleDrive()
    let provider = try DriveFixture.provider(fake, tuning: Self.resumableTuning())
    fake.inject(.status(503), on: .chunk)
    let data = DriveFixture.bytes(Self.total, salt: 4)
    _ = try await provider.put(DriveFixture.key("base/d/0"), data: data, condition: .overwrite)

    #expect(fake.requests(.chunk).map(\.contentRange).prefix(3) == ["bytes 0-262143/614400", "bytes */614400", "bytes 0-262143/614400"])
    #expect(fake.files(named: "base/d/0").map(\.data) == [data])
  }

  @Test("should leave nothing behind when an upload session expires or keeps failing")
  func shouldLeaveNothingOnAbandonedSession() async throws {
    let fake = FakeGoogleDrive()
    let provider = try DriveFixture.provider(fake, tuning: Self.resumableTuning())
    let key = try DriveFixture.key("base/e/0")
    fake.inject(.status(404), on: .chunk)
    let expired = await DriveFixture.error { _ = try await provider.put(key, data: DriveFixture.bytes(Self.total), condition: .overwrite) }
    #expect(expired == .unavailable("The Google Drive upload session expired."))

    fake.inject(.transport(.networkConnectionLost), on: .chunk, times: 10)
    let failing = await DriveFixture.error { _ = try await provider.put(key, data: DriveFixture.bytes(Self.total), condition: .overwrite) }
    #expect(failing == .unavailable("The Google Drive upload did not complete."))
    #expect(fake.allFiles.isEmpty)
    #expect(await DriveFixture.error { _ = try await provider.get(key) } == .notFound(key))
  }

  @Test("should overwrite in place with a media upload or a resumable update")
  func shouldOverwriteInPlace() async throws {
    let fake = FakeGoogleDrive()
    let provider = try DriveFixture.provider(fake, tuning: Self.resumableTuning())
    let key = try DriveFixture.key("replicas/r1/manifest")
    _ = try await provider.put(key, data: Data([1]), condition: .overwrite)
    _ = try await provider.put(key, data: Data([2, 2]), condition: .overwrite)
    let large = DriveFixture.bytes(Self.total, salt: 5)
    _ = try await provider.put(key, data: large, condition: .overwrite)

    #expect(fake.requests(.media).map(\.method) == ["PATCH"])
    #expect(fake.requests(.resumableStart).map(\.method) == ["PATCH"])
    let files = fake.files(named: key.rawValue)
    #expect(files.count == 1)
    #expect(files.first?.version == 3)
    #expect(try await provider.get(key) == large)
  }

  @Test("should refuse an object over the limit without contacting Drive")
  func shouldRefuseTooLarge() async throws {
    let fake = FakeGoogleDrive()
    var tuning = GoogleDriveTuning()
    tuning.maxObjectBytes = 16
    let provider = try DriveFixture.provider(fake, tuning: tuning)
    let key = try DriveFixture.key("a")
    #expect(await DriveFixture.error { _ = try await provider.put(key, data: Data(count: 17), condition: .overwrite) } == .tooLarge(key, limit: 16))
    #expect(fake.requests.isEmpty)
  }
}
