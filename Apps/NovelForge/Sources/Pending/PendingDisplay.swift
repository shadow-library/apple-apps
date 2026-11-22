import Foundation
import NovelForgeCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

enum PendingDisplay {
  static func chapter(_ item: PendingItem) -> String {
    guard let chapter = item.chapter else { return "" }
    guard let heading = item.heading else { return String(localized: "Chapter \(chapter)", table: "Pending") }
    return String(localized: "Chapter \(chapter): \(heading)", table: "Pending")
  }

  @ViewBuilder
  static func chip(_ item: PendingItem) -> some View {
    switch item.kind {
    case .chat(let chat): ChatTrayText.chip(chat.kind)
    case .review(_, let contradiction):
      let chip = JobDisplay.chip(contradiction ? .contradiction : .needsReview)
      ShadowBadge(Text(verbatim: chip.label), intent: chip.intent, systemImage: chip.systemImage)
    case .finalize: ShadowBadge(Text("Story Bible", tableName: "Pending"), intent: .accent, systemImage: "books.vertical")
    case .job(let job):
      switch job.line.state {
      case .interrupted: ShadowBadge(Text("Stopped", tableName: "Pending"), intent: .warning)
      case .waitingForConsent: ShadowBadge(Text("Permission", tableName: "Pending"), intent: .warning)
      case .failed: ShadowBadge(Text("Failed", tableName: "Pending"), intent: .danger)
      case .queued, .runningHere, .resumingHere, .runningOnAnotherDevice, .runningInAnotherCopy, .startedOnThisDevice:
        ShadowBadge(Text("Queued", tableName: "Pending"), intent: .neutral, systemImage: "clock")
      }
    }
  }

  static func title(_ item: PendingItem) -> Text {
    switch item.kind {
    case .chat(let chat): Text(verbatim: ChatTrayText.title(chat))
    case .review, .finalize: Text(verbatim: chapter(item))
    case .job(let job): Text("\(JobDisplay.title(job.line)) · \(chapter(item))", tableName: "Pending")
    }
  }

  static func subtitle(_ item: PendingItem, chats: ChatNovelModel?, here: UUID?, now: Date) -> String {
    switch item.kind {
    case .chat(let chat): chats.map { ChatTrayText.source(of: chat, here: here, chats: $0) } ?? ""
    case .review(_, false): String(localized: "Read the draft, then approve it or ask for changes.", table: "Pending")
    case .review(_, true): String(localized: "A review found a conflict with your story. Check it before you approve.", table: "Pending")
    case .finalize(_, let open) where open > 0: String(localized: "\(open) Story Bible updates need your call before it becomes final.", table: "Pending")
    case .finalize: String(localized: "Its Story Bible updates are answered. Finalize it when you're ready.", table: "Pending")
    case .job(let job): JobDisplay.summary(job.line, now: now)
    }
  }

  static func detail(_ item: PendingItem) -> PresentedError? {
    guard case .chat(let chat) = item.kind, let detail = ChatTrayText.detail(chat.kind) else { return nil }
    return PresentedError(headline: detail, detail: ChatTrayText.code(chat.kind))
  }

  /// The few words the collapsed tray joins.
  static func short(_ item: PendingItem) -> String {
    switch item.kind {
    case .chat(let chat): ChatTrayText.short(chat)
    case .review(_, false): String(localized: "draft to review", table: "Pending")
    case .review(_, true): String(localized: "conflict to check", table: "Pending")
    case .finalize: String(localized: "Story Bible updates", table: "Pending")
    case .job(let job):
      if case .failed = job.line.state { String(localized: "failed job", table: "Pending") } else { String(localized: "waiting job", table: "Pending") }
    }
  }

  /// The buttons a job's row offers in place; Cancel sits in the row's menu.
  static func actions(_ job: PendingJob) -> [ChapterJobLine.Action] {
    job.line.actions.filter { $0 != .cancel }
  }

  static func label(_ action: ChapterJobLine.Action) -> Text {
    switch action {
    case .runHere: JobDisplay.runHere
    case .resume: JobDisplay.resume
    case .tryAgain: Text("Try Again", tableName: "Pending")
    case .retryRead: Text("Read Again", tableName: "Pending")
    case .allow: Text("Review Permission…", tableName: "Pending")
    case .cancel: Text("Cancel Job", tableName: "Pending")
    }
  }
}
