import ShadowText

@testable import NovelForgeCore

func applyOps(_ json: String) throws -> [ChangeOp] {
  try parseChangeSet(try OrderedJSON(parsing: "[\(json)]"), options: ChangeSetValidationOptions(entityMaterialization: false))
}
