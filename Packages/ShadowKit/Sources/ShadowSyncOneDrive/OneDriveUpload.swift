import Foundation
import ShadowCore
import ShadowNetworking
import ShadowSync

/// One upload attempt into the vault folder. `folderMissing` lets the caller create the folder and try again.
enum OneDriveUploadOutcome {
  case stored(serverTime: Date?)
  case folderMissing
}

struct OneDriveUpload {
  let client: GraphClient
  let paths: OneDrivePaths
  let options: OneDriveProviderOptions

  func run(key: ObjectKey, name: String, body: Data, condition: PutCondition) async throws(StorageError) -> OneDriveUploadOutcome {
    guard body.count > options.simpleUploadLimit, !body.isEmpty else { return try await simple(key: key, name: name, body: body, condition: condition) }
    return try await session(key: key, name: name, body: body, condition: condition, restarts: 1)
  }

  private func simple(key: ObjectKey, name: String, body: Data, condition: PutCondition) async throws(StorageError) -> OneDriveUploadOutcome {
    guard let url = client.url(paths.content(name) + "?@microsoft.graph.conflictBehavior=" + Self.conflictBehavior(condition)) else {
      throw .underlying("the OneDrive upload address cannot be built")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    let response = try await client.authorized(request)
    if response.status == 404 { return .folderMissing }
    return try stored(response, key: key, condition: condition)
  }

  private func session(key: ObjectKey, name: String, body: Data, condition: PutCondition, restarts: Int) async throws(StorageError) -> OneDriveUploadOutcome {
    guard let url = client.url(paths.uploadSession(name)) else { throw .underlying("the OneDrive upload address cannot be built") }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(#"{"item":{"@microsoft.graph.conflictBehavior":"\#(Self.conflictBehavior(condition))"}}"#.utf8)
    let created = try await client.authorized(request)
    if created.status == 404 { return .folderMissing }
    if created.status == 409 { throw Self.conflict(key, condition: condition) }
    guard created.isSuccess else { throw client.failure(created) }
    guard let uploadURL = (try? JSONDecoder.shadow().decode(GraphUploadSession.self, from: created.body))?.uploadUrl else {
      throw .unavailable("OneDrive created an upload session without an address")
    }
    do throws(UploadFailure) {
      return try await send(body, to: uploadURL, key: key, condition: condition)
    } catch {
      await cancel(uploadURL)
      switch error {
      case .sessionGone where restarts > 0: return try await session(key: key, name: name, body: body, condition: condition, restarts: restarts - 1)
      case .sessionGone: throw .unavailable("the OneDrive upload session expired")
      case .storage(let error): throw error
      }
    }
  }

  private enum UploadFailure: Error {
    case sessionGone
    case storage(StorageError)
  }

  private func send(_ body: Data, to uploadURL: URL, key: ObjectKey, condition: PutCondition) async throws(UploadFailure) -> OneDriveUploadOutcome {
    let total = body.count
    var offset = 0
    var resumes = 0
    let rounds = (total / options.uploadFragmentBytes + 1) * (options.uploadResumes + 2)
    for _ in 0..<rounds {
      let end = min(offset + options.uploadFragmentBytes, total)
      var request = URLRequest(url: uploadURL)
      request.httpMethod = "PUT"
      request.setValue("\(end - offset)", forHTTPHeaderField: "Content-Length")
      request.setValue("bytes \(offset)-\(end - 1)/\(total)", forHTTPHeaderField: "Content-Range")
      request.httpBody = body.subdata(in: offset..<end)
      let response: GraphResponse
      do {
        response = try await client.anonymous(request)
      } catch {
        guard case .unavailable = error, resumes < options.uploadResumes, !Task.isCancelled else { throw .storage(error) }
        resumes += 1
        offset = try await resumePoint(uploadURL, total: total)
        continue
      }
      switch response.status {
      case 200, 201:
        do {
          return try stored(response, key: key, condition: condition)
        } catch {
          throw .storage(error)
        }
      case 202:
        offset = Self.nextOffset(in: response.body) ?? end
      case 404:
        throw .sessionGone
      case 409:
        throw .storage(Self.conflict(key, condition: condition))
      case 416:
        offset = try await resumePoint(uploadURL, total: total)
      default:
        let error = client.failure(response)
        guard case .unavailable = error, resumes < options.uploadResumes else { throw .storage(error) }
        resumes += 1
        offset = try await resumePoint(uploadURL, total: total)
      }
      guard offset < total else { throw .storage(.unavailable("OneDrive accepted every byte but did not complete the upload")) }
    }
    throw .storage(.unavailable("the OneDrive upload did not finish"))
  }

  private func resumePoint(_ uploadURL: URL, total: Int) async throws(UploadFailure) -> Int {
    var request = URLRequest(url: uploadURL)
    request.httpMethod = "GET"
    let response: GraphResponse
    do {
      response = try await client.anonymous(request)
    } catch {
      throw .storage(error)
    }
    if response.status == 404 { throw .sessionGone }
    guard response.isSuccess, let offset = Self.nextOffset(in: response.body), offset < total else { throw .storage(client.failure(response)) }
    return offset
  }

  /// Runs outside the caller's task, so a cancelled put still discards its session.
  private func cancel(_ uploadURL: URL) async {
    var request = URLRequest(url: uploadURL)
    request.httpMethod = "DELETE"
    let client = client
    await Task { _ = try? await client.anonymous(request) }.value
  }

  private func stored(_ response: GraphResponse, key: ObjectKey, condition: PutCondition) throws(StorageError) -> OneDriveUploadOutcome {
    if response.status == 409 { throw Self.conflict(key, condition: condition) }
    guard response.isSuccess else { throw client.failure(response) }
    guard let item = try? JSONDecoder.shadow().decode(GraphItem.self, from: response.body) else { throw .unavailable("OneDrive stored the file but its answer could not be read") }
    let serverTime = response.headers["date"].flatMap(TrustedClock.parseHTTPDate) ?? item.lastModifiedDateTime
    return .stored(serverTime: serverTime)
  }

  private static func nextOffset(in body: Data) -> Int? {
    guard let ranges = (try? JSONDecoder().decode(GraphUploadSession.self, from: body))?.nextExpectedRanges else { return nil }
    let starts = ranges.compactMap { range in Int(range.prefix { $0 != "-" }) }
    return starts.min()
  }

  private static func conflictBehavior(_ condition: PutCondition) -> String {
    switch condition {
    case .overwrite: "replace"
    case .ifAbsent: "fail"
    }
  }

  /// With `replace` a 409 means a folder holds the name, which no key can displace.
  private static func conflict(_ key: ObjectKey, condition: PutCondition) -> StorageError {
    switch condition {
    case .overwrite: .keyConflict(key)
    case .ifAbsent: .alreadyExists(key)
    }
  }
}
