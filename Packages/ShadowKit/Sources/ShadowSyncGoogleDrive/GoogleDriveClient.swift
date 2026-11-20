import Foundation
import ShadowCore
import ShadowSync

struct GoogleDriveClient: Sendable {
  enum ChangesOutcome: Sendable {
    case page(DriveChangePage)
    case tokenRejected
  }

  enum WriteOutcome: Sendable {
    case written(GoogleDriveIndexedFile, serverTime: Date?)
    case missing
  }

  static let appDataFolder = "appDataFolder"
  static let vaultProperty = "com.shadow.library.shadowsyncgoogledrive.vault"
  static let fileFields = "id,name,size,version,modifiedTime,trashed,appProperties"
  private static let mediaType = "application/octet-stream"
  private static let redirectStatuses: Set<Int> = [301, 302, 303, 307, 308]

  let vault: String
  private let http: GoogleDriveHTTP
  private let tuning: GoogleDriveTuning
  private let apiBaseURL: URL
  private let uploadBaseURL: URL

  init(vault: String, http: GoogleDriveHTTP, tuning: GoogleDriveTuning, apiBaseURL: URL, uploadBaseURL: URL) {
    self.vault = vault
    self.http = http
    self.tuning = tuning
    self.apiBaseURL = apiBaseURL
    self.uploadBaseURL = uploadBaseURL
  }

  func indexed(_ resource: DriveFileResource) -> GoogleDriveIndexedFile? {
    guard resource.trashed != true, resource.appProperties?[Self.vaultProperty] == vault, let key = resource.name.flatMap(ObjectKey.init) else { return nil }
    return GoogleDriveIndexedFile(id: resource.id, key: key, size: resource.size ?? 0, version: resource.version ?? 0, modifiedTime: resource.modifiedTime ?? .distantPast)
  }

  func startPageToken() async throws(StorageError) -> String {
    let request = Self.request("GET", url(apiBaseURL, ["changes", "startPageToken"], [("fields", "startPageToken")]))
    let token: DriveStartPageToken = try decoded(try await succeeded(request), "start page token")
    return token.startPageToken
  }

  func changes(after token: String) async throws(StorageError) -> ChangesOutcome {
    let fields = "nextPageToken,newStartPageToken,changes(changeType,removed,fileId,file(\(Self.fileFields)))"
    let query = [
      ("pageToken", token), ("spaces", Self.appDataFolder), ("includeRemoved", "true"), ("pageSize", String(tuning.drivePageSize)), ("fields", fields),
    ]
    let (body, response) = try await http.authorized(Self.request("GET", url(apiBaseURL, ["changes"], query)))
    if [400, 404, 410].contains(response.statusCode) { return .tokenRejected }
    try Self.require(response, body)
    return .page(try decoded(body, "change page"))
  }

  func files(after pageToken: String?) async throws(StorageError) -> DriveFileListPage {
    let vaultLiteral = vault.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    let filter = "'\(Self.appDataFolder)' in parents and trashed = false and appProperties has { key='\(Self.vaultProperty)' and value='\(vaultLiteral)' }"
    var query = [
      ("spaces", Self.appDataFolder), ("q", filter), ("pageSize", String(tuning.drivePageSize)),
      ("fields", "nextPageToken,incompleteSearch,files(\(Self.fileFields))"),
    ]
    if let pageToken { query.append(("pageToken", pageToken)) }
    let page: DriveFileListPage = try decoded(try await succeeded(Self.request("GET", url(apiBaseURL, ["files"], query))), "file list")
    guard !page.incompleteSearch else { throw .unavailable("Google Drive could not list every file of the vault.") }
    return page
  }

  func download(_ id: String) async throws(StorageError) -> Data? {
    var request = Self.request("GET", url(apiBaseURL, ["files", id], [("alt", "media")]))
    var (body, response) = try await http.authorized(request)
    var trusted = true
    var hops = 0
    while Self.redirectStatuses.contains(response.statusCode) {
      hops += 1
      guard hops <= tuning.redirectHops else { throw .unavailable("Google Drive redirected a download too many times.") }
      guard let location = response.value(forHTTPHeaderField: "Location"), let target = URL(string: location, relativeTo: response.url ?? request.url)?.absoluteURL,
        target.scheme?.lowercased() == "https"
      else { throw .unavailable("Google Drive redirected a download to an unusable address.") }
      request = Self.request("GET", target)
      trusted = http.isTrusted(target)
      (body, response) = trusted ? try await http.authorized(request) : try await http.anonymous(request)
    }
    if trusted && response.statusCode == 404 { return nil }
    guard trusted || (200..<300).contains(response.statusCode) else { throw .unavailable("A Google download address refused the request (status \(response.statusCode)).") }
    try Self.require(response, body)
    return body
  }

  func create(_ key: ObjectKey, data: Data) async throws(StorageError) -> (GoogleDriveIndexedFile, serverTime: Date?) {
    let metadata = DriveFileMetadata(name: key.rawValue, parents: [Self.appDataFolder], mimeType: Self.mediaType, appProperties: [Self.vaultProperty: vault]).encoded()
    let outcome: WriteOutcome
    if data.count > tuning.multipartLimit {
      var initiation = Self.request("POST", url(uploadBaseURL, ["files"], [("uploadType", "resumable"), ("fields", Self.fileFields)]))
      initiation.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
      initiation.httpBody = metadata
      outcome = try await resumable(initiation, data: data)
    } else {
      let boundary = try boundary(avoiding: [metadata, data])
      var request = Self.request("POST", url(uploadBaseURL, ["files"], [("uploadType", "multipart"), ("fields", Self.fileFields)]))
      request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
      request.httpBody = Self.multipartBody(metadata: metadata, media: data, boundary: boundary)
      let (body, response) = try await http.authorized(request)
      try Self.require(response, body)
      outcome = try written(body, response, "created file")
    }
    guard case .written(let file, let serverTime) = outcome else { throw .underlying("Google Drive lost an upload session it had just opened.") }
    return (file, serverTime)
  }

  func update(_ id: String, data: Data) async throws(StorageError) -> WriteOutcome {
    if data.count > tuning.multipartLimit {
      return try await resumable(Self.request("PATCH", url(uploadBaseURL, ["files", id], [("uploadType", "resumable"), ("fields", Self.fileFields)])), data: data)
    }
    var request = Self.request("PATCH", url(uploadBaseURL, ["files", id], [("uploadType", "media"), ("fields", Self.fileFields)]))
    request.setValue(Self.mediaType, forHTTPHeaderField: "Content-Type")
    request.httpBody = data
    let (body, response) = try await http.authorized(request)
    if response.statusCode == 404 { return .missing }
    try Self.require(response, body)
    return try written(body, response, "updated file")
  }

  func delete(_ id: String) async throws(StorageError) {
    let (body, response) = try await http.authorized(Self.request("DELETE", url(apiBaseURL, ["files", id], [])))
    if response.statusCode == 404 { return }
    try Self.require(response, body)
  }

  static func multipartBody(metadata: Data, media: Data, boundary: String) -> Data {
    var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
    body.append(metadata)
    body.append(Data("\r\n--\(boundary)\r\nContent-Type: \(mediaType)\r\n\r\n".utf8))
    body.append(media)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    return body
  }

  private enum ResumableStep {
    case chunk
    case status
  }

  /// The file exists only once the last byte arrives; an abandoned session expires on Google's side and leaves nothing behind.
  private func resumable(_ initiation: URLRequest, data: Data) async throws(StorageError) -> WriteOutcome {
    var initiation = initiation
    initiation.setValue(Self.mediaType, forHTTPHeaderField: "X-Upload-Content-Type")
    initiation.setValue(String(data.count), forHTTPHeaderField: "X-Upload-Content-Length")
    let (opened, openResponse) = try await http.authorized(initiation)
    if openResponse.statusCode == 404 { return .missing }
    try Self.require(openResponse, opened)
    guard let location = openResponse.value(forHTTPHeaderField: "Location"), let session = URL(string: location), http.isTrusted(session) else {
      throw GoogleDriveFailure.malformed("upload session address")
    }
    var offset = 0
    var step = ResumableStep.chunk
    var setbacks = 0
    while true {
      let sent: (Data, HTTPURLResponse)?
      do {
        sent = try await http.authorized(step == .chunk ? chunkRequest(session, data: data, offset: offset) : statusRequest(session, total: data.count))
      } catch {
        guard case .unavailable = error, !Task.isCancelled else { throw error }
        sent = nil
      }
      if case (let body, let response)? = sent {
        switch response.statusCode {
        case 200, 201:
          return try written(body, response, "uploaded file")
        case 308:
          let persisted = try Self.persistedBytes(response, total: data.count)
          let advanced = persisted > offset || step == .status
          offset = persisted
          step = offset < data.count ? .chunk : .status
          if advanced && step == .chunk { continue }
        case 404, 410:
          throw .unavailable("The Google Drive upload session expired.")
        case 500..<600:
          step = .status
        default:
          throw GoogleDriveFailure.status(response, body: body)
        }
      } else {
        step = .status
      }
      setbacks += 1
      guard setbacks <= tuning.resumeAttempts else { throw .unavailable("The Google Drive upload did not complete.") }
    }
  }

  private func chunkRequest(_ session: URL, data: Data, offset: Int) -> URLRequest {
    let end = min(offset + tuning.chunkBytes, data.count)
    var request = Self.request("PUT", session)
    request.setValue(Self.mediaType, forHTTPHeaderField: "Content-Type")
    request.setValue("bytes \(offset)-\(end - 1)/\(data.count)", forHTTPHeaderField: "Content-Range")
    request.httpBody = Data(data[(data.startIndex + offset)..<(data.startIndex + end)])
    return request
  }

  private func statusRequest(_ session: URL, total: Int) -> URLRequest {
    var request = Self.request("PUT", session)
    request.setValue("bytes */\(total)", forHTTPHeaderField: "Content-Range")
    request.httpBody = Data()
    return request
  }

  private static func persistedBytes(_ response: HTTPURLResponse, total: Int) throws(StorageError) -> Int {
    guard let range = response.value(forHTTPHeaderField: "Range") else { return 0 }
    let parts = range.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
    guard parts.count == 2, parts[0] == "bytes" else { throw GoogleDriveFailure.malformed("upload range") }
    let bounds = parts[1].split(separator: "-", maxSplits: 1)
    guard bounds.count == 2, bounds[0] == "0", let last = Int(bounds[1]), last >= 0, last < total else { throw GoogleDriveFailure.malformed("upload range") }
    return last + 1
  }

  private func boundary(avoiding parts: [Data]) throws(StorageError) -> String {
    for _ in 0..<16 {
      let candidate = tuning.makeBoundary()
      let delimiter = Data("--\(candidate)".utf8)
      if !candidate.isEmpty && parts.allSatisfy({ $0.range(of: delimiter) == nil }) { return candidate }
    }
    throw .underlying("No multipart boundary avoids the object's bytes.")
  }

  private func written(_ body: Data, _ response: HTTPURLResponse, _ what: String) throws(StorageError) -> WriteOutcome {
    let resource: DriveFileResource = try decoded(body, what)
    guard let file = indexed(resource) else { throw GoogleDriveFailure.malformed(what) }
    let serverTime = response.value(forHTTPHeaderField: "Date").flatMap(TrustedClock.parseHTTPDate) ?? resource.modifiedTime
    return .written(file, serverTime: serverTime)
  }

  private func succeeded(_ request: URLRequest) async throws(StorageError) -> Data {
    let (body, response) = try await http.authorized(request)
    try Self.require(response, body)
    return body
  }

  private func decoded<Value: Decodable>(_ body: Data, _ what: String) throws(StorageError) -> Value {
    do {
      return try JSONDecoder().decode(Value.self, from: body)
    } catch {
      throw GoogleDriveFailure.malformed(what)
    }
  }

  private static func require(_ response: HTTPURLResponse, _ body: Data) throws(StorageError) {
    guard !(200..<300).contains(response.statusCode) else { return }
    throw GoogleDriveFailure.status(response, body: body)
  }

  private static func request(_ method: String, _ url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = method
    return request
  }

  private func url(_ base: URL, _ path: [String], _ query: [(String, String)]) -> URL {
    let address = path.reduce(base) { $0.appending(path: $1) }
    guard var components = URLComponents(url: address, resolvingAgainstBaseURL: false) else { preconditionFailure("A Drive address always parses.") }
    if !query.isEmpty { components.percentEncodedQuery = query.map { "\(Self.encoded($0.0))=\(Self.encoded($0.1))" }.joined(separator: "&") }
    guard let url = components.url else { preconditionFailure("A Drive address always builds.") }
    return url
  }

  private static func encoded(_ value: String) -> String {
    var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    allowed.insert(charactersIn: "-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }
}
