import Foundation

extension Double {
  // Intl en-US toLocaleString: the shortest decimal rounded half away from zero to three fraction digits, comma-grouped.
  var enUSGrouped: String {
    guard var decimal = Decimal(string: abs(self).jsString) else { return jsString }
    var source = decimal
    NSDecimalRound(&decimal, &source, 3, .plain)
    let parts = "\(decimal)".split(separator: ".", omittingEmptySubsequences: false)
    let digits = String(parts[0])
    let fraction = parts.count > 1 ? String(parts[1]) : ""
    var grouped = ""
    for (offset, digit) in digits.enumerated() {
      if offset > 0, (digits.count - offset) % 3 == 0 { grouped += "," }
      grouped.append(digit)
    }
    return (self < 0 && decimal != 0 ? "-" : "") + grouped + (fraction.isEmpty ? "" : "." + fraction)
  }
}
