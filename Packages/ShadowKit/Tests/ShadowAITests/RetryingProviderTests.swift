import Foundation
import ShadowTestSupport
import Testing

@testable import ShadowAI

@Suite("RetryingProvider", TestTimeLimit.quick)
struct RetryingProviderTests {
  private static let request = ModelRequest(model: "m", system: [], messages: [.user("Hi")], maxOutputTokens: 64)
  private static let policy = RetryPolicy(maxAttempts: 4, baseDelay: .seconds(1), maxDelay: .seconds(60), jitter: 0.2)
  private static let started = ModelEvent.started(requestID: "req_ok", generationID: nil)
  private static let finished = ModelEvent.finished(usage: TokenUsage(input: 10, output: 5), reportedCost: nil, stop: .endTurn)

  private static func retrying(
    _ base: ScriptedModelProvider,
    clock: ManualClock = ManualClock(.advancesOnSleep)
  ) -> RetryingProvider<ScriptedModelProvider, ManualClock> {
    RetryingProvider(base, policy: policy, clock: clock, random: { 0 })
  }

  private static func drain(_ stream: ModelStream) async -> (events: [ModelEvent], error: ModelError?) {
    var events: [ModelEvent] = []
    do throws(ModelError) {
      for try await event in stream { events.append(event) }
      return (events, nil)
    } catch {
      return (events, error)
    }
  }

  @Test(
    "should retry each retryable error and announce the computed delay",
    arguments: [ModelError.rateLimited(retryAfter: nil), .overloaded(retryAfter: nil), .server(status: 502), .transport(.networkConnectionLost)]
  )
  func retriesRetryableErrors(cause: ModelError) async {
    let base = ScriptedModelProvider(calls: [
      [.event(.started(requestID: "req_lost", generationID: "gen_lost")), .failure(cause)],
      [.failure(cause)],
      ScriptedModelProvider.reply("Hi there", requestID: "req_ok"),
    ])
    let clock = ManualClock(.advancesOnSleep)

    let outcome = await Self.drain(Self.retrying(base, clock: clock).stream(Self.request))

    #expect(outcome.error == nil)
    #expect(
      outcome.events == [
        .retrying(attempt: 1, delay: .seconds(1), cause: cause, requestID: "req_lost", generationID: "gen_lost"),
        .retrying(attempt: 2, delay: .seconds(2), cause: cause, requestID: nil, generationID: nil), Self.started, .textDelta("Hi"), .textDelta(" there"), Self.finished,
      ]
    )
    #expect(clock.requestedSleeps == [.seconds(1), .seconds(2)])
    #expect(base.requests == [Self.request, Self.request, Self.request])
  }

  @Test("should honour a retry-after longer than the backoff")
  func honoursRetryAfter() async throws {
    let base = ScriptedModelProvider(calls: [[.failure(.rateLimited(retryAfter: .seconds(30)))], ScriptedModelProvider.reply("ok")])
    let clock = ManualClock(.advancesOnSleep)

    let outcome = await Self.drain(Self.retrying(base, clock: clock).stream(Self.request))

    #expect(outcome.events.first == .retrying(attempt: 1, delay: .seconds(30), cause: .rateLimited(retryAfter: .seconds(30)), requestID: nil, generationID: nil))
    #expect(clock.requestedSleeps == [.seconds(30)])
    #expect(outcome.error == nil)
  }

  @Test("should retry an overload raised after started but before any text, honouring its retry-after")
  func retriesOverloadAfterStarted() async {
    let overloaded = ModelError.overloaded(retryAfter: .seconds(20))
    let base = ScriptedModelProvider(calls: [
      [.event(.started(requestID: "req_1", generationID: "gen_1")), .failure(overloaded)],
      ScriptedModelProvider.reply("Recovered", requestID: "req_ok"),
    ])
    let clock = ManualClock(.advancesOnSleep)

    let outcome = await Self.drain(Self.retrying(base, clock: clock).stream(Self.request))

    #expect(outcome.error == nil)
    #expect(
      outcome.events == [
        .retrying(attempt: 1, delay: .seconds(20), cause: overloaded, requestID: "req_1", generationID: "gen_1"), Self.started, .textDelta("Recovered"), Self.finished,
      ]
    )
    #expect(clock.requestedSleeps == [.seconds(20)])
  }

  @Test("should never reach the base provider for a stream that is built and dropped")
  func staysIdleUntilIterated() async throws {
    let base = ScriptedModelProvider(calls: [ScriptedModelProvider.reply("unused")])
    let provider = Self.retrying(base)

    _ = provider.stream(Self.request)
    let unused = provider.stream(Self.request)
    _ = unused.makeAsyncIterator()
    try await Task.sleep(for: .milliseconds(50))

    #expect(base.requests.isEmpty)
    #expect(base.remainingCalls == 1)
    #expect(try await unused.collect().text == "unused")
    #expect(base.requests.count == 1)
  }

  @Test("should give up after the last attempt with the last error")
  func stopsAtMaxAttempts() async {
    let base = ScriptedModelProvider(calls: [
      [.failure(.overloaded(retryAfter: nil))], [.failure(.overloaded(retryAfter: nil))], [.failure(.server(status: 500))], [.failure(.server(status: 503))],
      [.failure(.overloaded(retryAfter: nil))],
    ])
    let clock = ManualClock(.advancesOnSleep)

    let outcome = await Self.drain(Self.retrying(base, clock: clock).stream(Self.request))

    #expect(outcome.error == .server(status: 503))
    #expect(outcome.events.map(Self.attempt) == [1, 2, 3])
    #expect(outcome.events.count == 3)
    #expect(base.requests.count == 4)
    #expect(base.remainingCalls == 1)
  }

  @Test("should pass an error through once text has been delivered")
  func neverRetriesAfterText() async {
    let base = ScriptedModelProvider(calls: [
      [.event(Self.started), .text("Half a"), .failure(.overloaded(retryAfter: nil))],
      ScriptedModelProvider.reply("unused"),
    ])

    let outcome = await Self.drain(Self.retrying(base).stream(Self.request))

    #expect(outcome.events == [Self.started, .textDelta("Half"), .textDelta(" a")])
    #expect(outcome.error == .overloaded(retryAfter: nil))
    #expect(base.requests.count == 1)
  }

  @Test("should pass an error through after a finished event")
  func neverRetriesAfterFinish() async {
    let base = ScriptedModelProvider(calls: [[.event(Self.started), .event(Self.finished), .failure(.overloaded(retryAfter: nil))], ScriptedModelProvider.reply("unused")])

    let outcome = await Self.drain(Self.retrying(base).stream(Self.request))

    #expect(outcome.events == [Self.started, Self.finished])
    #expect(outcome.error == .overloaded(retryAfter: nil))
    #expect(base.requests.count == 1)
  }

  @Test(
    "should pass a non-retryable error through at once",
    arguments: [ModelError.authentication, .invalidRequest("bad"), .midStream(code: "x", message: "y"), .insufficientCredits, .server(status: 501)]
  )
  func neverRetriesPermanentErrors(cause: ModelError) async {
    let base = ScriptedModelProvider(calls: [[.event(Self.started), .failure(cause)], ScriptedModelProvider.reply("unused")])
    let clock = ManualClock(.advancesOnSleep)

    let outcome = await Self.drain(Self.retrying(base, clock: clock).stream(Self.request))

    #expect(outcome.events == [Self.started])
    #expect(outcome.error == cause)
    #expect(base.requests.count == 1)
    #expect(clock.requestedSleeps.isEmpty)
  }

  @Test("should deliver nothing extra when a non-retryable error comes before started")
  func passesEarlyPermanentErrorAlone() async {
    let base = ScriptedModelProvider(calls: [[.failure(.authentication)], ScriptedModelProvider.reply("unused")])

    let outcome = await Self.drain(Self.retrying(base).stream(Self.request))

    #expect(outcome.events.isEmpty)
    #expect(outcome.error == .authentication)
  }

  @Test("should report the last attempt's ids on started and earlier attempts' ids only on retrying")
  func reportsIdsOfExhaustedAttempts() async {
    let overloaded = ModelError.overloaded(retryAfter: nil)
    let base = ScriptedModelProvider(calls: [
      [.event(.started(requestID: "req_1", generationID: "gen_1")), .failure(overloaded)],
      [.failure(overloaded)],
      [.event(.started(requestID: "req_3", generationID: "gen_3")), .failure(overloaded)],
      [.event(.started(requestID: "req_4", generationID: "gen_4")), .failure(overloaded)],
      ScriptedModelProvider.reply("unused"),
    ])

    let outcome = await Self.drain(Self.retrying(base).stream(Self.request))

    #expect(
      outcome.events == [
        .retrying(attempt: 1, delay: .seconds(1), cause: overloaded, requestID: "req_1", generationID: "gen_1"),
        .retrying(attempt: 2, delay: .seconds(2), cause: overloaded, requestID: nil, generationID: nil),
        .retrying(attempt: 3, delay: .seconds(4), cause: overloaded, requestID: "req_3", generationID: "gen_3"),
        .started(requestID: "req_4", generationID: "gen_4"),
      ]
    )
    #expect(outcome.error == overloaded)
    #expect(base.requests.count == 4)
  }

  @Test("should deliver started of an attempt that ends without finishing")
  func releasesStartedWhenAttemptEndsEarly() async {
    let base = ScriptedModelProvider(calls: [[.event(Self.started)], ScriptedModelProvider.reply("unused")])

    let outcome = await Self.drain(Self.retrying(base).stream(Self.request))

    #expect(outcome.events == [Self.started])
    #expect(outcome.error == nil)
    #expect(base.requests.count == 1)
  }

  @Test("should wait on the clock before the next attempt")
  func waitsOnClock() async throws {
    let base = ScriptedModelProvider(calls: [[.failure(.overloaded(retryAfter: nil))], ScriptedModelProvider.reply("ok")])
    let clock = ManualClock(.manual)
    let stream = Self.retrying(base, clock: clock).stream(Self.request)
    let consumer = Task { await Self.drain(stream) }

    await clock.waitForSleepers()
    #expect(base.requests.count == 1)
    clock.advance(by: .seconds(1))

    let outcome = await consumer.value
    #expect(outcome.error == nil)
    #expect(outcome.events.last == Self.finished)
    #expect(base.requests.count == 2)
  }

  @Test("should end with cancelled when cancelled during a wait")
  func cancelsDuringWait() async {
    let base = ScriptedModelProvider(calls: [[.failure(.overloaded(retryAfter: nil))], ScriptedModelProvider.reply("unused")])
    let clock = ManualClock(.manual)
    let stream = Self.retrying(base, clock: clock).stream(Self.request)
    let consumer = Task { await Self.drain(stream) }

    await clock.waitForSleepers()
    consumer.cancel()

    let outcome = await consumer.value
    #expect(outcome.events == [.retrying(attempt: 1, delay: .seconds(1), cause: .overloaded(retryAfter: nil), requestID: nil, generationID: nil)])
    #expect(outcome.error == .cancelled)
    #expect(base.requests.count == 1)
  }

  @Test("should retry validate without events")
  func retriesValidate() async throws {
    let base = ScriptedModelProvider(validations: [.failure(.overloaded(retryAfter: nil)), .failure(.transport(.timedOut)), .success(.valid(label: "Personal"))])
    let clock = ManualClock(.advancesOnSleep)
    let credential = try makeCredential()

    let status = try await Self.retrying(base, clock: clock).validate(credential)

    #expect(status == .valid(label: "Personal"))
    #expect(base.validatedCredentials.count == 3)
    #expect(clock.requestedSleeps == [.seconds(1), .seconds(2)])
  }

  @Test("should retry models and pass a permanent error through")
  func retriesModels() async throws {
    let models = [RemoteModel(id: "claude-sonnet", contextLength: 200_000)]
    let base = ScriptedModelProvider(modelLists: [.failure(.rateLimited(retryAfter: .seconds(9))), .success(models), .failure(.authentication), .success([])])
    let clock = ManualClock(.advancesOnSleep)
    let provider = Self.retrying(base, clock: clock)

    #expect(try await provider.models() == models)
    await #expect(throws: ModelError.authentication) { try await provider.models() }
    #expect(base.modelsCallCount == 3)
    #expect(clock.requestedSleeps == [.seconds(9)])
  }

  @Test("should give up on validate after the last attempt")
  func stopsValidateAtMaxAttempts() async throws {
    let base = ScriptedModelProvider(validations: Array(repeating: .failure(.overloaded(retryAfter: nil)), count: 6))
    let credential = try makeCredential()

    await #expect(throws: ModelError.overloaded(retryAfter: nil)) { try await Self.retrying(base).validate(credential) }
    #expect(base.validatedCredentials.count == 4)
  }

  @Test("should end validate with cancelled when cancelled during a wait")
  func cancelsValidateDuringWait() async throws {
    let base = ScriptedModelProvider(validations: [.failure(.overloaded(retryAfter: nil)), .success(.invalid)])
    let clock = ManualClock(.manual)
    let provider = Self.retrying(base, clock: clock)
    let credential = try makeCredential()
    let task = Task { () async -> Result<CredentialStatus, ModelError> in
      do throws(ModelError) { return .success(try await provider.validate(credential)) } catch { return .failure(error) }
    }

    await clock.waitForSleepers()
    task.cancel()

    #expect(await task.value == .failure(.cancelled))
    #expect(base.validatedCredentials.count == 1)
  }

  private static func attempt(of event: ModelEvent) -> Int? {
    guard case .retrying(let attempt, _, _, _, _) = event else { return nil }
    return attempt
  }
}

@Suite("RetryPolicy")
struct RetryPolicyTests {
  private static let policy = RetryPolicy()

  @Test("should default to five attempts from one second up to a minute with a fifth of jitter")
  func hasDefaults() {
    #expect(Self.policy == RetryPolicy(maxAttempts: 5, baseDelay: .seconds(1), maxDelay: .seconds(60), jitter: 0.2))
  }

  @Test(
    "should double the delay per attempt up to the cap",
    arguments: [(1, Duration.seconds(1)), (2, .seconds(2)), (3, .seconds(4)), (6, .seconds(32)), (7, .seconds(60)), (40, .seconds(60)), (10_000, .seconds(60)), (0, .seconds(1))]
  )
  func growsAndCaps(attempt: Int, expected: Duration) {
    #expect(Self.policy.delay(forAttempt: attempt, retryAfter: nil, random: 0) == expected)
  }

  @Test(
    "should shorten the delay by at most the jitter fraction",
    arguments: [(0.0, Duration.seconds(8)), (0.5, .milliseconds(7_200)), (1.0, .milliseconds(6_400)), (7.0, .milliseconds(6_400)), (-1.0, .seconds(8))])
  func boundsJitter(random: Double, expected: Duration) {
    #expect(Self.policy.delay(forAttempt: 4, retryAfter: nil, random: random) == expected)
  }

  @Test("should keep every jittered delay within its bounds")
  func keepsJitterWithinBounds() {
    for attempt in 1...8 {
      let full = Self.policy.delay(forAttempt: attempt, retryAfter: nil, random: 0)
      for step in 0..<100 {
        let delay = Self.policy.delay(forAttempt: attempt, retryAfter: nil, random: Double(step) / 100)
        #expect(delay <= full && delay >= full * 0.8)
      }
    }
  }

  @Test(
    "should let a longer retry-after win, capped at ten minutes",
    arguments: [
      (Duration.seconds(30), 1, Duration.seconds(30)),
      (.seconds(1), 3, .seconds(4)),
      (.zero, 1, .seconds(1)),
      (.seconds(-5), 1, .seconds(1)),
      (.seconds(120), 7, .seconds(120)),
      (.seconds(3_600), 1, .seconds(600)),
    ]
  )
  func honoursRetryAfter(retryAfter: Duration, attempt: Int, expected: Duration) {
    #expect(Self.policy.delay(forAttempt: attempt, retryAfter: retryAfter, random: 0) == expected)
  }

  @Test("should not jitter a provider's retry-after")
  func keepsRetryAfterExact() {
    #expect(Self.policy.delay(forAttempt: 1, retryAfter: .seconds(10), random: 0.99) == .seconds(10))
  }
}
