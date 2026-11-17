@testable import NovelForgeCore

func csErrors(_ json: String, allowed: [OpType]? = nil, options: ChangeSetValidationOptions = ChangeSetValidationOptions()) throws -> [String] {
  validateChangeSet(try csParse(json), allowedOps: allowed, options: options).errors
}

func csPluginErrors(_ json: String) throws -> [String] {
  validatePluginChangeSet(try csParse(json)).errors
}

func csOps(_ json: String, allowed: [OpType]? = nil, options: ChangeSetValidationOptions = ChangeSetValidationOptions()) throws -> [ChangeOp] {
  try parseChangeSet(csParse(json), allowedOps: allowed, options: options)
}

func csOp(_ json: String) throws -> ChangeOp {
  guard let op = try csOps("[\(json)]", options: ChangeSetValidationOptions(entityMaterialization: false)).first else { throw CSSpecError.notAnOperation(json) }
  return op
}

enum CSSpecError: Error {
  case notAnOperation(String)
}

let csValidOps = """
  [
    {"op": "premise.update", "premise": "a cultivator returns from death", "themes": ["revenge"]},
    {"op": "bible_document.upsert", "section": "project", "slug": "reader-promise", "body": "weekly power-ups"},
    {"op": "volume.upsert", "volumeKey": "vol_1", "objective": "survive the sect trials"},
    {"op": "brief.update", "chapter": 3, "endingContract": {"hookType": "cliffhanger", "emotionalBeat": "dread", "openQuestion": "who betrayed him?", "handoffState": "trapped in the vault"}}
  ]
  """
