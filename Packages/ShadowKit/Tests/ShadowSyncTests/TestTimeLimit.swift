import Testing

enum TestTimeLimit {
  static let quick = TimeLimitTrait.timeLimit(.minutes(5))
  static let standard = TimeLimitTrait.timeLimit(.minutes(10))
}
