struct CloudKitTuning: Sendable {
  var inlineLimit = CloudKitRecordLayout.inlineLimit
  var partBytes = CloudKitRecordLayout.partBytes
  var maxObjectBytes = CloudKitRecordLayout.maxObjectBytes
  var listPageSize = 1000
  var batchSize = 200
  var maxFeedPages = 10_000
  var maxRebuilds = 2

  func validated() -> Self {
    var tuning = self
    tuning.inlineLimit = max(0, inlineLimit)
    tuning.partBytes = max(1, partBytes)
    tuning.maxObjectBytes = max(0, maxObjectBytes)
    tuning.listPageSize = max(1, listPageSize)
    tuning.batchSize = max(1, batchSize)
    tuning.maxFeedPages = max(1, maxFeedPages)
    tuning.maxRebuilds = max(1, maxRebuilds)
    return tuning
  }
}
