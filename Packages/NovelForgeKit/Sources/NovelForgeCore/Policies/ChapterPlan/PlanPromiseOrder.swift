// Probed against Bun for up to 64 elements only; above that an intransitive comparator may order differently.
func jsArraySorted<Element>(_ items: [Element], compare: (Element, Element) -> Int) -> [Element] {
  guard items.count >= 2 else { return items }
  guard items.count <= 64 else { return items.jsStableSorted { compare($0, $1) < 0 } }
  var items = items
  let run = items.count < 8 ? 1 : countAndMakeRun(&items, compare)
  binaryInsertionSort(&items, start: run, compare)
  return items
}

private func countAndMakeRun<Element>(_ items: inout [Element], _ compare: (Element, Element) -> Int) -> Int {
  let high = items.count
  var runLength = 2
  let descending = compare(items[1], items[0]) < 0
  var previous = items[1]
  var index = 2
  while index < high {
    let order = compare(items[index], previous)
    if descending ? order >= 0 : order < 0 { break }
    previous = items[index]
    runLength += 1
    index += 1
  }
  if descending { items[0..<runLength].reverse() }
  return runLength
}

private func binaryInsertionSort<Element>(_ items: inout [Element], start: Int, _ compare: (Element, Element) -> Int) {
  var start = start
  while start < items.count {
    var left = 0
    var right = start
    let pivot = items[start]
    while left < right {
      let middle = left + ((right - left) >> 1)
      if compare(pivot, items[middle]) < 0 { right = middle } else { left = middle + 1 }
    }
    var position = start
    while position > left {
      items[position] = items[position - 1]
      position -= 1
    }
    items[left] = pivot
    start += 1
  }
}
