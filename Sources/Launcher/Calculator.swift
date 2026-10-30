import Foundation

/// Works out sums typed into the launcher, such as "12 * 7 + 1", "(3 + 4)^2",
/// "sqrt(2)" or "250 * 15%".
enum Calculator {
    static func evaluate(_ input: String) -> Double? {
        var parser = Parser(input)
        guard let value = parser.expression(), parser.isAtEnd(), value.isFinite else { return nil }
        return value
    }

    /// True if the text is a sum worth answering (not just a number or a word).
    static func isCalculation(_ input: String) -> Bool {
        let s = input.trimmingCharacters(in: .whitespaces)
        guard s.contains(where: \.isNumber), Double(s) == nil else { return false }
        let hasOperator = s.contains(where: { "+-*/^×÷%()".contains($0) })
        let hasFunction = s.contains(where: \.isLetter)
        guard hasOperator || hasFunction else { return false }
        return evaluate(s) != nil
    }

    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 10
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private struct Parser {
        private let chars: [Character]
        private var i = 0

        init(_ text: String) {
            chars = Array(text.lowercased())
        }

        mutating func isAtEnd() -> Bool {
            peek() == nil
        }

        private mutating func peek() -> Character? {
            while i < chars.count, chars[i] == " " { i += 1 }
            return i < chars.count ? chars[i] : nil
        }

        // expression = term (("+" | "-") term)*
        mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while let c = peek(), c == "+" || c == "-" {
                i += 1
                guard let right = term() else { return nil }
                value = c == "+" ? value + right : value - right
            }
            return value
        }

        // term = unary (("*" | "/") unary)*
        private mutating func term() -> Double? {
            guard var value = unary() else { return nil }
            while let c = peek(), "*/×÷".contains(c) {
                i += 1
                guard let right = unary() else { return nil }
                value = (c == "*" || c == "×") ? value * right : value / right
            }
            return value
        }

        // unary = ("-" | "+") unary | power
        private mutating func unary() -> Double? {
            if let c = peek(), c == "-" || c == "+" {
                i += 1
                guard let value = unary() else { return nil }
                return c == "-" ? -value : value
            }
            return power()
        }

        // power = postfix ("^" unary)?   (right-associative: 2^3^2 = 2^9)
        private mutating func power() -> Double? {
            guard let base = postfix() else { return nil }
            if peek() == "^" {
                i += 1
                guard let exponent = unary() else { return nil }
                return pow(base, exponent)
            }
            return base
        }

        // postfix = primary "%"*
        private mutating func postfix() -> Double? {
            guard var value = primary() else { return nil }
            while peek() == "%" {
                i += 1
                value /= 100
            }
            return value
        }

        private mutating func primary() -> Double? {
            guard let c = peek() else { return nil }

            if c == "(" {
                i += 1
                guard let value = expression(), peek() == ")" else { return nil }
                i += 1
                return value
            }

            if c.isASCII, c.isNumber || c == "." {
                var text = ""
                while i < chars.count, chars[i].isASCII, chars[i].isNumber || chars[i] == "." || chars[i] == "," {
                    if chars[i] != "," { text.append(chars[i]) } // 1,000 means 1000
                    i += 1
                }
                return Double(text)
            }

            if c.isLetter {
                var name = ""
                while i < chars.count, chars[i].isLetter {
                    name.append(chars[i])
                    i += 1
                }
                switch name {
                case "pi", "π": return Double.pi
                case "e": return M_E
                default: break
                }
                guard peek() == "(" else { return nil }
                i += 1
                guard let arg = expression(), peek() == ")" else { return nil }
                i += 1
                switch name {
                case "sqrt": return arg.squareRoot()
                case "cbrt": return cbrt(arg)
                case "abs": return abs(arg)
                case "round": return arg.rounded()
                case "floor": return arg.rounded(.down)
                case "ceil": return arg.rounded(.up)
                case "sin": return sin(arg)
                case "cos": return cos(arg)
                case "tan": return tan(arg)
                case "log": return log10(arg)
                case "ln": return log(arg)
                case "exp": return exp(arg)
                default: return nil
                }
            }
            return nil
        }
    }
}
