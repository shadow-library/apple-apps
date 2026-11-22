import Foundation
import ImageIO
import MemoirCore
import ShadowAI
import ShadowAppShell
import ShadowStore
import ShadowTestSupport
import Testing

@testable import Memoir

@MainActor
@Suite("Receipt reading", TestTimeLimit.standard)
struct ReceiptReadingTests {
  private static let reply = #"{"amount":"214.00","currency":"NOK","merchant":"Rema 1000 Torggata","category":"groceries","date":"2026-03-01","confidence":0.92}"#

  private static func form(_ context: MemoirScreenContext, reader: ReceiptReader?, blobs: FakeReceiptBlobs = FakeReceiptBlobs()) async throws -> ExpenseForm {
    ExpenseForm(
      mode: .create, options: try await MoneyFixture.options(context), context: context, locale: MoneyFixture.english,
      receipt: ReceiptDraft(blobs: blobs.blobs, reader: reader))
  }

  @Test("should read the reference's reply shape and refuse a total off its pattern")
  func parsesReplies() throws {
    let reading = try ReceiptStructuring.reading(parsing: Data(Self.reply.utf8))
    #expect(
      reading
        == ReceiptReading(
          amount: "214.00", currency: MoneyFixture.krone, merchant: "Rema 1000 Torggata", category: CategoryKey("groceries"), date: TestClock.day(-1),
          confidence: 0.92))

    let loose = try ReceiptStructuring.reading(
      parsing: Data(#"{"amount":" 12 ","currency":"euro","merchant":"  ","category":"Snacks","date":"yesterday","confidence":7}"#.utf8))
    #expect(loose == ReceiptReading(amount: "12", currency: nil, merchant: nil, category: nil, date: nil, confidence: 1), "what the reply gets wrong is left out")

    for amount in ["12.345", "1,200.00", "-5", "", "1234567890123", ".5", "12."] {
      #expect(Self.isUnusable(Data(#"{"amount":"\#(amount)"}"#.utf8)), "\(amount) is off the reference's pattern")
    }
    #expect(Self.isUnusable(Data("not json".utf8)))
    #expect(ReceiptStructuring.isAmount("123456789012.99"))
    let long = try ReceiptStructuring.reading(parsing: Data(#"{"amount":"1","merchant":"\#(String(repeating: "é", count: 250))"}"#.utf8))
    #expect(long.merchant?.unicodeScalars.count == ReceiptStructuring.maximumMerchantLength, "the reference's varchar(200)")
  }

  private static func isUnusable(_ reply: Data) -> Bool {
    do {
      _ = try ReceiptStructuring.reading(parsing: reply)
      return false
    } catch {
      guard case .unusable = error else { return false }
      return true
    }
  }

  @Test("should bound the text sent to the reference's 8,000 UTF-16 units without splitting a character")
  func boundsTheText() {
    let text = String(repeating: "a", count: 7_999) + "🧾" + "tail"
    let bounded = ReceiptStructuring.bounded(text)
    #expect(bounded.utf16.count == 7_999)
    #expect(ReceiptStructuring.bounded("short") == "short")
  }

  @Test("should ask for consent before any text leaves the device, then read once it is given, saving nothing")
  func gatesOnConsent() async throws {
    let context = try await MoneyFixture.context()
    let provider = ScriptedModelProvider()
    let form = try await Self.form(context, reader: ReceiptFixture.reader(provider, store: context.stores.main))
    let draft = try #require(form.receipt)
    await draft.take(ReceiptFixture.png(width: 60, height: 120))

    await draft.read()

    let request = try #require(draft.consentRequest)
    #expect(request.dataClass == ReceiptStructuring.consent.dataClass)
    #expect(request.disclosure == ReceiptStructuring.consent.disclosure)
    #expect(provider.requests.isEmpty, "nothing was sent without consent")
    #expect(draft.reading == .idle)
    #expect(ConsentDisclosure(request, among: ConsentDisclosure.memoir) == .memoirReceipts, "the consent sheet has words for it")

    try await ReceiptFixture.grant(context.stores.main)
    provider.enqueueReply(Self.reply)
    await draft.read()

    guard case .read(let reading) = draft.reading else {
      Issue.record("the reading is offered, not \(draft.reading)")
      return
    }
    #expect(reading.amount == "214.00")
    let sent = try #require(provider.requests.first)
    let userText = sent.messages.map(\.text).joined()
    #expect(userText.contains("TOTAL 214.00"), "the recognised text is sent")
    #expect(provider.requests.count == 1)
    #expect(try await MoneyFixture.expenseEntries(context).isEmpty, "a reading saves nothing")
    #expect(try await ReceiptFixture.receipts(context).isEmpty)
    #expect(try await MoneyFixture.bodies(context).isEmpty)
    #expect(form.amountText.isEmpty, "the form is filled only when the owner asks")
  }

  @Test("should fill the form from a reading only when asked, and save it as a scanned receipt")
  func usesTheReading() async throws {
    let context = try await MoneyFixture.context()
    try await ReceiptFixture.grant(context.stores.main)
    let provider = ScriptedModelProvider()
    provider.enqueueReply(Self.reply)
    let blobs = FakeReceiptBlobs()
    let form = try await Self.form(context, reader: ReceiptFixture.reader(provider, store: context.stores.main), blobs: blobs)
    let draft = try #require(form.receipt)
    await draft.take(ReceiptFixture.png(width: 60, height: 120))
    await draft.read()
    guard case .read(let reading) = draft.reading else {
      Issue.record("the reading is offered, not \(draft.reading)")
      return
    }

    let suggestion = form.suggestion(from: reading)
    #expect(suggestion.amount == MoneyAmount(amountMinor: 21_400, currency: MoneyFixture.krone))
    #expect(suggestion.unusableCurrency == nil)
    #expect(suggestion.occurredOn == TestClock.day(-1))
    #expect(suggestion.category == CategoryKey("groceries"))
    #expect(!suggestion.needsReview)
    form.use(suggestion)
    #expect(form.amountText == "214.00")
    #expect(form.currency == MoneyFixture.krone)
    #expect(form.merchant == "Rema 1000 Torggata")
    #expect(form.occurredOn == TestClock.day(-1))
    #expect(try await MoneyFixture.expenseEntries(context).isEmpty, "filling the form saves nothing")

    let id = try #require(await form.save())

    let receipt = try #require(try await ReceiptFixture.receipts(context).first?.record)
    let expense = try #require(try await MoneyFixture.expenseEntries(context).first?.record)
    #expect(expense.id == id && expense.receipt == receipt.id && expense.amountMinor == 21_400 && expense.currency == MoneyFixture.krone)
    #expect(
      try await MoneyFixture.bodies(context) == [.expenseCreate(ExpenseCreation(id: id, source: .ocr)), .receiptScan(ReceiptScan(receiptId: receipt.id))])
  }

  @Test("should leave out what the form cannot take: a future date, an archived or unknown category, decimals the currency lacks")
  func filtersTheSuggestion() async throws {
    let context = try await MoneyFixture.context(enabled: [MoneyFixture.euro, MoneyFixture.yen])
    let form = try await Self.form(context, reader: nil)
    let reading = ReceiptReading(amount: "12.50", currency: MoneyFixture.yen, merchant: nil, category: nil, date: TestClock.day(3), confidence: 0.3)

    let suggestion = form.suggestion(from: reading)

    #expect(suggestion.amount == nil, "the yen has no decimals")
    #expect(suggestion.unusableCurrency == nil, "the yen is offered; only its amount does not fit")
    #expect(suggestion.occurredOn == nil, "the form takes no date after today")
    #expect(suggestion.needsReview)
    #expect(suggestion.isEmpty)
    form.amountText = "1250"
    form.use(suggestion)
    #expect(form.currency == MoneyFixture.euro, "the currency never switches without the amount")
    #expect(form.amountText == "1250" && form.amount == .success(125_000), "the typed euro amount stays as typed")

    let euro = form.suggestion(from: ReceiptReading(amount: "12.50", currency: nil, merchant: nil, category: nil, date: nil, confidence: 1))
    #expect(euro.amount == MoneyAmount(amountMinor: 1250, currency: MoneyFixture.euro), "without a currency the form's own is used")
    #expect(!euro.needsReview)

    let won = try #require(CurrencyCode("KRW"))
    let foreign = form.suggestion(from: ReceiptReading(amount: "15000", currency: won, merchant: "Olive Young", category: nil, date: nil, confidence: 0.95))
    #expect(foreign.amount == nil, "a total in a currency the form does not offer is never read in the form's own")
    #expect(foreign.unusableCurrency == won)
    #expect(foreign.needsReview, "the owner is asked to check")
    form.use(foreign)
    #expect(form.currency == MoneyFixture.euro && form.amountText == "1250")
    #expect(form.merchant == "Olive Young")
  }

  @Test("should send nothing when no text is found, and drop a reading once the photo goes")
  func handlesEmptyTextAndRemoval() async throws {
    let context = try await MoneyFixture.context()
    try await ReceiptFixture.grant(context.stores.main)
    let provider = ScriptedModelProvider()
    let form = try await Self.form(context, reader: ReceiptFixture.reader(provider, store: context.stores.main, text: ""))
    let draft = try #require(form.receipt)
    await draft.take(ReceiptFixture.png(width: 60, height: 120))

    await draft.read()

    guard case .failed = draft.reading else {
      Issue.record("no text is a failure to show, not \(draft.reading)")
      return
    }
    #expect(provider.requests.isEmpty)
    draft.remove()
    #expect(draft.reading == .idle && !draft.hasPhoto && draft.attachment == nil)
  }

  @Test("should show the reference's unavailable copy when the reply is off contract")
  func refusesAnOffContractReply() async throws {
    let context = try await MoneyFixture.context()
    try await ReceiptFixture.grant(context.stores.main)
    let provider = ScriptedModelProvider()
    provider.enqueueReply(#"{"amount":"about twelve"}"#)
    let form = try await Self.form(context, reader: ReceiptFixture.reader(provider, store: context.stores.main))
    let draft = try #require(form.receipt)
    await draft.take(ReceiptFixture.png(width: 60, height: 120))

    await draft.read()

    #expect(draft.reading == .failed(ReceiptCopy.presented(.unusable)))
    #expect(!draft.isScanUsed)
  }

  @Test("should block saving while the photo is prepared or unusable, and save a typed expense once it is removed")
  func blocksSaveOnABadPhoto() async throws {
    let context = try await MoneyFixture.context()
    let form = try await Self.form(context, reader: nil)
    let draft = try #require(form.receipt)
    form.amountText = "12"
    #expect(form.canSave)

    await draft.take(Data("not an image".utf8))

    #expect(draft.photo == .failed(.unreadable))
    #expect(!form.canSave)
    #expect(form.hasChanges)
    draft.remove()
    #expect(form.canSave)
    let id = try #require(await form.save())
    #expect(try await MoneyFixture.expenseEntries(context).map(\.record.id) == [id])
    #expect(try await ReceiptFixture.receipts(context).isEmpty)
  }

  @Test("should show a pick as being prepared while it loads, and drop a slow earlier pick that lands after a newer one")
  func dropsStalePicks() async throws {
    let context = try await MoneyFixture.context()
    let form = try await Self.form(context, reader: nil)
    let draft = try #require(form.receipt)

    let slow = draft.startPick()
    #expect(draft.photo == .preparing)
    #expect(!form.canSave && draft.blocksSave)
    let quick = draft.startPick()
    await draft.take(ReceiptFixture.png(width: 60, height: 120), pick: quick)
    await draft.take(ReceiptFixture.png(width: 300, height: 100), pick: slow)
    draft.refuse(.unreadable, pick: slow)

    guard case .ready(let photo) = draft.photo else {
      Issue.record("the newer pick is kept, not \(draft.photo)")
      return
    }
    #expect(photo.pixelWidth == 60 && photo.pixelHeight == 120)

    let removed = draft.startPick()
    draft.remove()
    await draft.take(ReceiptFixture.png(width: 60, height: 120), pick: removed)
    #expect(draft.photo == .none, "a pick that lands after the photo was removed is dropped")
  }

  @Test("should unblock saving when a photo still loading is cancelled, and drop the load when it lands")
  func cancelsAPreparingPhoto() async throws {
    let context = try await MoneyFixture.context()
    let form = try await Self.form(context, reader: nil)
    let draft = try #require(form.receipt)
    form.amountText = "12"
    let pick = draft.startPick()
    #expect(!form.canSave, "a loading photo holds the form")

    draft.remove()

    #expect(form.canSave)
    await draft.take(ReceiptFixture.png(width: 60, height: 120), pick: pick)
    draft.refuse(.unreadable, pick: pick)
    #expect(draft.photo == .none)
    let id = try #require(await form.save())
    #expect(try await MoneyFixture.expenseEntries(context).map(\.record.id) == [id])
    #expect(try await ReceiptFixture.receipts(context).isEmpty, "the late load saved no receipt")
  }

  @Test("should offer no receipt when editing, as a saved expense's receipt is fixed")
  func offersNoReceiptWhenEditing() async throws {
    let context = try await MoneyFixture.context()
    let expense = try await MoneyFixture.expense(context, 500)
    let form = ExpenseForm(
      mode: .edit(expense), options: try await MoneyFixture.options(context), context: context, locale: MoneyFixture.english,
      receipt: ReceiptDraft(blobs: FakeReceiptBlobs().blobs, reader: nil))
    #expect(form.receipt == nil)
  }

  @Test("should drop a photo's location and camera metadata and turn it upright")
  func stripsMetadata() throws {
    let source = ReceiptFixture.jpeg(
      width: 800, height: 400,
      properties: [
        kCGImagePropertyOrientation: 6, kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 59.91, kCGImagePropertyGPSLatitudeRef: "N"],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Quokka street"], kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Zebracam"],
      ])
    #expect(ReceiptFixture.properties(of: source)[kCGImagePropertyGPSDictionary as String] != nil, "the source carries a location")

    let photo = try ReceiptPhoto.normalised(source)

    let kept = ReceiptFixture.properties(of: photo.data)
    #expect(kept[kCGImagePropertyGPSDictionary as String] == nil)
    #expect(kept[kCGImagePropertyTIFFDictionary as String] == nil)
    #expect(kept[kCGImagePropertyOrientation as String] == nil, "upright, so no orientation is left to apply")
    let exif = kept[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
    #expect(
      Set(exif.keys).isSubset(of: [kCGImagePropertyExifColorSpace as String, kCGImagePropertyExifPixelXDimension as String, kCGImagePropertyExifPixelYDimension as String]),
      "only what the JPEG encoder writes itself, never the source's Exif")
    #expect(photo.pixelWidth == 400 && photo.pixelHeight == 800, "orientation 6 turns the stored landscape upright")
  }

  @Test("should keep a photo upright, JPEG, no longer than the limit, and refuse what is not an image")
  func normalisesPhotos() throws {
    let photo = try ReceiptPhoto.normalised(ReceiptFixture.png(width: 800, height: 1_600), longestSide: 400)
    #expect(photo.pixelWidth == 200 && photo.pixelHeight == 400)
    #expect(photo.data.prefix(2) == Data([0xFF, 0xD8]), "a JPEG")
    #expect(throws: ReceiptPhotoError.unreadable) { try ReceiptPhoto.normalised(Data("plain text".utf8)) }
    #expect(throws: ReceiptPhotoError.unreadable) { try ReceiptPhoto.normalised(Data()) }
    #expect(throws: ReceiptPhotoError.tooLarge) { try ReceiptPhoto.normalised(ReceiptFixture.png(width: 400, height: 400), maximumBytes: 10) }
  }
}
