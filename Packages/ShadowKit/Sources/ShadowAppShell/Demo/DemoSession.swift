import Foundation
import OSLog
import Observation
import ShadowCore

/// The demo for the life of the process: `Demo` is what the app runs it with (its own vault in its own directory, `AIServices.demo` and an inert sync),
/// made by the app's `start` once the directory is fresh. The owner's vault stays as it was: the demo never reads or writes it, and leaving runs the app's
/// `stop` (which closes what the demo opened) and then deletes the directory.
@MainActor
@Observable
public final class DemoSession<Demo> {
  public enum State {
    case off
    case entering
    case on(Demo)
    case leaving
  }

  public typealias Locate = () throws(VaultOpenError) -> URL
  public typealias Start = @MainActor (_ directory: URL) async -> Demo
  public typealias Stop = @MainActor (Demo) async -> Void

  public private(set) var state = State.off
  /// Why the last attempt to enter could not make the demo's directory.
  public var failure: VaultOpenError?
  @ObservationIgnored private let locate: Locate
  @ObservationIgnored private let start: Start
  @ObservationIgnored private let stop: Stop
  @ObservationIgnored private let defaultsSuite: String?
  @ObservationIgnored private var directory: URL?
  @ObservationIgnored private var changing: Task<Void, Never>?

  /// `defaultsSuite` (`DemoDefaults.suiteName(for:)`) is emptied with the directory.
  public init(
    directory locate: @escaping Locate = DemoDirectory.appLocation, defaultsSuite: String? = nil, start: @escaping Start, stop: @escaping Stop
  ) {
    self.locate = locate
    self.defaultsSuite = defaultsSuite
    self.start = start
    self.stop = stop
  }

  public var active: Demo? {
    guard case .on(let demo) = state else { return nil }
    return demo
  }

  public var isOff: Bool {
    guard case .off = state else { return false }
    return true
  }

  /// At launch: removes a demo left by a process that ended in it, then enters the demo when the app was launched with `DemoDirectory.launchArgument`.
  public func launched(arguments: [String] = ProcessInfo.processInfo.arguments) async {
    if isOff, let url = try? locate() { clear(url) }
    guard DemoDirectory.isRequested(arguments: arguments) else { return }
    await enter()
  }

  /// Starts the demo in a fresh directory; does nothing unless it is off, and waits for a leave in flight first.
  public func enter() async {
    await changing?.value
    guard isOff else { return }
    let task = Task {
      state = .entering
      do throws(VaultOpenError) {
        let url = try locate()
        try DemoDirectory.recreate(url)
        if let defaultsSuite { DemoDefaults.clear(suiteName: defaultsSuite) }
        directory = url
        failure = nil
        state = .on(await start(url))
      } catch {
        Self.logger.error("The demo could not start code=\(error.code, privacy: .public)")
        failure = error
        state = .off
      }
    }
    changing = task
    await task.value
  }

  /// Stops the demo and deletes everything it made; does nothing unless it is on.
  public func leave() async {
    await changing?.value
    guard case .on(let demo) = state else { return }
    let task = Task {
      state = .leaving
      await stop(demo)
      if let directory { clear(directory) }
      directory = nil
      state = .off
    }
    changing = task
    await task.value
  }

  private func clear(_ url: URL) {
    if let defaultsSuite { DemoDefaults.clear(suiteName: defaultsSuite) }
    Self.remove(url)
  }

  private static func remove(_ url: URL) {
    do throws(VaultOpenError) {
      try DemoDirectory.remove(url)
    } catch {
      logger.error("The demo's files could not be removed code=\(error.code, privacy: .public)")
    }
  }

  nonisolated private static var logger: Logger { Logger(category: "demo") }
}
