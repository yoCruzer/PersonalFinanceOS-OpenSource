import Foundation

enum AmountExpressionError: Error, Equatable {
    case invalidExpression
    case divisionByZero
    case nonPositiveResult
    case overflow
}

extension AmountExpressionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidExpression:
            "请完成金额计算。"
        case .divisionByZero:
            "金额不能除以 0。"
        case .nonPositiveResult:
            "金额必须大于 0。"
        case .overflow:
            "金额过大，请输入较小的金额。"
        }
    }
}

enum AmountExpression {
    static func evaluateMoney(
        _ expression: String,
        currencyCode: String = Money.cnyCode
    ) throws -> Money {
        let tokens = try tokenize(expression)
        let postfix = try makePostfix(tokens)
        let decimal = try evaluate(postfix)

        guard decimal > 0 else {
            throw AmountExpressionError.nonPositiveResult
        }

        var value = decimal
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, Money.defaultFractionDigits, .plain)

        let maximum = Decimal(Int64.max) / 100
        guard rounded <= maximum else {
            throw AmountExpressionError.overflow
        }

        do {
            return try Money(
                decimalString: NSDecimalNumber(decimal: rounded).stringValue,
                currencyCode: currencyCode
            )
        } catch MoneyError.overflow {
            throw AmountExpressionError.overflow
        } catch {
            throw AmountExpressionError.invalidExpression
        }
    }

    static func appendingDigit(_ digit: Character, to expression: String) -> String {
        guard digit.isNumber else {
            return expression
        }
        let operand = currentOperand(in: expression)
        if let separator = operand.firstIndex(of: "."),
           operand.distance(from: separator, to: operand.endIndex) > Money.defaultFractionDigits {
            return expression
        }
        return expression + String(digit)
    }

    static func appendingDecimalPoint(to expression: String) -> String {
        let operand = currentOperand(in: expression)
        guard !operand.contains(".") else {
            return expression
        }
        return expression + (operand.isEmpty ? "0." : ".")
    }

    static func appendingOperator(_ symbol: Character, to expression: String) -> String {
        guard isOperator(symbol), !expression.isEmpty else {
            return expression
        }
        if expression.last == "." {
            return expression
        }
        if let last = expression.last, isOperator(last) {
            return String(expression.dropLast()) + String(symbol)
        }
        return expression + String(symbol)
    }

    static func deletingLastCharacter(from expression: String) -> String {
        String(expression.dropLast())
    }

    private enum Token: Equatable {
        case number(Decimal)
        case operation(Character)
    }

    private static func tokenize(_ expression: String) throws -> [Token] {
        let compact = expression.filter { !$0.isWhitespace }
        guard !compact.isEmpty else {
            throw AmountExpressionError.invalidExpression
        }

        var tokens: [Token] = []
        var number = ""

        func appendNumber() throws {
            let components = number.split(separator: ".", omittingEmptySubsequences: false)
            guard !number.isEmpty,
                  number != ".",
                  components.count <= 2,
                  (components.count < 2 || components[1].count <= Money.defaultFractionDigits),
                  let decimal = Decimal(string: number, locale: Locale(identifier: "en_US_POSIX")) else {
                throw AmountExpressionError.invalidExpression
            }
            tokens.append(.number(decimal))
            number = ""
        }

        for rawCharacter in compact {
            let character = normalized(rawCharacter)
            if character.isNumber || character == "." {
                if character == ".", number.contains(".") {
                    throw AmountExpressionError.invalidExpression
                }
                number.append(character)
            } else if isOperator(character) {
                try appendNumber()
                tokens.append(.operation(character))
            } else {
                throw AmountExpressionError.invalidExpression
            }
        }
        try appendNumber()

        guard case .number = tokens.first,
              case .number = tokens.last else {
            throw AmountExpressionError.invalidExpression
        }
        return tokens
    }

    private static func makePostfix(_ tokens: [Token]) throws -> [Token] {
        var output: [Token] = []
        var operations: [Character] = []
        var expectsNumber = true

        for token in tokens {
            switch token {
            case .number:
                guard expectsNumber else {
                    throw AmountExpressionError.invalidExpression
                }
                output.append(token)
                expectsNumber = false
            case let .operation(operation):
                guard !expectsNumber else {
                    throw AmountExpressionError.invalidExpression
                }
                while let last = operations.last,
                      precedence(last) >= precedence(operation) {
                    output.append(.operation(operations.removeLast()))
                }
                operations.append(operation)
                expectsNumber = true
            }
        }
        guard !expectsNumber else {
            throw AmountExpressionError.invalidExpression
        }
        output.append(contentsOf: operations.reversed().map(Token.operation))
        return output
    }

    private static func evaluate(_ tokens: [Token]) throws -> Decimal {
        var stack: [Decimal] = []

        for token in tokens {
            switch token {
            case let .number(number):
                stack.append(number)
            case let .operation(operation):
                guard stack.count >= 2 else {
                    throw AmountExpressionError.invalidExpression
                }
                let right = stack.removeLast()
                let left = stack.removeLast()
                if operation == "/", right == 0 {
                    throw AmountExpressionError.divisionByZero
                }

                let leftNumber = NSDecimalNumber(decimal: left)
                let rightNumber = NSDecimalNumber(decimal: right)
                let result: NSDecimalNumber
                switch operation {
                case "+":
                    result = leftNumber.adding(rightNumber)
                case "-":
                    result = leftNumber.subtracting(rightNumber)
                case "*":
                    result = leftNumber.multiplying(by: rightNumber)
                case "/":
                    result = leftNumber.dividing(by: rightNumber)
                default:
                    throw AmountExpressionError.invalidExpression
                }
                guard result != .notANumber else {
                    throw AmountExpressionError.overflow
                }
                stack.append(result.decimalValue)
            }
        }

        guard stack.count == 1, let result = stack.first else {
            throw AmountExpressionError.invalidExpression
        }
        return result
    }

    private static func currentOperand(in expression: String) -> Substring {
        let start = expression.lastIndex(where: isOperator).map(expression.index(after:))
            ?? expression.startIndex
        return expression[start...]
    }

    private static func normalized(_ character: Character) -> Character {
        switch character {
        case "×": "*"
        case "÷": "/"
        case "−": "-"
        default: character
        }
    }

    private static func isOperator(_ character: Character) -> Bool {
        ["+", "-", "−", "*", "×", "/", "÷"].contains(character)
    }

    private static func precedence(_ operation: Character) -> Int {
        operation == "*" || operation == "/" ? 2 : 1
    }
}
