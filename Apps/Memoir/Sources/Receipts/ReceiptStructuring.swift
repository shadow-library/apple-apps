import Foundation
import MemoirCore
import ShadowAI
import ShadowCore

/// What the model read from a receipt's text, checked as the reference checks it; nothing here is saved until the owner confirms the expense form.
nonisolated struct ReceiptReading: Sendable, Equatable {
  /// memoir-server `ocr.service.ts` only marks a reading for review; below this the screen asks the owner to check every value.
  static let reviewBelow = 0.6

  /// The total as the receipt shows it: up to twelve digits and at most two decimals after a full stop.
  let amount: String
  let currency: CurrencyCode?
  let merchant: String?
  let category: CategoryKey?
  let date: LocalDate?
  let confidence: Double

  var needsReview: Bool { confidence < Self.reviewBelow }
}

nonisolated enum ReceiptReadFailure: Error {
  case noText
  case recognition
  case routing(TaskRouterError)
  case model(ModelError)
  /// memoir-server `OCR_002`: the reply was off contract, so nothing is offered rather than a guess.
  case unusable
}

/// memoir-server `SynapseOcrStructuringClient` (`modules/ocr/synapse-structuring.client.ts`): only the text read on this device is sent, never the image.
/// Unlike the reference it asks for the currency and for one of the built-in category keys, and leaves out line items, which an expense does not keep.
nonisolated enum ReceiptStructuring {
  static let consent = AIConsentRequirement(dataClass: "memoir.receipt_text", disclosure: "memoir-receipt-text/v1")
  /// memoir-server `OcrParseDto.extractedText` `maxLength`, in UTF-16 units as JavaScript counts them.
  static let maximumTextLength = 8000
  /// memoir-server `expenses.merchant` is `varchar(200)`, counted in code points as PostgreSQL counts characters.
  static let maximumMerchantLength = 200
  static let schemaName = "memoir_receipt"

  static let system = [
    "You convert the raw text of a shop receipt into structured JSON. You never invent a value that is not in the text.",
    "Reply with JSON only: { \"amount\": string, \"currency\": string | null, \"merchant\": string | null, \"category\": string | null, \"date\": string | null, \"confidence\": number }.",
    "\"amount\" is the final total as it appears, \"currency\" is its ISO 4217 code if the receipt shows one, \"category\" is one of "
      + MoneyBook.builtInCategories.map(\.key).joined(separator: ", ")
      + ", \"date\" is ISO yyyy-mm-dd if one is legible, and \"confidence\" is 0-1.",
    "Use null wherever the receipt does not say, rather than guessing.",
  ].joined(separator: "\n")

  static let schema: JSONValue = [
    "type": "object",
    "properties": [
      "amount": ["type": "string"],
      "currency": ["type": ["string", "null"]],
      "merchant": ["type": ["string", "null"]],
      "category": ["type": ["string", "null"]],
      "date": ["type": ["string", "null"]],
      "confidence": ["type": "number"],
    ],
    "required": ["amount"],
    "additionalProperties": false,
  ]

  static func user(text: String) -> String {
    "Receipt text:\n\(text)"
  }

  /// The text cut to the reference's limit on a character boundary.
  static func bounded(_ text: String) -> String {
    prefix(text, limit: maximumTextLength) { $0.utf16.count }
  }

  private static func prefix(_ text: String, limit: Int, length: (Character) -> Int) -> String {
    var used = 0
    var kept = ""
    for character in text {
      used += length(character)
      guard used <= limit else { break }
      kept.append(character)
    }
    return kept
  }

  static func read(_ text: String, router: TaskRouter) async throws(ReceiptReadFailure) -> ReceiptReading {
    let call: RoutedCall
    do {
      call = try await router.prepare(TaskCall(task: .helper, pace: .swift, consent: consent))
    } catch {
      throw .routing(error)
    }
    let request = call.request(system: [ContextSegment(text: system, endsStablePrefix: true)], messages: [.user(user(text: bounded(text)))])
    let result: StructuredResult
    do {
      result = try await call.structured(request, name: schemaName, schema: schema)
    } catch {
      switch error {
      case .model(let model, _): throw .model(model)
      case .refused, .truncated, .invalid, .decoding: throw .unusable
      }
    }
    return try reading(parsing: result.json)
  }

  /// `toStructuringResult`: an amount off the pattern makes the whole reply unusable; anything else the reply gets wrong is left out.
  static func reading(parsing json: Data) throws(ReceiptReadFailure) -> ReceiptReading {
    guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { throw .unusable }
    guard let amount = (object["amount"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), isAmount(amount) else { throw .unusable }
    let confidence = (object["confidence"] as? NSNumber).map { min(max($0.doubleValue, 0), 1) } ?? 0
    return ReceiptReading(
      amount: amount, currency: text(object["currency"]).flatMap { CurrencyCode($0.uppercased()) },
      merchant: text(object["merchant"]).map { prefix($0, limit: maximumMerchantLength) { $0.unicodeScalars.count } },
      category: text(object["category"]).flatMap { CategoryKey($0.lowercased()) }.flatMap { MoneyBook.builtInCategories.contains($0) ? $0 : nil },
      date: text(object["date"]).flatMap { LocalDate(isoString: $0) }, confidence: confidence.isFinite ? confidence : 0)
  }

  private static func text(_ value: Any?) -> String? {
    guard let value = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    return value
  }

  /// `AMOUNT_PATTERN` (`/^\d{1,12}(\.\d{1,2})?$/`), checked by hand.
  static func isAmount(_ text: String) -> Bool {
    let parts = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    let isDigits = { (part: Substring) in part.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) } }
    guard let whole = parts.first, (1...12).contains(whole.utf8.count), isDigits(whole) else { return false }
    guard parts.count == 2 else { return true }
    return (1...2).contains(parts[1].utf8.count) && isDigits(parts[1])
  }
}
