import ShadowCore

enum ChangeSetError: ShadowError, Equatable {
  case notAllowedForScope(problems: [String])

  var code: String { "RFN_004" }

  var errorDescription: String? { "Change-set operation not allowed for this scope" }
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set-validation.ts:208
func parseChangeSet(_ raw: OrderedJSON, allowedOps: [OpType]? = nil, options: ChangeSetValidationOptions = ChangeSetValidationOptions()) throws(ChangeSetError) -> [ChangeOp] {
  let validation = validateChangeSet(raw, allowedOps: allowedOps, options: options)
  guard validation.errors.isEmpty, case .array(let items) = validation.value else { throw .notAllowedForScope(problems: validation.errors) }
  let ops = items.compactMap { $0.objectValue.flatMap(ChangeOp.init(validated:)) }
  guard ops.count == items.count else { throw .notAllowedForScope(problems: ["a validated operation could not be built"]) }
  return ops
}

// apps/novel-forge-server/src/modules/refinement/change-set/change-set-validation.ts:214
func parseOptionalChangeSet(_ raw: OrderedJSON?, allowedOps: [OpType]? = nil, options: ChangeSetValidationOptions = ChangeSetValidationOptions()) throws(ChangeSetError)
  -> [ChangeOp]
{
  guard let raw, !raw.isNull, raw.arrayValue?.isEmpty != true else { return [] }
  return try parseChangeSet(raw, allowedOps: allowedOps, options: options)
}
