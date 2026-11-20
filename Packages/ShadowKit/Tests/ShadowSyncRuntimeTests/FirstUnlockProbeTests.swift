import Foundation
import ShadowSyncRuntime
import Testing

@Suite("FirstUnlockProbe", TestTimeLimit.quick)
struct FirstUnlockProbeTests {
  @Test("should answer unlocked once it can read or create its protected file")
  func answersUnlocked() throws {
    let directory = try TemporaryDirectory()
    let probe = FirstUnlockProbe(url: FirstUnlockProbe.defaultURL(applicationSupport: directory.url, bundleIdentifier: "com.shadow.apps.test"))

    #expect(probe.hasUnlockedSinceBoot())
    #expect(FileManager.default.fileExists(atPath: probe.url.path(percentEncoded: false)))
    #expect(probe.hasUnlockedSinceBoot())
  }

  @Test("should replace a file it cannot read for another reason")
  func replacesUnreadableFile() throws {
    let directory = try TemporaryDirectory()
    let probe = FirstUnlockProbe(url: directory.url.appending(path: "first-unlock"))
    #expect(probe.hasUnlockedSinceBoot())
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: probe.url.path(percentEncoded: false))

    #expect(probe.hasUnlockedSinceBoot())
  }

  @Test("should answer locked when it can neither read nor create its file")
  func answersLocked() throws {
    let directory = try TemporaryDirectory()
    let parent = directory.url.appending(path: "Sync", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path(percentEncoded: false))
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path(percentEncoded: false)) }

    #expect(!FirstUnlockProbe(url: parent.appending(path: "first-unlock")).hasUnlockedSinceBoot())
  }
}
