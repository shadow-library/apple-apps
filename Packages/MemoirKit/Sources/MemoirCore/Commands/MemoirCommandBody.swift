import Foundation
import ShadowCore

/// Where a command's one text goes in its `CommandNoteRecord`, if it has one.
public enum CommandTextSlot: String, Sendable, Hashable {
  case reasonNote = "note"
  case reflection = "reflectionText"
}

/// One typed case per command type. A payload carries ids, dates, closed-set tokens, flags and the integers its kind pins; the owner's words and every
/// measured value stay in the records the command names.
public enum MemoirCommandBody: Sendable, Hashable {
  case questCreate(QuestCreation)
  case questUpdate(QuestUpdate)
  case questDelete(QuestReference)
  case questComplete(Occurrence)
  case questPartial(Occurrence)
  case questSkip(QuestBreak)
  case questPostpone(QuestBreak)
  case questReschedule(QuestReschedule)
  case questAttachReason(QuestReason)
  case questEditLog(QuestLogEdit)
  case questDeleteLog(Occurrence)
  case recoveryComplete(RecoveryCompletion)
  case planSetLock(PlanLock)
  case metricCreate(MetricReference)
  case metricUpdate(MetricReference)
  case metricDelete(MetricDeletion)
  case metricRegister(MetricRegistration)
  case expenseCreate(ExpenseCreation)
  case expenseUpdate(RecordReference)
  case expenseDelete(RecordReference)
  case subscriptionCreate(RecordReference)
  case subscriptionUpdate(RecordReference)
  case subscriptionDelete(RecordReference)
  case subscriptionConfirmCycle(CycleConfirmation)
  case categorySetArchived(CategoryArchival)
  case titleDisplay(TitleDisplay)
  case cosmeticPurchase(CosmeticID)
  case cosmeticEquip(CosmeticID)
  case journalSave(QuickLogEntry)
  case mealLog(QuickLogEntry)
  case mealLogPreset(PresetMealEntry)
  case mealSavePreset(RecordReference)
  case mealPresetUpdate(RecordReference)
  case mealPresetDelete(RecordReference)
  case weightSave(WeightEntry)
  case sideQuestLog(SideQuestEntry)
  case accountSetTimeZone(TimeZoneChange)
  case accountSetIntensityMode(IntensityModeChange)
  case accountSetReturnerThreshold(ReturnerThresholdChange)
  case receiptScan(ReceiptScan)

  public init(_ command: MemoirCommand) throws(CommandRefusal) {
    try self.init(type: command.type, payload: command.payload.members, occurrence: command.occurrence)
  }

  /// Decodes a payload with the reference's checks and the native refusals, refuses any key the kind does not have, then applies the payload's own rules.
  public init(type: CommandType, payload members: [String: JSONValue], occurrence: Occurrence?) throws(CommandRefusal) {
    guard let kind = MemoirCommandKind(type) else { throw .unknownType(type.name) }
    switch (kind.occurrenceUse, occurrence) {
    case (.required, nil): throw .occurrenceRequired(kind)
    case (.none, .some): throw .occurrenceUnexpected(kind)
    default: break
    }
    var reader = PayloadReader(members)
    self = try Self.read(kind, from: &reader, occurrence: occurrence)
    try reader.finish()
    do throws(MemoirCommandError) {
      _ = try CommandPayload(members, type: type)
    } catch {
      throw .payload(error)
    }
  }

  public var kind: MemoirCommandKind {
    switch self {
    case .questCreate: .questCreate
    case .questUpdate: .questUpdate
    case .questDelete: .questDelete
    case .questComplete: .questComplete
    case .questPartial: .questPartial
    case .questSkip: .questSkip
    case .questPostpone: .questPostpone
    case .questReschedule: .questReschedule
    case .questAttachReason: .questAttachReason
    case .questEditLog: .questEditLog
    case .questDeleteLog: .questDeleteLog
    case .recoveryComplete: .recoveryComplete
    case .planSetLock: .planSetLock
    case .metricCreate: .metricCreate
    case .metricUpdate: .metricUpdate
    case .metricDelete: .metricDelete
    case .metricRegister: .metricRegister
    case .expenseCreate: .expenseCreate
    case .expenseUpdate: .expenseUpdate
    case .expenseDelete: .expenseDelete
    case .subscriptionCreate: .subscriptionCreate
    case .subscriptionUpdate: .subscriptionUpdate
    case .subscriptionDelete: .subscriptionDelete
    case .subscriptionConfirmCycle: .subscriptionConfirmCycle
    case .categorySetArchived: .categorySetArchived
    case .titleDisplay: .titleDisplay
    case .cosmeticPurchase: .cosmeticPurchase
    case .cosmeticEquip: .cosmeticEquip
    case .journalSave: .journalSave
    case .mealLog: .mealLog
    case .mealLogPreset: .mealLogPreset
    case .mealSavePreset: .mealSavePreset
    case .mealPresetUpdate: .mealPresetUpdate
    case .mealPresetDelete: .mealPresetDelete
    case .weightSave: .weightSave
    case .sideQuestLog: .sideQuestLog
    case .accountSetTimeZone: .accountSetTimeZone
    case .accountSetIntensityMode: .accountSetIntensityMode
    case .accountSetReturnerThreshold: .accountSetReturnerThreshold
    case .receiptScan: .receiptScan
    }
  }

  public var occurrence: Occurrence? {
    switch self {
    case .questComplete(let occurrence), .questPartial(let occurrence), .questDeleteLog(let occurrence): occurrence
    case .questSkip(let action), .questPostpone(let action): action.occurrence
    case .questReschedule(let action): action.occurrence
    case .questAttachReason(let action): action.occurrence
    case .questEditLog(let action): action.occurrence
    case .metricRegister(let registration): registration.questLog
    default: nil
    }
  }

  /// The slot the command's note record fills, when the payload says a text is attached.
  public var textSlot: CommandTextSlot? {
    switch self {
    case .questSkip(let action), .questPostpone(let action): action.hasNote ? .reasonNote : nil
    case .questReschedule(let action): action.hasNote ? .reasonNote : nil
    case .questAttachReason(let action): action.hasNote ? .reasonNote : nil
    case .questEditLog(let edit): edit.note == .set ? .reasonNote : edit.reflection == .set ? .reflection : nil
    case .recoveryComplete(let completion): completion.hasReflection ? .reflection : nil
    default: nil
    }
  }

  public func payload() throws(CommandRefusal) -> CommandPayload {
    var writer = PayloadWriter()
    write(to: &writer)
    do throws(MemoirCommandError) {
      return try CommandPayload(writer.members, type: kind.commandType)
    } catch {
      throw .payload(error)
    }
  }

  private func write(to writer: inout PayloadWriter) {
    switch self {
    case .questCreate(let creation): creation.write(to: &writer)
    case .questUpdate(let update): update.write(to: &writer)
    case .questDelete(let reference): reference.write(to: &writer)
    case .questComplete, .questPartial, .questDeleteLog: break
    case .questSkip(let action), .questPostpone(let action): action.write(to: &writer)
    case .questReschedule(let action): action.write(to: &writer)
    case .questAttachReason(let action): action.write(to: &writer)
    case .questEditLog(let edit): edit.write(to: &writer)
    case .recoveryComplete(let completion): completion.write(to: &writer)
    case .planSetLock(let lock): lock.write(to: &writer)
    case .metricCreate(let metric), .metricUpdate(let metric): metric.write(to: &writer)
    case .metricDelete(let deletion): deletion.write(to: &writer)
    case .metricRegister(let registration): registration.write(to: &writer)
    case .expenseCreate(let creation): creation.write(to: &writer)
    case .expenseUpdate(let reference), .expenseDelete(let reference), .subscriptionCreate(let reference), .subscriptionUpdate(let reference),
      .subscriptionDelete(let reference), .mealSavePreset(let reference), .mealPresetUpdate(let reference), .mealPresetDelete(let reference):
      reference.write(to: &writer)
    case .subscriptionConfirmCycle(let confirmation): confirmation.write(to: &writer)
    case .categorySetArchived(let archival): archival.write(to: &writer)
    case .titleDisplay(let display): display.write(to: &writer)
    case .cosmeticPurchase(let cosmetic), .cosmeticEquip(let cosmetic): cosmetic.write(to: &writer)
    case .journalSave(let entry), .mealLog(let entry): entry.write(to: &writer)
    case .mealLogPreset(let entry): entry.write(to: &writer)
    case .weightSave(let entry): entry.write(to: &writer)
    case .sideQuestLog(let entry): entry.write(to: &writer)
    case .accountSetTimeZone(let change): change.write(to: &writer)
    case .accountSetIntensityMode(let change): change.write(to: &writer)
    case .accountSetReturnerThreshold(let change): change.write(to: &writer)
    case .receiptScan(let scan): scan.write(to: &writer)
    }
  }

  private static func read(_ kind: MemoirCommandKind, from reader: inout PayloadReader, occurrence: Occurrence?) throws(CommandRefusal) -> MemoirCommandBody {
    func required() throws(CommandRefusal) -> Occurrence {
      guard let occurrence else { throw .occurrenceRequired(kind) }
      return occurrence
    }
    switch kind {
    case .questCreate: return .questCreate(try QuestCreation(reading: &reader))
    case .questUpdate: return .questUpdate(try QuestUpdate(reading: &reader))
    case .questDelete: return .questDelete(try QuestReference(reading: &reader))
    case .questComplete: return .questComplete(try required())
    case .questPartial: return .questPartial(try required())
    case .questSkip: return .questSkip(try QuestBreak(reading: &reader, occurrence: try required()))
    case .questPostpone: return .questPostpone(try QuestBreak(reading: &reader, occurrence: try required()))
    case .questReschedule: return .questReschedule(try QuestReschedule(reading: &reader, occurrence: try required()))
    case .questAttachReason: return .questAttachReason(try QuestReason(reading: &reader, occurrence: try required()))
    case .questEditLog: return .questEditLog(try QuestLogEdit(reading: &reader, occurrence: try required()))
    case .questDeleteLog: return .questDeleteLog(try required())
    case .recoveryComplete: return .recoveryComplete(try RecoveryCompletion(reading: &reader))
    case .planSetLock: return .planSetLock(try PlanLock(reading: &reader))
    case .metricCreate: return .metricCreate(try MetricReference(reading: &reader))
    case .metricUpdate: return .metricUpdate(try MetricReference(reading: &reader))
    case .metricDelete: return .metricDelete(try MetricDeletion(reading: &reader))
    case .metricRegister: return .metricRegister(try MetricRegistration(reading: &reader, occurrence: occurrence))
    case .expenseCreate: return .expenseCreate(try ExpenseCreation(reading: &reader))
    case .expenseUpdate: return .expenseUpdate(try RecordReference(reading: &reader))
    case .expenseDelete: return .expenseDelete(try RecordReference(reading: &reader))
    case .subscriptionCreate: return .subscriptionCreate(try RecordReference(reading: &reader))
    case .subscriptionUpdate: return .subscriptionUpdate(try RecordReference(reading: &reader))
    case .subscriptionDelete: return .subscriptionDelete(try RecordReference(reading: &reader))
    case .subscriptionConfirmCycle: return .subscriptionConfirmCycle(try CycleConfirmation(reading: &reader))
    case .categorySetArchived: return .categorySetArchived(try CategoryArchival(reading: &reader))
    case .titleDisplay: return .titleDisplay(try TitleDisplay(reading: &reader))
    case .cosmeticPurchase: return .cosmeticPurchase(try CosmeticID.read(&reader, forSale: true))
    case .cosmeticEquip: return .cosmeticEquip(try CosmeticID.read(&reader, forSale: false))
    case .journalSave: return .journalSave(try QuickLogEntry(reading: &reader))
    case .mealLog: return .mealLog(try QuickLogEntry(reading: &reader))
    case .mealLogPreset: return .mealLogPreset(try PresetMealEntry(reading: &reader))
    case .mealSavePreset: return .mealSavePreset(try RecordReference(reading: &reader))
    case .mealPresetUpdate: return .mealPresetUpdate(try RecordReference(reading: &reader))
    case .mealPresetDelete: return .mealPresetDelete(try RecordReference(reading: &reader))
    case .weightSave: return .weightSave(try WeightEntry(reading: &reader))
    case .sideQuestLog: return .sideQuestLog(try SideQuestEntry(reading: &reader))
    case .accountSetTimeZone: return .accountSetTimeZone(try TimeZoneChange(reading: &reader))
    case .accountSetIntensityMode: return .accountSetIntensityMode(try IntensityModeChange(reading: &reader))
    case .accountSetReturnerThreshold: return .accountSetReturnerThreshold(try ReturnerThresholdChange(reading: &reader))
    case .receiptScan: return .receiptScan(try ReceiptScan(reading: &reader))
    }
  }
}
