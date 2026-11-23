import Foundation
import ShadowTestSupport
import Testing

@testable import ShadowAppShell

@MainActor
@Suite("DemoSession", TestTimeLimit.quick)
struct DemoSessionTests {
  private final class Demo {
    let directory: URL
    var stopped = false

    init(directory: URL) {
      self.directory = directory
    }
  }

  private final class Calls {
    var started: [URL] = []
    var stopped = 0
    var filesAtStart: [[String]] = []
    var activeWhileStopping: [Bool] = []
    weak var session: DemoSession<Demo>?
  }

  private let suite = "com.shadow.apps.test.demo-\(UUID().uuidString)"

  private let root = FileManager.default.temporaryDirectory.appending(path: "DemoSessionTests-\(UUID().uuidString)", directoryHint: .isDirectory)

  private var demoDirectory: URL { root.appending(path: DemoDirectory.name, directoryHint: .isDirectory) }

  private func session(_ calls: Calls, locate: DemoSession<Demo>.Locate? = nil) -> DemoSession<Demo> {
    let url = demoDirectory
    let session = DemoSession(
      directory: locate ?? { url }, defaultsSuite: suite,
      start: { directory in
        calls.started.append(directory)
        calls.filesAtStart.append((try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? ["missing"])
        try? Data("demo".utf8).write(to: directory.appending(path: "vault.sqlite"))
        return Demo(directory: directory)
      },
      stop: { demo in
        #expect(FileManager.default.fileExists(atPath: demo.directory.path(percentEncoded: false)))
        calls.activeWhileStopping.append(calls.session?.active != nil)
        demo.stopped = true
        calls.stopped += 1
      })
    calls.session = session
    return session
  }

  private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

  @Test("should place the demo beside the vaults directory, never inside it")
  func shouldPlaceTheDemoBesideTheVaults() throws {
    let vault = try VaultDirectory.default(bundleIdentifier: "com.shadow.apps.test")
    let demo = try DemoDirectory.default(bundleIdentifier: "com.shadow.apps.test")

    #expect(demo.lastPathComponent == "Demo")
    #expect(demo.deletingLastPathComponent().standardized == vault.deletingLastPathComponent().deletingLastPathComponent().standardized)
    #expect(!demo.standardized.path.hasPrefix(vault.deletingLastPathComponent().standardized.path))
  }

  @Test("should enter in an empty directory, removing whatever an earlier demo left there")
  func shouldEnterInAFreshDirectory() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: demoDirectory, withIntermediateDirectories: true)
    try Data("left".utf8).write(to: demoDirectory.appending(path: "leftover.sqlite"))
    let calls = Calls()
    let session = session(calls)

    await session.enter()

    #expect(calls.started == [demoDirectory])
    #expect(calls.filesAtStart == [[]])
    #expect(session.active?.directory == demoDirectory)
  }

  @Test("should stop the demo before deleting its directory when leaving")
  func shouldStopThenDeleteWhenLeaving() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let calls = Calls()
    let session = session(calls)
    await session.enter()
    let demo = try #require(session.active)

    await session.leave()

    #expect(demo.stopped)
    #expect(calls.stopped == 1)
    #expect(calls.activeWhileStopping == [false])
    #expect(!exists(demoDirectory))
    #expect(session.isOff)
  }

  @Test("should empty its defaults suite on entering and leaving, and keep its directory out of backups")
  func shouldEmptyItsDefaultsAndStayOutOfBackups() async throws {
    defer {
      try? FileManager.default.removeItem(at: root)
      DemoDefaults.clear(suiteName: suite)
    }
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.set("left", forKey: "choice")
    let session = session(Calls())

    await session.enter()
    #expect(defaults.object(forKey: "choice") == nil)
    #expect(BackupExclusion.isExcluded(demoDirectory))
    defaults.set("demo", forKey: "choice")
    await session.leave()

    #expect(defaults.object(forKey: "choice") == nil)
    #expect(
      DemoDefaults.suiteName(for: AppIdentity(id: "com.shadow.apps.test", displayName: "Test", vaultNoun: "vault", vaultTitle: "Vault", exampleBucketName: "b"))
        == "com.shadow.apps.test.demo")
  }

  @Test("should start only once when asked to enter twice, and stop only once when asked to leave twice")
  func shouldEnterAndLeaveOnce() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    let calls = Calls()
    let session = session(calls)

    async let first: Void = session.enter()
    async let second: Void = session.enter()
    _ = await (first, second)
    async let leaving: Void = session.leave()
    async let again: Void = session.leave()
    _ = await (leaving, again)

    #expect(calls.started.count == 1)
    #expect(calls.stopped == 1)
  }

  @Test("should enter at launch only with the launch argument, and remove a leftover demo either way")
  func shouldEnterAtLaunchOnlyWithTheArgument() async throws {
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: demoDirectory, withIntermediateDirectories: true)
    let calls = Calls()
    let plain = session(calls)

    await plain.launched(arguments: ["/Applications/App"])

    #expect(plain.isOff)
    #expect(calls.started.isEmpty)
    #expect(!exists(demoDirectory))

    let requested = session(calls)
    await requested.launched(arguments: ["/Applications/App", DemoDirectory.launchArgument])

    #expect(requested.active != nil)
    #expect(DemoDirectory.isRequested(arguments: ["App", "-ShadowDemo"]))
    #expect(!DemoDirectory.isRequested(arguments: ["App", "-ShadowDemoX"]))
  }

  @Test("should stay off and say why when the demo's directory has no place")
  func shouldStayOffWhenTheDirectoryFails() async {
    let calls = Calls()
    let session = session(calls) { () throws(VaultOpenError) -> URL in throw .locationUnavailable("no place") }

    await session.enter()

    #expect(session.isOff)
    #expect(session.failure == .locationUnavailable("no place"))
    #expect(calls.started.isEmpty)
  }
}
