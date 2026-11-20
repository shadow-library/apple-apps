import Foundation
import ShadowNetworking
import Synchronization

/// An in-process Drive v3 for one account: app data folder files by id with duplicate names allowed, an app-property query, a changes feed that can lag,
/// multipart, media and resumable uploads, deletes, redirected downloads, a token endpoint and injected faults.
final class FakeGoogleDrive: HTTPTransport {
  static let apiHost = "www.googleapis.com"
  static let foreignHost = "content.fake-usercontent.example"
  static let vaultProperty = "com.shadow.library.shadowsyncgoogledrive.vault"
  static let initialAccessToken = "access-0"

  enum Route: Sendable, Equatable {
    case startPageToken
    case changes
    case list
    case download
    case foreignDownload
    case multipart
    case media
    case resumableStart
    case chunk
    case delete
    case token
    case unknown
  }

  enum Fault: Sendable {
    case status(Int, reason: String? = nil, headers: [String: String] = [:])
    case transport(URLError.Code)
    case applyThenDrop
    case partialChunk(Int)
  }

  struct File: Sendable {
    var id: String
    var name: String
    var parents: [String]
    var appProperties: [String: String]
    var data: Data
    var version: Int64
    var modifiedTime: Date
    var trashed = false
  }

  struct Recorded: Sendable {
    let method: String
    let url: URL
    let route: Route
    let authorization: String?
    let contentRange: String?
    let contentType: String?
    let body: Data
  }

  private struct Change {
    let fileID: String
    var visibleAt: Int
  }

  private enum Target {
    case create(name: String, parents: [String], appProperties: [String: String])
    case update(String)
  }

  private struct Session {
    let target: Target
    let total: Int
    var received = Data()
    var completed: String?
  }

  private struct State {
    var files: [String: File] = [:]
    var log: [Change] = []
    var feedCalls = 0
    var feedLag = 0
    var invalidBelow = 0
    var nextID = 1
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    var sessions: [String: Session] = [:]
    var nextSession = 1
    var faults: [(Route, Fault)] = []
    var validTokens: Set<String> = [FakeGoogleDrive.initialAccessToken]
    var issued = 0
    var issuesValidTokens = true
    var refreshRejected = false
    var redirectsMedia = false
    var hiddenFromSearch: Set<String> = []
    var searchGhosts: [String: File] = [:]
    var requests: [Recorded] = []
    var hooks: [(Route, @Sendable () -> Void)] = []
    var pauses: [(Route, @Sendable () async -> Void)] = []
  }

  private struct Reply {
    let status: Int
    var body = Data()
    var headers: [String: String] = [:]
  }

  private let state = Mutex(State())

  var requests: [Recorded] { state.withLock { $0.requests } }
  var tokenRequests: Int { requests.filter { $0.route == .token }.count }

  func requests(_ route: Route) -> [Recorded] {
    requests.filter { $0.route == route }
  }

  func files(named name: String) -> [File] {
    state.withLock { $0.files.values.filter { $0.name == name }.sorted { $0.id < $1.id } }
  }

  var allFiles: [File] { state.withLock { $0.files.values.sorted { $0.id < $1.id } } }
  var openSessions: Int { state.withLock { $0.sessions.values.filter { $0.completed == nil }.count } }

  func inject(_ fault: Fault, on route: Route, times: Int = 1) {
    state.withLock { $0.faults += Array(repeating: (route, fault), count: times) }
  }

  func after(_ route: Route, run hook: @escaping @Sendable () -> Void) {
    state.withLock { $0.hooks.append((route, hook)) }
  }

  /// Runs `pause` once, after the reply to the next request on `route` is computed and before it is returned.
  func pause(_ route: Route, with pause: @escaping @Sendable () async -> Void) {
    state.withLock { $0.pauses.append((route, pause)) }
  }

  func setFeedLag(_ calls: Int) {
    state.withLock { $0.feedLag = calls }
  }

  func healFeed() {
    state.withLock { state in
      state.feedLag = 0
      for index in state.log.indices { state.log[index].visibleAt = min(state.log[index].visibleAt, state.feedCalls) }
    }
  }

  func expirePageTokens() {
    state.withLock { $0.invalidBelow = $0.log.count }
  }

  func setRedirectsMedia(_ redirects: Bool) {
    state.withLock { $0.redirectsMedia = redirects }
  }

  func hideFromSearch(_ id: String) {
    state.withLock { _ = $0.hiddenFromSearch.insert(id) }
  }

  func showInSearch(_ id: String) {
    state.withLock { _ = $0.hiddenFromSearch.remove(id) }
  }

  func revokeAccessTokens() {
    state.withLock { $0.validTokens = [] }
  }

  func setIssuesValidTokens(_ valid: Bool) {
    state.withLock { $0.issuesValidTokens = valid }
  }

  func setRefreshRejected(_ rejected: Bool) {
    state.withLock { $0.refreshRejected = rejected }
  }

  @discardableResult
  func insert(name: String, vault: String?, data: Data, id: String? = nil, modifiedTime: Date? = nil) -> String {
    state.withLock { state in
      let id = id ?? Self.newID(&state)
      let time = modifiedTime ?? Self.tick(&state)
      let properties = vault.map { [Self.vaultProperty: $0] } ?? [:]
      state.files[id] = File(id: id, name: name, parents: ["appDataFolder"], appProperties: properties, data: data, version: 1, modifiedTime: time)
      Self.logChange(id, &state)
      return id
    }
  }

  func remove(_ id: String) {
    state.withLock { state in
      state.files[id] = nil
      Self.logChange(id, &state)
    }
  }

  /// Deletes the file while search keeps showing it, as a lagging search index does.
  func removeKeepingSearch(_ id: String) {
    state.withLock { state in
      state.searchGhosts[id] = state.files.removeValue(forKey: id)
      Self.logChange(id, &state)
    }
  }

  func trash(_ id: String) {
    state.withLock { state in
      state.files[id]?.trashed = true
      state.files[id]?.version += 1
      Self.logChange(id, &state)
    }
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (outcome, hooks, pauses) = state.withLock { state in
      let route = Self.route(of: request)
      let recorded = Recorded(
        method: request.httpMethod ?? "GET", url: request.url ?? URL(fileURLWithPath: "/"), route: route, authorization: request.value(forHTTPHeaderField: "Authorization"),
        contentRange: request.value(forHTTPHeaderField: "Content-Range"), contentType: request.value(forHTTPHeaderField: "Content-Type"), body: request.httpBody ?? Data())
      state.requests.append(recorded)
      let outcome = Self.handle(request, route: route, &state)
      let due = state.hooks.filter { $0.0 == route }.map(\.1)
      state.hooks.removeAll { $0.0 == route }
      let paused = state.pauses.filter { $0.0 == route }.map(\.1)
      state.pauses.removeAll { $0.0 == route }
      return (outcome, due, paused)
    }
    for hook in hooks { hook() }
    for pause in pauses { await pause() }
    let reply = try outcome.get()
    guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else {
      throw URLError(.badURL)
    }
    return (reply.body, response)
  }

  private static func route(of request: URLRequest) -> Route {
    guard let url = request.url, let host = url.host() else { return .unknown }
    let method = request.httpMethod ?? "GET"
    if host == "oauth2.googleapis.com" { return .token }
    if host == foreignHost { return .foreignDownload }
    let path = url.path()
    let query = parameters(url)
    if query["upload_id"] != nil { return .chunk }
    switch (method, path) {
    case ("GET", "/drive/v3/changes/startPageToken"): return .startPageToken
    case ("GET", "/drive/v3/changes"): return .changes
    case ("GET", "/drive/v3/files"): return .list
    case ("GET", _) where path.hasPrefix("/drive/v3/files/") && query["alt"] == "media": return .download
    case ("DELETE", _) where path.hasPrefix("/drive/v3/files/"): return .delete
    case ("POST", "/upload/drive/v3/files"): return query["uploadType"] == "multipart" ? .multipart : query["uploadType"] == "resumable" ? .resumableStart : .unknown
    case ("PATCH", _) where path.hasPrefix("/upload/drive/v3/files/"):
      return query["uploadType"] == "media" ? .media : query["uploadType"] == "resumable" ? .resumableStart : .unknown
    default: return .unknown
    }
  }

  private static func handle(_ request: URLRequest, route: Route, _ state: inout State) -> Result<Reply, URLError> {
    if route != .foreignDownload && route != .token {
      let presented = request.value(forHTTPHeaderField: "Authorization") ?? ""
      guard presented.hasPrefix("Bearer "), state.validTokens.contains(String(presented.dropFirst(7))) else {
        return .success(errorReply(401, reason: "authError"))
      }
    }
    var dropAfter = false
    if let index = state.faults.firstIndex(where: { $0.0 == route }) {
      let fault = state.faults.remove(at: index).1
      switch fault {
      case .status(let status, let reason, let headers):
        var reply = errorReply(status, reason: reason)
        reply.headers.merge(headers) { _, new in new }
        return .success(reply)
      case .transport(let code):
        return .failure(URLError(code))
      case .applyThenDrop:
        dropAfter = true
      case .partialChunk(let count):
        return partialChunk(request, count: count, &state)
      }
    }
    let reply = route == .token ? token(request, &state) : respond(request, route: route, &state)
    return dropAfter ? .failure(URLError(.networkConnectionLost)) : .success(reply)
  }

  private static func respond(_ request: URLRequest, route: Route, _ state: inout State) -> Reply {
    guard let url = request.url else { return errorReply(400, reason: "badRequest") }
    let query = parameters(url)
    switch route {
    case .startPageToken: return json(["startPageToken": String(state.log.count)])
    case .changes: return changes(query, &state)
    case .list: return list(query, &state)
    case .download, .foreignDownload: return download(url, query: query, route: route, &state)
    case .multipart: return multipart(request, &state)
    case .media: return media(request, url: url, &state)
    case .resumableStart: return startSession(request, url: url, &state)
    case .chunk: return chunk(request, query: query, &state)
    case .delete:
      let id = url.lastPathComponent
      guard state.files.removeValue(forKey: id) != nil else { return errorReply(404, reason: "notFound") }
      logChange(id, &state)
      return Reply(status: 204)
    case .token, .unknown: return errorReply(400, reason: "badRequest")
    }
  }

  private static func changes(_ query: [String: String], _ state: inout State) -> Reply {
    guard query["spaces"] == "appDataFolder", query["includeRemoved"] == "true" else { return errorReply(400, reason: "badRequest") }
    guard let token = query["pageToken"].flatMap(Int.init), token >= state.invalidBelow, token <= state.log.count else {
      return errorReply(400, reason: "invalid")
    }
    state.feedCalls += 1
    var visibleEnd = token
    while visibleEnd < state.log.count && state.log[visibleEnd].visibleAt <= state.feedCalls { visibleEnd += 1 }
    let pageSize = query["pageSize"].flatMap(Int.init) ?? 100
    let end = min(visibleEnd, token + pageSize)
    let entries: [[String: Any]] = state.log[token..<end].map { change in
      guard let file = state.files[change.fileID] else { return ["changeType": "file", "fileId": change.fileID, "removed": true] }
      return ["changeType": "file", "fileId": change.fileID, "removed": false, "file": resource(file)]
    }
    var body: [String: Any] = ["changes": entries]
    body[end < visibleEnd ? "nextPageToken" : "newStartPageToken"] = String(end)
    return json(body)
  }

  private static func list(_ query: [String: String], _ state: inout State) -> Reply {
    guard query["spaces"] == "appDataFolder", let q = query["q"], q.contains("'appDataFolder' in parents"), q.contains("trashed = false") else {
      return errorReply(400, reason: "badRequest")
    }
    guard let match = q.firstMatch(of: /appProperties has \{ key='([^']*)' and value='([^']*)' \}/) else { return errorReply(400, reason: "badRequest") }
    let (key, value) = (String(match.1), String(match.2))
    let candidates = Array(state.files.values) + Array(state.searchGhosts.values)
    let matching =
      candidates
      .filter { $0.parents.contains("appDataFolder") && !$0.trashed && $0.appProperties[key] == value && !state.hiddenFromSearch.contains($0.id) }
      .sorted { $0.id < $1.id }
    let offset = query["pageToken"].flatMap(Int.init) ?? 0
    let pageSize = query["pageSize"].flatMap(Int.init) ?? 100
    let page = matching.dropFirst(offset).prefix(pageSize)
    var body: [String: Any] = ["files": page.map(resource), "incompleteSearch": false]
    if offset + page.count < matching.count { body["nextPageToken"] = String(offset + page.count) }
    return json(body)
  }

  private static func download(_ url: URL, query: [String: String], route: Route, _ state: inout State) -> Reply {
    let id = url.lastPathComponent
    guard let file = state.files[id] else { return errorReply(404, reason: "notFound") }
    if route == .download && state.redirectsMedia {
      return Reply(status: 302, headers: ["Location": "https://\(foreignHost)/download/\(id)?signature=s1"])
    }
    return Reply(status: 200, body: file.data, headers: ["Content-Type": "application/octet-stream"])
  }

  private static func multipart(_ request: URLRequest, _ state: inout State) -> Reply {
    guard let contentType = request.value(forHTTPHeaderField: "Content-Type"), contentType.hasPrefix("multipart/related; boundary="),
      let parts = multipartParts(request.httpBody ?? Data(), boundary: String(contentType.dropFirst("multipart/related; boundary=".count))), parts.count == 2,
      parts[0].headers == "Content-Type: application/json; charset=UTF-8", parts[1].headers == "Content-Type: application/octet-stream",
      let metadata = try? JSONSerialization.jsonObject(with: parts[0].content) as? [String: Any]
    else { return errorReply(400, reason: "badContent") }
    guard let target = createTarget(metadata) else { return errorReply(400, reason: "badContent") }
    return fileReply(create(target, data: parts[1].content, &state), state)
  }

  private static func media(_ request: URLRequest, url: URL, _ state: inout State) -> Reply {
    let id = url.lastPathComponent
    guard state.files[id] != nil else { return errorReply(404, reason: "notFound") }
    return fileReply(update(id, data: request.httpBody ?? Data(), &state), state)
  }

  private static func startSession(_ request: URLRequest, url: URL, _ state: inout State) -> Reply {
    guard request.value(forHTTPHeaderField: "X-Upload-Content-Type") == "application/octet-stream",
      let total = request.value(forHTTPHeaderField: "X-Upload-Content-Length").flatMap(Int.init)
    else { return errorReply(400, reason: "badRequest") }
    let target: Target
    if request.httpMethod == "PATCH" {
      let id = url.lastPathComponent
      guard state.files[id] != nil else { return errorReply(404, reason: "notFound") }
      target = .update(id)
    } else {
      guard let body = request.httpBody, let metadata = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let created = createTarget(metadata) else {
        return errorReply(400, reason: "badContent")
      }
      target = created
    }
    let session = "session-\(state.nextSession)"
    state.nextSession += 1
    state.sessions[session] = Session(target: target, total: total)
    var location = URLComponents(url: url, resolvingAgainstBaseURL: false)
    location?.queryItems = [URLQueryItem(name: "uploadType", value: "resumable"), URLQueryItem(name: "upload_id", value: session)]
    return Reply(status: 200, headers: ["Location": location?.url?.absoluteString ?? ""])
  }

  private static func chunk(_ request: URLRequest, query: [String: String], _ state: inout State) -> Reply {
    guard let id = query["upload_id"], var session = state.sessions[id] else { return errorReply(404, reason: "notFound") }
    guard let range = request.value(forHTTPHeaderField: "Content-Range"), range.hasPrefix("bytes ") else { return errorReply(400, reason: "badRange") }
    let spec = range.dropFirst("bytes ".count).split(separator: "/")
    guard spec.count == 2, Int(spec[1]) == session.total else { return errorReply(400, reason: "badRange") }
    if spec[0] == "*" {
      if let completed = session.completed, let file = state.files[completed] { return fileReply(file, state) }
      return incomplete(session)
    }
    let bounds = spec[0].split(separator: "-").compactMap { Int($0) }
    let body = request.httpBody ?? Data()
    guard session.completed == nil, bounds.count == 2, bounds[0] == session.received.count, bounds[1] - bounds[0] + 1 == body.count,
      bounds[1] + 1 == session.total || body.count.isMultiple(of: 256 * 1024)
    else { return errorReply(400, reason: "badRange") }
    session.received.append(body)
    guard session.received.count == session.total else {
      state.sessions[id] = session
      return incomplete(session)
    }
    let file: File
    switch session.target {
    case .create: file = create(session.target, data: session.received, &state)
    case .update(let fileID):
      guard state.files[fileID] != nil else { return errorReply(404, reason: "notFound") }
      file = update(fileID, data: session.received, &state)
    }
    session.completed = file.id
    state.sessions[id] = session
    return fileReply(file, state)
  }

  private static func partialChunk(_ request: URLRequest, count: Int, _ state: inout State) -> Result<Reply, URLError> {
    if let id = request.url.map(parameters)?["upload_id"], var session = state.sessions[id] {
      session.received.append((request.httpBody ?? Data()).prefix(count))
      state.sessions[id] = session
    }
    return .failure(URLError(.networkConnectionLost))
  }

  private static func incomplete(_ session: Session) -> Reply {
    guard !session.received.isEmpty else { return Reply(status: 308) }
    return Reply(status: 308, headers: ["Range": "bytes=0-\(session.received.count - 1)"])
  }

  private static func token(_ request: URLRequest, _ state: inout State) -> Reply {
    let form = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    guard form.contains("grant_type=refresh_token") else { return json(["error": "unsupported_grant_type"], status: 400) }
    guard !state.refreshRejected else { return json(["error": "invalid_grant"], status: 400) }
    state.issued += 1
    let token = "access-\(state.issued)"
    if state.issuesValidTokens { state.validTokens.insert(token) }
    return json(["access_token": token, "token_type": "Bearer", "expires_in": 3600])
  }

  private static func createTarget(_ metadata: [String: Any]) -> Target? {
    guard let name = metadata["name"] as? String, let parents = metadata["parents"] as? [String], parents == ["appDataFolder"],
      metadata["mimeType"] as? String == "application/octet-stream", let properties = metadata["appProperties"] as? [String: String]
    else { return nil }
    return .create(name: name, parents: parents, appProperties: properties)
  }

  private static func create(_ target: Target, data: Data, _ state: inout State) -> File {
    guard case .create(let name, let parents, let properties) = target else { preconditionFailure("create takes a create target") }
    let id = newID(&state)
    let file = File(id: id, name: name, parents: parents, appProperties: properties, data: data, version: 1, modifiedTime: tick(&state))
    state.files[id] = file
    logChange(id, &state)
    return file
  }

  private static func update(_ id: String, data: Data, _ state: inout State) -> File {
    let time = tick(&state)
    state.files[id]?.data = data
    state.files[id]?.version += 1
    state.files[id]?.modifiedTime = time
    logChange(id, &state)
    guard let file = state.files[id] else { preconditionFailure("update takes an existing file") }
    return file
  }

  private static func newID(_ state: inout State) -> String {
    defer { state.nextID += 1 }
    return "file-\(String(format: "%05d", state.nextID))"
  }

  private static func tick(_ state: inout State) -> Date {
    state.clock = state.clock.addingTimeInterval(0.001)
    return state.clock
  }

  private static func logChange(_ id: String, _ state: inout State) {
    state.log.append(Change(fileID: id, visibleAt: state.feedCalls + state.feedLag))
  }

  private static func resource(_ file: File) -> [String: Any] {
    [
      "id": file.id, "name": file.name, "size": String(file.data.count), "version": String(file.version), "modifiedTime": format(file.modifiedTime),
      "trashed": file.trashed, "appProperties": file.appProperties,
    ]
  }

  private static func fileReply(_ file: File, _ state: State) -> Reply {
    var reply = json(resource(file))
    reply.headers["Date"] = httpDate(state.clock)
    return reply
  }

  static func format(_ date: Date) -> String {
    date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
  }

  private static func httpDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    return formatter.string(from: date)
  }

  private static func json(_ object: [String: Any], status: Int = 200) -> Reply {
    let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    return Reply(status: status, body: body, headers: ["Content-Type": "application/json; charset=UTF-8"])
  }

  private static func errorReply(_ status: Int, reason: String?) -> Reply {
    let errors: [[String: Any]] = reason.map { [["domain": "global", "reason": $0, "message": "Fake failure"]] } ?? []
    return json(["error": ["code": status, "message": "Fake failure", "errors": errors]], status: status)
  }

  static func parameters(_ url: URL) -> [String: String] {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }) { first, _ in first }
  }

  /// Splits a multipart body strictly: the first delimiter opens the body, every part has headers and a blank line, and the close delimiter ends it.
  static func multipartParts(_ body: Data, boundary: String) -> [(headers: String, content: Data)]? {
    let framed = Data("\r\n".utf8) + body
    let delimiter = Data("\r\n--\(boundary)".utf8)
    var starts: [Range<Data.Index>] = []
    var searchFrom = framed.startIndex
    while let found = framed.range(of: delimiter, in: searchFrom..<framed.endIndex) {
      starts.append(found)
      searchFrom = found.upperBound
    }
    guard starts.count >= 2, starts[0].lowerBound == framed.startIndex, let last = starts.last, framed[last.upperBound...] == Data("--\r\n".utf8) else { return nil }
    var parts: [(headers: String, content: Data)] = []
    for (open, close) in zip(starts, starts.dropFirst()) {
      let segment = framed[open.upperBound..<close.lowerBound]
      guard segment.starts(with: Data("\r\n".utf8)), let blank = segment.range(of: Data("\r\n\r\n".utf8)), blank.lowerBound >= segment.startIndex + 2 else { return nil }
      let headers = String(decoding: segment[(segment.startIndex + 2)..<blank.lowerBound], as: UTF8.self)
      parts.append((headers, Data(segment[blank.upperBound...])))
    }
    return parts
  }
}
