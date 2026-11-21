import Foundation

struct SyncWork: OptionSet, Sendable, Hashable {
  let rawValue: Int

  static let refresh = SyncWork(rawValue: 1 << 0)
  static let evaluate = SyncWork(rawValue: 1 << 1)
  static let download = SyncWork(rawValue: 1 << 2)
  static let upload = SyncWork(rawValue: 1 << 3)

  static let sync: SyncWork = [.download, .upload]
  static let launch: SyncWork = [.evaluate, .download, .upload]
  static let foreground: SyncWork = [.refresh, .evaluate, .download, .upload]
}
