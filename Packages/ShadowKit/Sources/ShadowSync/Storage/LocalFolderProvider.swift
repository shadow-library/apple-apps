import Foundation

/// Stores each object as a file under a folder. Two limits follow from the filesystem and surface as `StorageError.keyConflict`:
/// a key cannot coexist with a key that is its segment-ancestor or descendant (`a` beside `a/b`), and on case-insensitive volumes
/// keys that differ only by letter case would alias each other, so the second spelling is rejected.
public struct LocalFolderProvider: StorageProvider {
  private static let temporaryDirectoryName = ".tmp~"
  private static let staleTemporaryAge: TimeInterval = 3_600

  private enum EntryKind {
    case file
    case directory
    case symlink
    case other
  }

  private enum Access {
    case read
    case write
  }

  public let capabilities = StorageCapabilities(
    pushesChangeNotices: false,
    supportsPutIfAbsent: true,
    hasChangeFeed: false,
    reportsServerTime: false,
    maxObjectBytes: .max,
    classPolicy: .unrestricted
  )

  private let rootPath: String
  private let temporaryPath: String
  private let pageSize: Int

  public init(root: URL, pageSize: Int = 1000) throws(StorageError) {
    guard pageSize > 0 else { throw .underlying("page size must be positive") }
    do {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    } catch {
      throw .unavailable(error.localizedDescription)
    }
    guard let resolved = Self.canonicalPath(root.path) else { throw .unavailable("cannot resolve \(root.path)") }
    rootPath = resolved
    temporaryPath = resolved + "/" + Self.temporaryDirectoryName
    self.pageSize = pageSize
    do {
      try FileManager.default.createDirectory(atPath: temporaryPath, withIntermediateDirectories: true)
    } catch {
      throw .unavailable(error.localizedDescription)
    }
    Self.removeStaleTemporaryFiles(in: temporaryPath)
  }

  public func list(prefix: String, after cursor: ListCursor?) async throws(StorageError) -> ListPage {
    var matching: [StorageObject] = []
    visit(directory: rootPath, relative: "", prefix: prefix, into: &matching)
    matching.sort { $0.key < $1.key }
    let remaining = cursor.map { cursor in matching.filter { cursor.token.utf8.lexicographicallyPrecedes($0.key.rawValue.utf8) } } ?? matching
    let objects = Array(remaining.prefix(pageSize))
    let next = remaining.count > pageSize ? objects.last.map { ListCursor(token: $0.key.rawValue) } : nil
    return ListPage(objects: objects, next: next)
  }

  public func get(_ key: ObjectKey) async throws(StorageError) -> Data {
    guard let parent = try resolveParent(of: key, access: .read) else { throw .notFound(key) }
    let target = parent + "/" + Self.name(of: key)
    guard try existingFile(at: target, key: key, access: .read) else { throw .notFound(key) }
    do {
      return try Data(contentsOf: URL(fileURLWithPath: target))
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
      throw .notFound(key)
    } catch {
      throw .underlying(error.localizedDescription)
    }
  }

  public func put(_ key: ObjectKey, data: Data, condition: PutCondition) async throws(StorageError) -> PutReceipt {
    guard let parent = try resolveParent(of: key, access: .write) else { throw .keyConflict(key) }
    let target = parent + "/" + Self.name(of: key)
    _ = try existingFile(at: target, key: key, access: .write)
    let temporary = temporaryPath + "/" + UUID().uuidString
    defer { _ = unlink(temporary) }
    try writeDurably(data, to: temporary)
    switch condition {
    case .overwrite:
      guard rename(temporary, target) == 0 else {
        let code = errno
        throw code == EISDIR || code == ENOTDIR ? .keyConflict(key) : .underlying(Self.describe(code))
      }
    case .ifAbsent:
      guard link(temporary, target) == 0 else {
        let code = errno
        throw code == EEXIST ? .alreadyExists(key) : .underlying(Self.describe(code))
      }
    }
    return PutReceipt(serverTime: nil)
  }

  public func delete(_ keys: [ObjectKey]) async throws(StorageError) {
    for key in keys {
      guard let parent = try resolveParent(of: key, access: .read) else { continue }
      let target = parent + "/" + Self.name(of: key)
      guard try existingFile(at: target, key: key, access: .read) else { continue }
      guard unlink(target) == 0 || errno == ENOENT else { throw .underlying(Self.describe(errno)) }
    }
  }

  public func changeNotices() -> AsyncStream<Void> {
    AsyncStream { _ in }
  }

  private func writeDurably(_ data: Data, to path: String) throws(StorageError) {
    do {
      try FileManager.default.createDirectory(atPath: temporaryPath, withIntermediateDirectories: true)
      guard FileManager.default.createFile(atPath: path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
      let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try handle.close()
    } catch {
      throw .underlying(error.localizedDescription)
    }
  }

  private func isInsideRoot(_ path: String) -> Bool {
    path == rootPath || path.hasPrefix(rootPath + "/")
  }

  private func reject(_ key: ObjectKey, access: Access) throws(StorageError) -> String? {
    guard access == .read else { throw .keyConflict(key) }
    return nil
  }

  private func resolveParent(of key: ObjectKey, access: Access) throws(StorageError) -> String? {
    var current = rootPath
    for component in key.rawValue.split(separator: "/", omittingEmptySubsequences: false).dropLast() {
      let next = current + "/" + component
      var entry = Self.inspect(next)
      if entry == nil {
        guard access == .write else { return nil }
        guard mkdir(next, 0o755) == 0 || errno == EEXIST else { throw errno == ENOTDIR ? .keyConflict(key) : .underlying(Self.describe(errno)) }
        entry = Self.inspect(next)
      }
      switch entry?.kind {
      case .directory:
        guard Self.canonicalPath(next)?.utf8.elementsEqual(next.utf8) == true else { return try reject(key, access: access) }
        current = next
      case .symlink:
        guard let target = Self.resolvedPath(next), Self.inspect(target)?.kind == .directory else { return try reject(key, access: access) }
        guard isInsideRoot(target) else { throw .underlying("\(key) resolves outside the storage root") }
        current = target
      default:
        return try reject(key, access: access)
      }
    }
    return current
  }

  private func existingFile(at target: String, key: ObjectKey, access: Access) throws(StorageError) -> Bool {
    guard let entry = Self.inspect(target) else { return false }
    guard entry.kind == .file, Self.canonicalPath(target)?.utf8.elementsEqual(target.utf8) == true else {
      guard access == .read else { throw .keyConflict(key) }
      return false
    }
    return true
  }

  private func visit(directory: String, relative: String, prefix: String, into objects: inout [StorageObject]) {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
    for name in names {
      if relative.isEmpty && name == Self.temporaryDirectoryName { continue }
      guard let entry = Self.inspect(directory + "/" + name) else { continue }
      let path = relative + name
      switch entry.kind {
      case .directory:
        let nested = path + "/"
        guard nested.utf8.starts(with: prefix.utf8) || prefix.utf8.starts(with: nested.utf8) else { continue }
        visit(directory: directory + "/" + name, relative: nested, prefix: prefix, into: &objects)
      case .file:
        guard let key = ObjectKey(path), key.hasPrefix(prefix) else { continue }
        objects.append(StorageObject(key: key, size: entry.size))
      case .symlink, .other:
        continue
      }
    }
  }

  private static func name(of key: ObjectKey) -> String {
    String(key.rawValue.split(separator: "/").last ?? "")
  }

  private static func describe(_ code: Int32) -> String {
    String(cString: strerror(code))
  }

  private static func canonicalPath(_ path: String) -> String? {
    try? URL(fileURLWithPath: path).resourceValues(forKeys: [.canonicalPathKey]).canonicalPath
  }

  private static func resolvedPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return canonicalPath(String(cString: resolved))
  }

  private static func inspect(_ path: String) -> (kind: EntryKind, size: Int)? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    let kind: EntryKind
    switch info.st_mode & S_IFMT {
    case S_IFREG: kind = .file
    case S_IFDIR: kind = .directory
    case S_IFLNK: kind = .symlink
    default: kind = .other
    }
    return (kind, Int(info.st_size))
  }

  private static func removeStaleTemporaryFiles(in path: String) {
    let manager = FileManager.default
    guard let names = try? manager.contentsOfDirectory(atPath: path) else { return }
    let cutoff = Date(timeIntervalSinceNow: -staleTemporaryAge)
    for name in names {
      let entry = path + "/" + name
      guard let modified = (try? manager.attributesOfItem(atPath: entry))?[.modificationDate] as? Date, modified < cutoff else { continue }
      try? manager.removeItem(atPath: entry)
    }
  }
}
