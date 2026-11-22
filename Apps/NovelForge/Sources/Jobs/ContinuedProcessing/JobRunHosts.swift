import ShadowAppShell

enum JobRunHosts {
  /// Continued processing on iPhone and iPad; on the Mac a run goes on while the app runs, so the foreground host is enough.
  static func system() -> any JobRunHost {
    #if os(iOS)
      ContinuedProcessingHost(scheduler: SystemContinuedProcessingScheduler.shared)
    #else
      ForegroundRunHost()
    #endif
  }
}
