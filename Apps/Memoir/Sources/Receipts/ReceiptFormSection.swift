import Foundation
import ImageIO
import MemoirCore
import ShadowAI
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// The expense form's receipt: a photo to add while the expense is first saved, read on request; once saved, only whether it has one.
struct ReceiptFormSection: View {
  let form: ExpenseForm

  var body: some View {
    if let draft = form.receipt {
      ReceiptDraftSection(form: form, draft: draft)
    } else if case .edit(let expense) = form.mode {
      Section {
        LabeledContent {
          expense.receipt == nil ? Text("No receipt", tableName: "Receipts") : Text("Receipt attached", tableName: "Receipts")
        } label: {
          Text("Receipt photo", tableName: "Receipts")
        }
      } footer: {
        Text("A receipt photo can only be added while an expense is first saved.", tableName: "Receipts")
      }
    }
  }
}

private struct ReceiptDraftSection: View {
  let form: ExpenseForm
  @Bindable var draft: ReceiptDraft
  @Environment(AIServices.self) private var services: AIServices?

  var body: some View {
    Section {
      switch draft.photo {
      case .none:
        ReceiptPickers(draft: draft)
      case .preparing:
        HStack(spacing: Spacing.space2) {
          ProgressView()
          Text("Preparing the photo…", tableName: "Receipts").foregroundStyle(ShadowColor.textSecondary)
          Spacer(minLength: Spacing.space2)
          Button {
            draft.remove()
          } label: {
            Text("Cancel", tableName: "Receipts")
          }
          .buttonStyle(.borderless)
        }
      case .ready(let photo):
        ReceiptPhotoRow(photo: photo) { draft.remove() }
        reading
      case .failed(let error):
        ShadowValidationMessage(Text(verbatim: ReceiptCopy.photoIssue(error)))
        Button(role: .destructive) {
          draft.remove()
        } label: {
          Text("Remove Photo", tableName: "Receipts")
        }
      }
    } header: {
      Text("Receipt photo", tableName: "Receipts")
    } footer: {
      Text(
        "The photo is kept with this expense once you save it. Reading it fills the form for you to check — nothing is saved until you do.", tableName: "Receipts")
    }
    .modifier(ReceiptConsentPrompt(draft: draft, services: services))
    if case .read(let reading) = draft.reading {
      ReceiptSuggestionSection(suggestion: form.suggestion(from: reading), form: form) {
        form.use(form.suggestion(from: reading))
        draft.dismissReading()
      } dismiss: {
        draft.dismissReading()
      }
    }
  }

  @ViewBuilder private var reading: some View {
    switch draft.reading {
    case .idle, .read:
      if draft.reader != nil {
        Button {
          Task { await draft.read() }
        } label: {
          Label(title: { Text("Read Receipt", tableName: "Receipts") }, icon: { Image(systemName: "text.viewfinder") })
        }
        .disabled(!draft.canRead)
      }
    case .recognizing:
      progress(Text("Reading the text on this device…", tableName: "Receipts"))
    case .structuring:
      progress(Text("Filling in the details…", tableName: "Receipts"))
    case .failed(let failure):
      ShadowValidationMessage(failure.text)
      Button {
        Task { await draft.read() }
      } label: {
        Text("Try Again", tableName: "Receipts")
      }
      .disabled(!draft.canRead)
    }
  }

  private func progress(_ text: Text) -> some View {
    HStack(spacing: Spacing.space2) {
      ProgressView()
      text.foregroundStyle(ShadowColor.textSecondary)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct ReceiptPhotoRow: View {
  let photo: ReceiptPhoto
  let remove: () -> Void
  @State private var preview: CGImage?

  var body: some View {
    HStack(spacing: Spacing.space3) {
      Group {
        if let preview {
          Image(decorative: preview, scale: 1).resizable().scaledToFill()
        } else {
          Image(systemName: "doc.text.image").foregroundStyle(ShadowColor.textSecondary)
        }
      }
      .frame(width: Spacing.space10, height: Spacing.space10)
      .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Spacing.space05) {
        Text("Receipt photo", tableName: "Receipts").foregroundStyle(ShadowColor.textPrimary)
        Text(verbatim: photo.data.count.formatted(.byteCount(style: .file))).shadowFont(.caption).foregroundStyle(ShadowColor.textSecondary)
      }
      Spacer(minLength: Spacing.space2)
      Button(role: .destructive, action: remove) {
        Label(title: { Text("Remove Photo", tableName: "Receipts") }, icon: { Image(systemName: "trash") }).labelStyle(.iconOnly)
      }
      .buttonStyle(.borderless)
    }
    .task(id: photo.data) { preview = ReceiptImages.decode(photo.data, longestSide: 240) }
  }
}

private struct ReceiptSuggestionSection: View {
  let suggestion: ReceiptSuggestion
  let form: ExpenseForm
  let use: () -> Void
  let dismiss: () -> Void
  @Environment(\.locale) private var locale

  var body: some View {
    Section {
      if suggestion.isEmpty {
        Text("Nothing read from this receipt fits this expense.", tableName: "Receipts").foregroundStyle(ShadowColor.textSecondary)
      }
      if let amount = suggestion.amount {
        row(Text("Amount", tableName: "Receipts"), MoneyText.formatted(amount, locale: locale))
      } else if let currency = suggestion.unusableCurrency {
        Text("The receipt is in \(currency.code), which this expense can’t use, so its total is left out.", tableName: "Receipts")
          .foregroundStyle(ShadowColor.warningText)
      } else {
        Text("The receipt’s total doesn’t fit this expense’s currency, so it is left out.", tableName: "Receipts").foregroundStyle(ShadowColor.warningText)
      }
      if let merchant = suggestion.merchant { row(Text("Merchant", tableName: "Receipts"), merchant) }
      if let date = suggestion.occurredOn { row(Text("Date", tableName: "Receipts"), MoneyDates.text(date, locale: locale)) }
      if let category = suggestion.category { row(Text("Category", tableName: "Receipts"), form.options.name(of: category)) }
      HStack {
        Button(action: dismiss) { Text("Dismiss", tableName: "Receipts") }
        Spacer()
        Button(action: use) { Text("Use These Values", tableName: "Receipts") }
          .buttonStyle(.borderedProminent)
          .disabled(suggestion.isEmpty)
      }
      .buttonStyle(.borderless)
    } header: {
      Text("Receipt review", tableName: "Receipts")
    } footer: {
      suggestion.needsReview
        ? Text("Read from the photo, nothing saved yet. The reading is unsure — check every value before you save.", tableName: "Receipts")
        : Text("Read from the photo, nothing saved yet. Correct anything and save.", tableName: "Receipts")
    }
  }

  private func row(_ label: Text, _ value: String) -> some View {
    LabeledContent {
      HStack(spacing: Spacing.space1) {
        Text(verbatim: value)
        if suggestion.needsReview { ShadowBadge(Text("check", tableName: "Receipts"), intent: .warning) }
      }
    } label: {
      label
    }
  }
}

/// Asks for the receipt-text consent the structuring call is missing, then reads again; without AI services there is no reading to ask for.
private struct ReceiptConsentPrompt: ViewModifier {
  @Bindable var draft: ReceiptDraft
  let services: AIServices?

  func body(content: Content) -> some View {
    if let services, let store = draft.reader?.store {
      content.aiConsentSheet($draft.consentRequest, services: services, store: store) { Task { await draft.read() } }
    } else {
      content
    }
  }
}

/// Images decoded for the screen, shrunk to what it shows.
nonisolated enum ReceiptImages {
  static func decode(_ data: Data, longestSide: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return thumbnail(source, longestSide: longestSide)
  }

  static func decode(contentsOf url: URL, longestSide: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return thumbnail(source, longestSide: longestSide)
  }

  private static func thumbnail(_ source: CGImageSource, longestSide: Int) -> CGImage? {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: longestSide,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }
}
