import Foundation
import OSLog
import ShadowCore
import ShadowSync

extension S3StorageProvider {
  /// The sync layer writes only `vault.json`, `keys/`, `blobs/` and `replicas/`, never a name starting with a dot.
  public static let conditionalWriteProbeKey: ObjectKey = {
    guard let key = ObjectKey(".shadow-s3-probe/conditional-writes") else { preconditionFailure("the probe key is a valid object key") }
    return key
  }()

  private static let probeLogger = Logger(category: "ShadowSyncS3.Probe")
  private static let probeBody = Data("com.shadow.library.shadowsyncs3.probe".utf8)
  private static let staleProbeAge: TimeInterval = 15 * 60

  /// Throws when the answer is inconclusive. Removes only the object it wrote, or one a crashed probe left more than 15 minutes ago by the server's clock,
  /// so a probe running on another device at the same time is never disturbed.
  public func probeConditionalWrites() async throws(StorageError) -> Bool {
    var mayRetry = true
    while true {
      let first = try await putObject(Self.conditionalWriteProbeKey, data: Self.probeBody, ifNoneMatch: true)
      if first.isUnsupportedCondition { return false }
      if first.isSuccess { return try await finishProbe() }
      guard first.status == 412 else { throw first.failure(context: failureContext) }
      let leftover = mayRetry ? try await probeLeftover() : .recent
      switch leftover {
      case .recent: throw .unavailable("A conditional-write probe object is already in this bucket, perhaps from another device's probe; try again in a few minutes.")
      case .gone: break
      case .stale: try await delete([Self.conditionalWriteProbeKey])
      }
      mayRetry = false
    }
  }

  private func finishProbe() async throws(StorageError) -> Bool {
    let second: S3Response
    do {
      second = try await putObject(Self.conditionalWriteProbeKey, data: Self.probeBody, ifNoneMatch: true)
    } catch {
      await removeProbeObject()
      throw error
    }
    await removeProbeObject()
    if second.status == 412 { return true }
    if second.isSuccess { return false }
    throw second.failure(context: failureContext)
  }

  private func probeLeftover() async throws(StorageError) -> ProbeLeftover {
    let response = try await send("HEAD", object: Self.conditionalWriteProbeKey)
    if response.status == 404 { return .gone }
    try response.requireSuccess(key: Self.conditionalWriteProbeKey, context: failureContext)
    guard let serverDate = response.serverDate, let written = response.headers["last-modified"].flatMap(TrustedClock.parseHTTPDate) else { return .recent }
    return serverDate.timeIntervalSince(written) > Self.staleProbeAge ? .stale : .recent
  }

  private func removeProbeObject() async {
    do {
      try await delete([Self.conditionalWriteProbeKey])
    } catch {
      Self.probeLogger.error("Could not remove the conditional-write probe object: \(error.code, privacy: .public)")
    }
  }
}

private enum ProbeLeftover {
  case gone
  case stale
  case recent
}

extension S3Response {
  fileprivate var isUnsupportedCondition: Bool {
    status == 501 || S3Failure(status: status, headers: headers, body: body).code == "NotImplemented"
  }

  fileprivate func failure(context: S3FailureContext) -> StorageError {
    S3Failure(status: status, headers: headers, body: body).storageError(key: nil, context: context)
  }
}
