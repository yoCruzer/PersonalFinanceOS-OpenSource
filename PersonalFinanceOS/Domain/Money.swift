import Foundation

enum MoneyError: Error, Equatable {
    case negativeAmount
    case invalidCurrencyCode
    case invalidDecimal
    case unsupportedFractionDigits
    case overflow
}

struct Money: Codable, Equatable, Hashable, Sendable {
    static let cnyCode = "CNY"
    static let defaultFractionDigits = 2

    let minorUnits: Int64
    let currencyCode: String

    init(minorUnits: Int64, currencyCode: String = Money.cnyCode) throws {
        guard minorUnits >= 0 else {
            throw MoneyError.negativeAmount
        }

        let normalizedCurrencyCode = currencyCode.uppercased()
        guard Self.isValidCurrencyCode(normalizedCurrencyCode) else {
            throw MoneyError.invalidCurrencyCode
        }

        self.minorUnits = minorUnits
        self.currencyCode = normalizedCurrencyCode
    }

    init(decimalString: String, currencyCode: String = Money.cnyCode) throws {
        let normalizedCurrencyCode = currencyCode.uppercased()
        guard Self.isValidCurrencyCode(normalizedCurrencyCode) else {
            throw MoneyError.invalidCurrencyCode
        }

        let input = decimalString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !input.hasPrefix("-") else {
            throw input.hasPrefix("-") ? MoneyError.negativeAmount : MoneyError.invalidDecimal
        }

        let components = input.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count <= 2 else {
            throw MoneyError.invalidDecimal
        }

        let wholeText = String(components[0])
        let fractionText = components.count == 2 ? String(components[1]) : ""
        guard (!wholeText.isEmpty || !fractionText.isEmpty),
              Self.containsOnlyASCIIDigits(wholeText),
              Self.containsOnlyASCIIDigits(fractionText) else {
            throw MoneyError.invalidDecimal
        }
        guard fractionText.count <= Self.defaultFractionDigits else {
            throw MoneyError.unsupportedFractionDigits
        }

        guard let whole = Int64(wholeText.isEmpty ? "0" : wholeText) else {
            throw MoneyError.overflow
        }

        let paddedFraction = fractionText.padding(
            toLength: Self.defaultFractionDigits,
            withPad: "0",
            startingAt: 0
        )
        guard let fraction = Int64(paddedFraction.isEmpty ? "0" : paddedFraction) else {
            throw MoneyError.invalidDecimal
        }

        let (scaledWhole, wholeOverflow) = whole.multipliedReportingOverflow(by: 100)
        let (minorUnits, sumOverflow) = scaledWhole.addingReportingOverflow(fraction)
        guard !wholeOverflow, !sumOverflow else {
            throw MoneyError.overflow
        }

        self.minorUnits = minorUnits
        self.currencyCode = normalizedCurrencyCode
    }

    var decimalString: String {
        let whole = minorUnits / 100
        let fraction = minorUnits % 100
        return "\(whole).\(String(format: "%02lld", fraction))"
    }

    func formatted(locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        formatter.minimumFractionDigits = Self.defaultFractionDigits
        formatter.maximumFractionDigits = Self.defaultFractionDigits

        let number = NSDecimalNumber(
            mantissa: UInt64(minorUnits),
            exponent: -Int16(Self.defaultFractionDigits),
            isNegative: false
        )
        return formatter.string(from: number) ?? "\(currencyCode) \(decimalString)"
    }

    private static func containsOnlyASCIIDigits(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { (48...57).contains($0.value) }
    }

    private static func isValidCurrencyCode(_ value: String) -> Bool {
        value.count == 3 && value.unicodeScalars.allSatisfy { (65...90).contains($0.value) }
    }
}
