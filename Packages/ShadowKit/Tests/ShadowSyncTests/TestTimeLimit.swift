import Testing

enum TestTimeLimit {
  static let quick = TimeLimitTrait.timeLimit(.minutes(5))
}
