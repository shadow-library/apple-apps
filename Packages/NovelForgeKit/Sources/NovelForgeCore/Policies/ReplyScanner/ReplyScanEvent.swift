enum ReplyScanEvent: Equatable, Sendable {
  case reply(String)
  case element(ChangeSetElement)
}

enum ReplyScanState: Equatable, Sendable {
  case awaitingReply
  case replyFound
  case completed
}
