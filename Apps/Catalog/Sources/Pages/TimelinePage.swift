import ShadowDesignSystem
import SwiftUI

private struct ChapterEvent: Identifiable {
  let id: Int
  let status: ShadowTimelineStatus
  let title: String
  let detail: String
  let time: String
}

private struct AuditEvent: Identifiable {
  let id: Int
  let date: Date
  let status: ShadowTimelineStatus
  let title: String
  let detail: String
  let symbol: String?
}

private let chapterPath = [
  ChapterEvent(id: 1, status: .completed, title: "Chapter planned", detail: "With the author", time: "12 Nov"),
  ChapterEvent(id: 2, status: .completed, title: "Drafted by AI", detail: "3,214 words", time: "13 Nov"),
  ChapterEvent(id: 3, status: .current, title: "In review", detail: "2 comments open", time: "now"),
  ChapterEvent(id: 4, status: .upcoming, title: "Finalized into canon", detail: "", time: "Next"),
]

private let deliveryAttempts = [
  ChapterEvent(id: 11, status: .completed, title: "Queued", detail: "Weekly digest · 2,977 recipients", time: "08:00"),
  ChapterEvent(id: 12, status: .failed, title: "Attempt 1 failed", detail: "Mailbox full for 61 recipients", time: "08:04"),
  ChapterEvent(id: 13, status: .current, title: "Retrying", detail: "Attempt 2 of 3", time: "now"),
]

private let longEvents = [
  ChapterEvent(
    id: 21, status: .completed, title: "Mira Vale approved the revised ending of Chapter 43, “The Glass Stair”, after asking for the lantern scene to move earlier",
    detail: "Comments resolved: the Archivist’s secret name is now revealed one scene later than in the first draft", time: "14 Nov, 09:42"),
  ChapterEvent(
    id: 22, status: .failed, title: "Export to EPUB failed because the cover image was missing a required alt text", detail: "Add a description and try again",
    time: "14 Nov, 09:50"),
]

private let now = Date.catalogNow

private let auditLog = [
  AuditEvent(id: 31, date: now.catalogAgo(minutes: 6), status: .current, title: "Signed in on iPad", detail: "Mira Vale · Edinburgh", symbol: "iphone"),
  AuditEvent(id: 32, date: now.catalogAgo(hours: 2), status: .completed, title: "Password changed", detail: "Mira Vale", symbol: "key"),
  AuditEvent(id: 33, date: now.catalogAgo(hours: 3), status: .failed, title: "Step-up code rejected", detail: "3 attempts · Lagos", symbol: "lock.trianglebadge.exclamationmark"),
  AuditEvent(id: 34, date: now.catalogAgo(hours: 20), status: .completed, title: "Passkey added", detail: "MacBook Pro", symbol: "person.badge.key"),
  AuditEvent(id: 35, date: now.catalogAgo(hours: 26), status: .completed, title: "Signed in on Mac", detail: "Mira Vale · Edinburgh", symbol: nil),
]

private func dayTitle(_ date: Date) -> Text {
  switch ShadowDayBucket(date: date, now: now) {
  case .today: Text("Today")
  case .yesterday: Text("Yesterday")
  case .earlier: Text(date, format: .dateTime.day().month())
  }
}

private struct PathCard: View {
  let events: [ChapterEvent]

  var body: some View {
    ShadowTimeline(events) { event in
      ShadowTimelineItem(
        status: event.status, title: Text(verbatim: event.title), detail: event.detail.isEmpty ? nil : Text(verbatim: event.detail), time: Text(verbatim: event.time),
        statusLabel: label(event.status))
    }
    .shadowCard()
  }

  private func label(_ status: ShadowTimelineStatus) -> Text {
    switch status {
    case .completed: Text("Done")
    case .current: Text("In progress")
    case .upcoming: Text("Not started")
    case .failed: Text("Failed")
    }
  }
}

struct TimelinePage: View {
  var body: some View {
    ComponentPage(component: .timeline) {
      StateSection("Process, oldest first", note: "A 2pt rail joins the steps. Done is success with a check, now is accent, next is an outlined ring. Details sit under the title.")
      {
        PathCard(events: chapterPath)
      }
      StateSection(
        "Failed and ongoing", note: "A failure gets a cross and the destructive label colour, so it never relies on colour alone; the ongoing step names what is happening now."
      ) {
        PathCard(events: deliveryAttempts)
      }
      StateSection("History, newest first, grouped by day", note: "Audit history puts the latest event on top. Events can carry their own symbol; day headers continue the rail.") {
        ShadowTimeline(auditLog.shadowGroupedByDay(date: \.date, order: .newestFirst), dayTitle: dayTitle) { event in
          ShadowTimelineItem(
            status: event.status, title: Text(verbatim: event.title), detail: Text(verbatim: event.detail), time: Text(event.date, format: .dateTime.hour().minute()),
            systemImage: event.symbol)
        }
        .shadowCard()
      }
      StateSection("Long text", note: "Titles and details wrap to as many lines as they need. The rail stays attached to the first line.") {
        PathCard(events: longEvents)
      }
      StateSection("Single event", note: "One event has no rail below it.") {
        PathCard(events: [chapterPath[2]])
      }
      StateSection("With an action", note: "A row can carry extra content, such as a retry button under a failed attempt.") {
        ShadowTimeline(Array(deliveryAttempts.prefix(2))) { event in
          ShadowTimelineItem(status: event.status, title: Text(verbatim: event.title), detail: Text(verbatim: event.detail), time: Text(verbatim: event.time)) {
            if event.status == .failed {
              Button("Retry now") {}
                .buttonStyle(.shadowBordered)
                .controlSize(.small)
                .padding(.top, Spacing.space1)
            }
          }
        }
        .shadowCard()
      }
      StateSection("Light and dark") {
        SchemePair {
          ShadowTimeline(chapterPath + [deliveryAttempts[1]]) { event in
            ShadowTimelineItem(
              status: event.status, title: Text(verbatim: event.title), detail: event.detail.isEmpty ? nil : Text(verbatim: event.detail), time: Text(verbatim: event.time))
          }
        }
      }
      .shadowColumnSpan(.full)
    }
  }
}
