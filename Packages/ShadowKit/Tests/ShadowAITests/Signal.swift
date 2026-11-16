struct Signal: Sendable {
  private let stream: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation

  init() {
    (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
  }

  func fire() {
    continuation.yield()
  }

  func wait() async {
    for await _ in stream { return }
  }
}
