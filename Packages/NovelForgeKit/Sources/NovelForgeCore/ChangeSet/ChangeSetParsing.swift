import ShadowCore
import ShadowText

enum ChangeSetError: ShadowError, Equatable {
  case notAllowedForScope(problems: [String])

  var code: String { "RFN_004" }

  var errorDescription: String? { "Change-set operation not allowed for this scope" }
}

struct ValidatedChangeSet: Sendable, Equatable {
  let ops: [ChangeOp]

  init(_ raw: OrderedJSON, allowedOps: [OpType]? = nil, options: ChangeSetValidationOptions = ChangeSetValidationOptions()) throws(ChangeSetError) {
    let validation = validateChangeSet(raw, allowedOps: allowedOps, options: options)
    guard validation.errors.isEmpty else { throw .notAllowedForScope(problems: validation.errors) }
    guard let records = validation.validatedRecords else { throw .notAllowedForScope(problems: ["a validated operation could not be built"]) }
    let ops = records.compactMap(ChangeOp.init(validated:))
    guard ops.count == records.count else { throw .notAllowedForScope(problems: ["a validated operation could not be built"]) }
    self.ops = ops
  }
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set-validation.ts:208
func parseChangeSet(_ raw: OrderedJSON, allowedOps: [OpType]? = nil, options: ChangeSetValidationOptions = ChangeSetValidationOptions()) throws(ChangeSetError) -> [ChangeOp] {
  try ValidatedChangeSet(raw, allowedOps: allowedOps, options: options).ops
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set-validation.ts:214
func parseOptionalChangeSet(_ raw: OrderedJSON?, allowedOps: [OpType]? = nil, options: ChangeSetValidationOptions = ChangeSetValidationOptions()) throws(ChangeSetError)
  -> [ChangeOp]
{
  guard let raw, !raw.isNull, raw.arrayValue?.isEmpty != true else { return [] }
  return try parseChangeSet(raw, allowedOps: allowedOps, options: options)
}
