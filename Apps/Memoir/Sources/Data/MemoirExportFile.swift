import Foundation
import ShadowCore

/// `memoir-export.json`, version 1: every entity of the three stores as stored, so amounts stay integer minor units and measurements stay decimal
/// strings, beside the receipt images this device holds. Modelled on memoir-server's export manifest (`export-assembler.service.ts`), whose
/// `tables` become one section per store and kind; the command log is included, since here it is the history the hero is worked out from.
nonisolated struct MemoirExportFile: Codable, Equatable, Sendable {
  static let format = "com.shadow.apps.memoir.export"
  static let currentVersion = 1
  static let fileName = "memoir-export.json"
  static let receiptsFolder = "receipts"

  /// Sync's own bookkeeping (device directory, key floors, sealed key copies), which holds none of the owner's records.
  static let excludedKindPrefix = "_"

  let format: String
  let version: Int
  /// ISO 8601 in UTC, with milliseconds.
  let generatedAt: String
  let appVersion: String
  let stores: [Store]
  let receiptImages: [ReceiptImage]
  /// What this device keeps for itself and never syncs.
  let local: Local
  /// Recomputed by this build when the export was made; not a record, and never read back.
  let derived: Derived?

  struct Store: Codable, Equatable, Sendable {
    /// `main`, `activity` or `health`: the classes of data the store holds besides general ones.
    let name: String
    let registryVersion: Int
    let kinds: [Kind]
  }

  struct Kind: Codable, Equatable, Sendable {
    let kind: String
    /// `general`, `activity` or `health`.
    let syncClass: String
    /// `record`, `appended` (the command log and edit histories) or `revisioned` (journal entries, with their kept revisions).
    let shape: String
    let entries: [Entry]
  }

  /// A record's merged fields, an appended item, or a revisioned entity's fields with its kept revisions; a removed record keeps `removed: true`.
  struct Entry: Codable, Equatable, Sendable {
    let key: String
    var fields: [String: JSONValue]?
    var item: [String: JSONValue]?
    var head: String?
    var revisions: [Revision]?
  }

  struct Revision: Codable, Equatable, Sendable {
    let id: String
    let parent: String?
    let generation: Int64
    let body: JSONValue
  }

  /// `file` is the image's path inside the archive, or nil when its blob is not on this device.
  struct ReceiptImage: Codable, Equatable, Sendable {
    let receipt: String
    let blob: String
    let contentType: String
    let byteCount: Int
    let file: String?
  }

  struct Local: Codable, Equatable, Sendable {
    let weeklyReviews: [WeeklyReview]
  }

  /// `answers` by prompt (`better`, `change`, `carry`); `week` is the review week's first day, `yyyy-MM-dd`.
  struct WeeklyReview: Codable, Equatable, Sendable {
    let week: String
    let answers: [String: String]
    let completedAtMillis: Int64?
  }

  struct Derived: Codable, Equatable, Sendable {
    let note: String
    let level: Int
    let totalXP: Int
    let coins: Int
  }
}
