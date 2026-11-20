import Foundation
import ShadowNetworking
import Synchronization

/// An in-process Microsoft Graph and identity platform: a drive with an app folder, delta with paging, lag and resync, simple and session uploads,
/// redirected downloads on another host, `$batch` deletes, bearer checks with refresh, and scripted faults.
final class FakeGraph: HTTPTransport {
  static let graphHost = "graph.microsoft.com"
  static let tokenHost = "login.microsoftonline.com"
  static let downloadHost = "download.fake-onedrive.test"
  static let uploadHost = "upload.fake-onedrive.test"
  static let appFolderID = "approot"
  static let serverDate = Date(timeIntervalSince1970: 1_790_000_000)
  static let serverDateHeader = "Mon, 21 Sep 2026 14:13:20 GMT"
  static let appFolderPath = "Apps/Novel Forge Tests/"

  struct Item: Sendable {
    let id: String
    var name: String
    var parentID: String
    let isFolder: Bool
    var data: Data
    var version: Int
    var changed: Int
  }

  struct Tombstone: Sendable {
    let id: String
    let changed: Int
  }

  struct Session: Sendable {
    let parentID: String
    let name: String
    let replace: Bool
    let total: Int?
    var received: Data
  }

  struct Recorded: Sendable {
    let method: String
    let url: URL
    let authorization: String?
    let range: String?
    let contentRange: String?
    let body: Data
  }

  struct Fault: Sendable {
    let matches: @Sendable (Recorded) -> Bool
    let status: Int
    let headers: [String: String]
    let body: Data
    let transportError: URLError?
  }

  private struct State: Sendable {
    var items: [String: Item] = [
      FakeGraph.appFolderID: Item(id: FakeGraph.appFolderID, name: "Novel Forge Tests", parentID: "root", isFolder: true, data: Data(), version: 1, changed: 0)
    ]
    var tombstones: [String: Tombstone] = [:]
    var sequence = 0
    var nextID = 1
    var horizon = 0
    var lagStep: Int?
    var deltaPageSize = 50
    var expireTokensOnce = false
    var sessions: [String: Session] = [:]
    var downloads: [String: String] = [:]
    var accessTokens: Set<String> = []
    var issued = 0
    var refreshFails = false
    var refreshKeepsToken = false
    var faults: [Fault] = []
    var requests: [Recorded] = []
    var createsParentsOnUpload = false
  }

  private let state = Mutex(State())

  init(initialAccessToken: String = "access-0") {
    state.withLock { $0.accessTokens = [initialAccessToken] }
  }

  var requests: [Recorded] { state.withLock { $0.requests } }

  func configure(_ change: (inout Configuration) -> Void) {
    state.withLock { state in
      var configuration = Configuration(
        lagStep: state.lagStep, deltaPageSize: state.deltaPageSize, refreshFails: state.refreshFails, refreshKeepsToken: state.refreshKeepsToken,
        createsParentsOnUpload: state.createsParentsOnUpload)
      change(&configuration)
      state.lagStep = configuration.lagStep
      state.deltaPageSize = configuration.deltaPageSize
      state.refreshFails = configuration.refreshFails
      state.refreshKeepsToken = configuration.refreshKeepsToken
      state.createsParentsOnUpload = configuration.createsParentsOnUpload
    }
  }

  struct Configuration {
    var lagStep: Int?
    var deltaPageSize: Int
    var refreshFails: Bool
    var refreshKeepsToken: Bool
    var createsParentsOnUpload: Bool
  }

  func inject(status: Int, headers: [String: String] = [:], body: String = "", when matches: @escaping @Sendable (Recorded) -> Bool) {
    state.withLock { $0.faults.append(Fault(matches: matches, status: status, headers: headers, body: Data(body.utf8), transportError: nil)) }
  }

  func inject(_ error: URLError, when matches: @escaping @Sendable (Recorded) -> Bool) {
    state.withLock { $0.faults.append(Fault(matches: matches, status: 0, headers: [:], body: Data(), transportError: error)) }
  }

  func revokeAccessTokens() {
    state.withLock { $0.accessTokens = [] }
  }

  func expireDeltaTokensOnce() {
    state.withLock { $0.expireTokensOnce = true }
  }

  var openSessions: Int { state.withLock { $0.sessions.count } }

  var fileNames: [String] {
    state.withLock { state in state.items.values.filter { !$0.isFolder }.map(\.name).sorted() }
  }

  func folderID(named name: String) -> String? {
    state.withLock { state in Self.child(named: name, of: Self.appFolderID, in: state)?.id }
  }

  func seedFile(name: String, data: Data, in folderID: String? = nil, folderName: String? = nil) {
    state.withLock { state in
      let parent = folderID ?? folderName.flatMap { Self.child(named: $0, of: Self.appFolderID, in: state)?.id } ?? Self.appFolderID
      _ = Self.create(name: name, parentID: parent, isFolder: false, data: data, in: &state)
    }
  }

  func seedFolder(name: String, in parentID: String = FakeGraph.appFolderID) -> String {
    state.withLock { state in Self.create(name: name, parentID: parentID, isFolder: true, data: Data(), in: &state).id }
  }

  func deleteItem(named name: String, in parentID: String) {
    state.withLock { state in
      guard let item = Self.child(named: name, of: parentID, in: state) else { return }
      Self.remove(item.id, in: &state)
    }
  }

  func renameItem(named name: String, in parentID: String, to newName: String) {
    state.withLock { state in
      guard let item = Self.child(named: name, of: parentID, in: state) else { return }
      Self.touch(item.id, in: &state) { $0.name = newName }
    }
  }

  func moveItem(named name: String, in parentID: String, to newParentID: String) {
    state.withLock { state in
      guard let item = Self.child(named: name, of: parentID, in: state) else { return }
      Self.touch(item.id, in: &state) { $0.parentID = newParentID }
    }
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    guard let url = request.url else { throw URLError(.badURL) }
    let recorded = Recorded(
      method: request.httpMethod ?? "GET", url: url, authorization: request.value(forHTTPHeaderField: "Authorization"), range: request.value(forHTTPHeaderField: "Range"),
      contentRange: request.value(forHTTPHeaderField: "Content-Range"), body: request.httpBody ?? Data())
    let reply = state.withLock { state -> Reply in
      state.requests.append(recorded)
      if let index = state.faults.firstIndex(where: { $0.matches(recorded) }) {
        let fault = state.faults.remove(at: index)
        if let error = fault.transportError { return .failure(error) }
        return Reply(status: fault.status, headers: fault.headers, body: fault.body)
      }
      return Self.route(recorded, in: &state)
    }
    if let error = reply.error { throw error }
    var headers = reply.headers
    headers["Date"] = headers["Date"] ?? Self.serverDateHeader
    guard let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers) else { throw URLError(.badServerResponse) }
    return (reply.body, response)
  }

  private struct Reply {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()
    var error: URLError?

    static func failure(_ error: URLError) -> Reply {
      Reply(status: 0, error: error)
    }

    static func json(_ status: Int, _ object: Any, headers: [String: String] = [:]) -> Reply {
      let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
      return Reply(status: status, headers: headers.merging(["Content-Type": "application/json"]) { first, _ in first }, body: body)
    }

    static func error(_ status: Int, _ code: String, headers: [String: String] = [:]) -> Reply {
      json(status, ["error": ["code": code, "message": code]], headers: headers)
    }
  }

  private static func route(_ request: Recorded, in state: inout State) -> Reply {
    switch request.url.host() {
    case tokenHost: return token(request, in: &state)
    case downloadHost: return download(request, in: state)
    case uploadHost: return upload(request, in: &state)
    case graphHost:
      guard let authorization = request.authorization, authorization.hasPrefix("Bearer "), state.accessTokens.contains(String(authorization.dropFirst(7))) else {
        return .error(401, "InvalidAuthenticationToken")
      }
      return graph(request, in: &state)
    default: return .error(404, "unknownHost")
    }
  }

  private static func token(_ request: Recorded, in state: inout State) -> Reply {
    let form = String(decoding: request.body, as: UTF8.self)
    guard form.contains("grant_type=refresh_token") else { return .json(400, ["error": "unsupported_grant_type"]) }
    if state.refreshFails { return .json(400, ["error": "invalid_grant", "error_description": "expired"]) }
    if !state.refreshKeepsToken { state.issued += 1 }
    let access = "access-\(state.issued)"
    state.accessTokens.insert(access)
    return .json(200, ["access_token": access, "token_type": "Bearer", "expires_in": 3600, "refresh_token": "refresh-\(state.issued)", "scope": "Files.ReadWrite.AppFolder"])
  }

  private static func graph(_ request: Recorded, in state: inout State) -> Reply {
    guard let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false), components.percentEncodedPath.hasPrefix("/v1.0") else {
      return .error(400, "invalidRequest")
    }
    let path = String(components.percentEncodedPath.dropFirst("/v1.0".count))
    let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { first, _ in first }
    return dispatch(method: request.method, path: path, query: query, body: request.body, in: &state)
  }

  private static func dispatch(method: String, path: String, query: [String: String], body: Data, in state: inout State) -> Reply {
    if path == "/$batch", method == "POST" { return batch(body, in: &state) }
    if path == "/me/drive/special/approot/children", method == "POST" { return createFolder(body, in: &state) }
    if path.hasPrefix("/me/drive/items/") { return byID(method: method, path: path, query: query, in: &state) }
    let prefix = "/me/drive/special/approot:/"
    guard path.hasPrefix(prefix) else { return .error(400, "invalidRequest") }
    let addressed = path.dropFirst(prefix.count).split(separator: ":", omittingEmptySubsequences: false)
    let segments = addressed[0].split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
    let action = addressed.count > 1 ? String(addressed[1]) : ""
    switch (method, action) {
    case ("GET", ""):
      guard let item = resolve(segments, in: state) else { return .error(404, "itemNotFound") }
      return .json(200, json(item, in: state))
    case ("GET", "/content"):
      guard let item = resolve(segments, in: state), !item.isFolder else { return .error(404, "itemNotFound") }
      return redirect(item, in: &state)
    case ("DELETE", ""):
      guard let item = resolve(segments, in: state) else { return .error(404, "itemNotFound") }
      remove(item.id, in: &state)
      return Reply(status: 204)
    case ("PUT", "/content"):
      return simpleUpload(segments, replace: query["@microsoft.graph.conflictBehavior"] != "fail", data: body, in: &state)
    case ("POST", "/createUploadSession"):
      return createSession(segments, body: body, in: &state)
    default:
      return .error(400, "invalidRequest")
    }
  }

  private static func byID(method: String, path: String, query: [String: String], in state: inout State) -> Reply {
    let parts = path.dropFirst("/me/drive/items/".count).split(separator: "/").map(String.init)
    guard let id = parts.first, parts.count == 2 else { return .error(400, "invalidRequest") }
    switch (method, parts[1]) {
    case ("GET", "content"):
      guard let item = state.items[id], !item.isFolder else { return .error(404, "itemNotFound") }
      return redirect(item, in: &state)
    case ("GET", "delta"):
      return delta(folderID: id, query: query, in: &state)
    default:
      return .error(400, "invalidRequest")
    }
  }

  private static func delta(folderID: String, query: [String: String], in state: inout State) -> Reply {
    guard state.items[folderID]?.isFolder == true else { return .error(404, "itemNotFound") }
    let since = query["token"].flatMap(Int.init)
    if since != nil, query["skip"] == nil, state.expireTokensOnce {
      state.expireTokensOnce = false
      return .error(410, "resyncChangesApplyDifferences", headers: ["Location": "https://\(graphHost)/v1.0/me/drive/items/\(folderID)/delta"])
    }
    let snapshot: Int
    if let fixed = query["snapshot"].flatMap(Int.init) {
      snapshot = fixed
    } else {
      if let step = state.lagStep { state.horizon = min(state.sequence, state.horizon + step) } else { state.horizon = state.sequence }
      snapshot = state.horizon
    }
    let floor = since ?? -1
    var changes: [(changed: Int, entry: [String: Any])] = []
    for item in state.items.values where item.changed > floor && item.changed <= snapshot && isWithin(item.id, folderID, in: state) {
      changes.append((item.changed, json(item, in: state)))
    }
    if since != nil {
      for tombstone in state.tombstones.values where tombstone.changed > floor && tombstone.changed <= snapshot {
        changes.append((tombstone.changed, ["id": tombstone.id, "deleted": ["state": "deleted"], "file": [:]]))
      }
    }
    changes.sort { $0.changed < $1.changed }
    let skip = query["skip"].flatMap(Int.init) ?? 0
    let page = changes.dropFirst(skip).prefix(state.deltaPageSize)
    let base = "https://\(graphHost)/v1.0/me/drive/items/\(folderID)/delta?token="
    let resumed = since.map(String.init) ?? "initial"
    var body: [String: Any] = ["value": page.map(\.entry)]
    if skip + page.count < changes.count {
      body["@odata.nextLink"] = base + "\(resumed)&snapshot=\(snapshot)&skip=\(skip + page.count)"
    } else {
      body["@odata.deltaLink"] = base + "\(snapshot)"
    }
    return .json(200, body)
  }

  private static func simpleUpload(_ segments: [String], replace: Bool, data: Data, in state: inout State) -> Reply {
    guard let name = segments.last else { return .error(400, "invalidRequest") }
    guard let parent = parentFolder(segments, creating: state.createsParentsOnUpload, in: &state) else { return .error(404, "itemNotFound") }
    return store(name: name, parentID: parent, data: data, replace: replace, in: &state)
  }

  private static func createSession(_ segments: [String], body: Data, in state: inout State) -> Reply {
    guard let name = segments.last else { return .error(400, "invalidRequest") }
    guard let parent = parentFolder(segments, creating: state.createsParentsOnUpload, in: &state) else { return .error(404, "itemNotFound") }
    let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    let behavior = ((object?["item"] as? [String: Any])?["@microsoft.graph.conflictBehavior"] as? String) ?? "fail"
    if let problem = invalidName(name, parentID: parent, in: state) { return problem }
    if behavior == "fail", child(named: name, of: parent, in: state) != nil { return .error(409, "nameAlreadyExists") }
    let id = "session-\(state.nextID)"
    state.nextID += 1
    state.sessions[id] = Session(parentID: parent, name: name, replace: behavior == "replace", total: nil, received: Data())
    return .json(200, ["uploadUrl": "https://\(uploadHost)/up/\(id)", "expirationDateTime": "2026-09-22T00:00:00Z"])
  }

  private static func upload(_ request: Recorded, in state: inout State) -> Reply {
    if request.authorization != nil { return .error(401, "unauthenticated") }
    let id = String(request.url.lastPathComponent)
    guard var session = state.sessions[id] else { return .error(404, "itemNotFound") }
    switch request.method {
    case "DELETE":
      state.sessions[id] = nil
      return Reply(status: 204)
    case "GET":
      return .json(200, ["nextExpectedRanges": ["\(session.received.count)-"]])
    case "PUT":
      guard let range = request.contentRange.flatMap(parseContentRange), range.end - range.start + 1 == request.body.count else { return .error(400, "invalidRange") }
      if let total = session.total, total != range.total { return .error(400, "invalidRange") }
      guard range.start == session.received.count else { return .error(416, "invalidRange") }
      let isLast = range.end + 1 == range.total
      guard isLast || request.body.count % 327_680 == 0 else { return .error(400, "fragmentNotAligned") }
      session.received.append(request.body)
      state.sessions[id] = Session(parentID: session.parentID, name: session.name, replace: session.replace, total: range.total, received: session.received)
      guard isLast else { return .json(202, ["nextExpectedRanges": ["\(session.received.count)-"]]) }
      let stored = store(name: session.name, parentID: session.parentID, data: session.received, replace: session.replace, in: &state)
      if (200..<300).contains(stored.status) { state.sessions[id] = nil }
      return stored
    default:
      return .error(400, "invalidRequest")
    }
  }

  private static func parseContentRange(_ value: String) -> (start: Int, end: Int, total: Int)? {
    guard value.hasPrefix("bytes ") else { return nil }
    let parts = value.dropFirst(6).split(separator: "/")
    let bounds = parts.first?.split(separator: "-") ?? []
    guard parts.count == 2, bounds.count == 2, let start = Int(bounds[0]), let end = Int(bounds[1]), let total = Int(parts[1]) else { return nil }
    return (start, end, total)
  }

  private static func store(name: String, parentID: String, data: Data, replace: Bool, in state: inout State) -> Reply {
    if let problem = invalidName(name, parentID: parentID, in: state) { return problem }
    if let existing = child(named: name, of: parentID, in: state) {
      guard replace, !existing.isFolder else { return .error(409, "nameAlreadyExists") }
      touch(existing.id, in: &state) { item in
        item.data = data
        item.version += 1
      }
      return .json(200, json(state.items[existing.id] ?? existing, in: state))
    }
    let item = create(name: name, parentID: parentID, isFolder: false, data: data, in: &state)
    return .json(201, json(item, in: state))
  }

  private static func invalidName(_ name: String, parentID: String, in state: State) -> Reply? {
    let lowered = name.lowercased()
    let stem = String(lowered.prefix { $0 != "." })
    let devices = Set(["con", "prn", "aux", "nul"] + (0...9).flatMap { ["com\($0)", "lpt\($0)"] })
    let forbidden = CharacterSet(charactersIn: "\"*:<>?/\\|")
    if name.unicodeScalars.contains(where: forbidden.contains) || name.hasSuffix(".") || name.hasSuffix(" ") || name.hasPrefix(" ") { return .error(400, "invalidRequest") }
    if devices.contains(stem) || [".lock", "desktop.ini"].contains(lowered) || lowered.contains("_vti_") || name.hasPrefix("~$") { return .error(400, "invalidRequest") }
    let folderPath = state.items[parentID].map { $0.id == appFolderID ? "" : $0.name + "/" } ?? ""
    if name.count > 255 || (appFolderPath + folderPath + name).count > 400 { return .error(400, "pathIsTooLong") }
    return nil
  }

  private static func createFolder(_ body: Data, in state: inout State) -> Reply {
    guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], let name = object["name"] as? String, object["folder"] != nil else {
      return .error(400, "invalidRequest")
    }
    if child(named: name, of: appFolderID, in: state) != nil { return .error(409, "nameAlreadyExists") }
    let item = create(name: name, parentID: appFolderID, isFolder: true, data: Data(), in: &state)
    return .json(201, json(item, in: state))
  }

  private static func batch(_ body: Data, in state: inout State) -> Reply {
    guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], let requests = object["requests"] as? [[String: Any]], requests.count <= 20 else {
      return .error(400, "invalidRequest")
    }
    var responses: [[String: Any]] = []
    for request in requests {
      guard let id = request["id"] as? String, let method = request["method"] as? String, let url = request["url"] as? String else { return .error(400, "invalidRequest") }
      let path = String(url.prefix { $0 != "?" })
      let reply = dispatch(method: method, path: path, query: [:], body: Data(), in: &state)
      var response: [String: Any] = ["id": id, "status": reply.status, "headers": reply.headers]
      if let json = try? JSONSerialization.jsonObject(with: reply.body) { response["body"] = json }
      responses.append(response)
    }
    return .json(200, ["responses": responses])
  }

  private static func redirect(_ item: Item, in state: inout State) -> Reply {
    let token = "dl-\(state.nextID)"
    state.nextID += 1
    state.downloads[token] = item.id
    return Reply(status: 302, headers: ["Location": "https://\(downloadHost)/\(token)"])
  }

  private static func download(_ request: Recorded, in state: State) -> Reply {
    guard let id = state.downloads[request.url.lastPathComponent], let item = state.items[id] else { return .error(404, "itemNotFound") }
    guard let range = request.range, range.hasPrefix("bytes=0-"), let last = Int(range.dropFirst("bytes=0-".count)) else { return Reply(status: 200, body: item.data) }
    return Reply(status: 206, body: Data(item.data.prefix(last + 1)))
  }

  private static func resolve(_ segments: [String], in state: State) -> Item? {
    var current = state.items[appFolderID]
    for segment in segments {
      guard let parent = current else { return nil }
      current = child(named: segment, of: parent.id, in: state)
    }
    return current
  }

  private static func parentFolder(_ segments: [String], creating: Bool, in state: inout State) -> String? {
    var parent = appFolderID
    for segment in segments.dropLast() {
      if let existing = child(named: segment, of: parent, in: state) {
        guard existing.isFolder else { return nil }
        parent = existing.id
      } else {
        guard creating else { return nil }
        parent = create(name: segment, parentID: parent, isFolder: true, data: Data(), in: &state).id
      }
    }
    return parent
  }

  private static func child(named name: String, of parentID: String, in state: State) -> Item? {
    state.items.values.first { $0.parentID == parentID && $0.name.caseInsensitiveCompare(name) == .orderedSame }
  }

  private static func isWithin(_ id: String, _ ancestor: String, in state: State) -> Bool {
    var current: String? = id
    while let id = current {
      if id == ancestor { return true }
      current = state.items[id]?.parentID
    }
    return false
  }

  @discardableResult
  private static func create(name: String, parentID: String, isFolder: Bool, data: Data, in state: inout State) -> Item {
    state.sequence += 1
    let item = Item(id: "item-\(state.nextID)", name: name, parentID: parentID, isFolder: isFolder, data: data, version: 1, changed: state.sequence)
    state.nextID += 1
    state.items[item.id] = item
    return item
  }

  private static func touch(_ id: String, in state: inout State, _ change: (inout Item) -> Void) {
    guard var item = state.items[id] else { return }
    change(&item)
    state.sequence += 1
    item.changed = state.sequence
    state.items[id] = item
  }

  private static func remove(_ id: String, in state: inout State) {
    for child in state.items.values where child.parentID == id { remove(child.id, in: &state) }
    guard state.items.removeValue(forKey: id) != nil else { return }
    state.sequence += 1
    state.tombstones[id] = Tombstone(id: id, changed: state.sequence)
  }

  private static func json(_ item: Item, in state: State) -> [String: Any] {
    var object: [String: Any] = [
      "id": item.id, "name": item.name, "size": item.data.count, "eTag": "\"\(item.id),\(item.version)\"", "cTag": "\"c:\(item.id),\(item.version)\"",
      "parentReference": ["id": item.parentID, "driveId": "drive-1"], "lastModifiedDateTime": "2026-09-21T14:13:20Z",
    ]
    object[item.isFolder ? "folder" : "file"] = item.isFolder ? ["childCount": state.items.values.count { $0.parentID == item.id }] : ["mimeType": "application/octet-stream"]
    return object
  }
}
