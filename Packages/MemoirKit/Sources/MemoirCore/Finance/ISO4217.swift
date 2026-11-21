/// ISO 4217 currencies with minor units and their exponent: the number of decimal places a minor-unit amount carries. Funds and metals without minor
/// units (XAU, XDR, XTS, XXX, ...) are left out. Codes withdrawn recently (ANG, BGN, CUC, HRK, SLL, ZWL) stay so old expenses still convert.
public enum ISO4217 {
  public static let exponents: [String: Int] = {
    var table = [String: Int]()
    for code in twoDecimalCodes { table[code] = 2 }
    for code in noDecimalCodes { table[code] = 0 }
    for code in threeDecimalCodes { table[code] = 3 }
    for code in fourDecimalCodes { table[code] = 4 }
    return table
  }()

  public static let codes: [CurrencyCode] = exponents.keys.sorted().compactMap(CurrencyCode.init)

  public static func exponent(of currency: CurrencyCode) throws(FinanceError) -> Int {
    guard let exponent = exponents[currency.code] else { throw .unknownCurrency(currency) }
    return exponent
  }

  private static let noDecimalCodes = ["BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG", "RWF", "UGX", "UYI", "VND", "VUV", "XAF", "XOF", "XPF"]
  private static let threeDecimalCodes = ["BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND"]
  private static let fourDecimalCodes = ["CLF", "UYW"]
  private static let twoDecimalCodes = [
    "AED", "AFN", "ALL", "AMD", "ANG", "AOA", "ARS", "AUD", "AWG", "AZN", "BAM", "BBD", "BDT", "BGN", "BMD", "BND", "BOB", "BOV", "BRL", "BSD", "BTN", "BWP",
    "BYN", "BZD", "CAD", "CDF", "CHE", "CHF", "CHW", "CNY", "COP", "COU", "CRC", "CUC", "CUP", "CVE", "CZK", "DKK", "DOP", "DZD", "EGP", "ERN", "ETB", "EUR",
    "FJD", "FKP", "GBP", "GEL", "GHS", "GIP", "GMD", "GTQ", "GYD", "HKD", "HNL", "HRK", "HTG", "HUF", "IDR", "ILS", "INR", "IRR", "JMD", "KES", "KGS", "KHR",
    "KPW", "KYD", "KZT", "LAK", "LBP", "LKR", "LRD", "LSL", "MAD", "MDL", "MGA", "MKD", "MMK", "MNT", "MOP", "MRU", "MUR", "MVR", "MWK", "MXN", "MXV", "MYR",
    "MZN", "NAD", "NGN", "NIO", "NOK", "NPR", "NZD", "PAB", "PEN", "PGK", "PHP", "PKR", "PLN", "QAR", "RON", "RSD", "RUB", "SAR", "SBD", "SCR", "SDG", "SEK",
    "SGD", "SHP", "SLE", "SLL", "SOS", "SRD", "SSP", "STN", "SVC", "SYP", "SZL", "THB", "TJS", "TMT", "TOP", "TRY", "TTD", "TWD", "TZS", "UAH", "USD", "USN",
    "UYU", "UZS", "VED", "VES", "WST", "XAD", "XCD", "XCG", "YER", "ZAR", "ZMW", "ZWG", "ZWL",
  ]
}
