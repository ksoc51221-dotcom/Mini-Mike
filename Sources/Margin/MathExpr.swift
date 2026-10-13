import Foundation

/// A small, safe math language for graphs. Claude writes expressions like "a(x - h)^2 + k" or
/// "8 - 0.7x + shift", and Margin evaluates them itself: nothing is ever run as code.
///
/// Supports numbers, + - * / ^, parentheses, implicit multiplication (2x, 3(x+1), (x+1)(x-1), a(x-h)^2),
/// ² and ³, comparisons (< > <= >=, giving 1 or 0) for if(cond, a, b), functions (sin, sqrt, ln, …),
/// constants (pi, e), and named values: x, t, slider names, point coordinates like E.x, and the
/// graph's own curves called as functions, like f(2).
indirect enum MathExpr: Equatable {
    case number(Double)
    case name(String)
    case negate(MathExpr)
    case binary(String, MathExpr, MathExpr)
    case call(String, [MathExpr])

    struct ParseError: Error, CustomStringConvertible {
        let description: String
    }

    /// `functions`: the graph's curve names, which can be called like f(2). Other names followed by
    /// parentheses multiply instead, so "a(x - h)^2" means a·(x − h)².
    static func parse(_ source: String, functions: Set<String> = []) throws -> MathExpr {
        guard source.count <= 600 else { throw ParseError(description: "expression is too long") }
        var parser = Parser(tokens: try tokenize(source), functions: functions)
        return try parser.parseAll()
    }

    /// Every name the expression refers to, as a value (x, a, E.x) or as a function (f).
    var names: Set<String> {
        switch self {
        case .number: return []
        case .name(let n): return [n]
        case .negate(let e): return e.names
        case .binary(_, let l, let r): return l.names.union(r.names)
        case .call(let f, let args):
            let inner = args.reduce(into: Set<String>()) { $0.formUnion($1.names) }
            return Self.builtins[f] == nil ? inner.union([f]) : inner
        }
    }

    func value(_ env: MathEnv) -> Double {
        switch self {
        case .number(let v):
            return v
        case .name(let n):
            return env.value(of: n)
        case .negate(let e):
            return -e.value(env)
        case .binary(let op, let l, let r):
            let a = l.value(env), b = r.value(env)
            switch op {
            case "+": return a + b
            case "-": return a - b
            case "*": return a * b
            case "/": return a / b
            case "^": return Self.power(a, b)
            case "<": return a < b ? 1 : 0
            case ">": return a > b ? 1 : 0
            case "<=": return a <= b ? 1 : 0
            case ">=": return a >= b ? 1 : 0
            default: return .nan
            }
        case .call(let f, let args):
            if f == "if" { // only the chosen branch is evaluated
                guard args.count == 3 else { return .nan }
                return args[0].value(env) != 0 ? args[1].value(env) : args[2].value(env)
            }
            let values = args.map { $0.value(env) }
            if let builtin = Self.builtins[f] {
                return builtin.arity.accepts(values.count) ? builtin.apply(values) : .nan
            }
            guard values.count == 1 else { return .nan }
            return env.call(f, values[0])
        }
    }

    /// Real powers of negative numbers: (−8)^(1/3) is −2, like on paper, not "undefined".
    private static func power(_ a: Double, _ b: Double) -> Double {
        let p = pow(a, b)
        guard p.isNaN, a < 0, b.isFinite, b != 0 else { return p }
        // An odd root, like 1/3 or 3/5: check whether 1/b is (close to) an odd whole number.
        let inverse = 1 / b
        let rounded = inverse.rounded()
        guard abs(inverse - rounded) < 1e-9, Int(rounded) % 2 != 0 else { return p }
        return -pow(-a, b)
    }

    // MARK: Built-in functions

    enum Arity {
        case exactly(Int), atLeast(Int)
        func accepts(_ n: Int) -> Bool {
            switch self {
            case .exactly(let k): return n == k
            case .atLeast(let k): return n >= k
            }
        }
    }

    static let builtins: [String: (arity: Arity, apply: ([Double]) -> Double)] = [
        "sin": (.exactly(1), { sin($0[0]) }), "cos": (.exactly(1), { cos($0[0]) }), "tan": (.exactly(1), { tan($0[0]) }),
        "asin": (.exactly(1), { asin($0[0]) }), "acos": (.exactly(1), { acos($0[0]) }), "atan": (.exactly(1), { atan($0[0]) }),
        "arcsin": (.exactly(1), { asin($0[0]) }), "arccos": (.exactly(1), { acos($0[0]) }), "arctan": (.exactly(1), { atan($0[0]) }),
        "atan2": (.exactly(2), { atan2($0[0], $0[1]) }),
        "sinh": (.exactly(1), { sinh($0[0]) }), "cosh": (.exactly(1), { cosh($0[0]) }), "tanh": (.exactly(1), { tanh($0[0]) }),
        "sec": (.exactly(1), { 1 / cos($0[0]) }), "csc": (.exactly(1), { 1 / sin($0[0]) }), "cot": (.exactly(1), { 1 / tan($0[0]) }),
        "exp": (.exactly(1), { exp($0[0]) }),
        "ln": (.exactly(1), { log($0[0]) }),
        "log": (.exactly(1), { log10($0[0]) }), "log10": (.exactly(1), { log10($0[0]) }), "log2": (.exactly(1), { log2($0[0]) }),
        "sqrt": (.exactly(1), { sqrt($0[0]) }), "cbrt": (.exactly(1), { cbrt($0[0]) }),
        "abs": (.exactly(1), { abs($0[0]) }), "sign": (.exactly(1), { $0[0] > 0 ? 1 : $0[0] < 0 ? -1 : 0 }),
        "floor": (.exactly(1), { floor($0[0]) }), "ceil": (.exactly(1), { ceil($0[0]) }), "round": (.exactly(1), { $0[0].rounded() }),
        "min": (.atLeast(1), { $0.min() ?? .nan }), "max": (.atLeast(1), { $0.max() ?? .nan }),
        "pow": (.exactly(2), { power($0[0], $0[1]) }),
        "mod": (.exactly(2), { $0[0] - $0[1] * floor($0[0] / $0[1]) }),
        "if": (.exactly(3), { $0[0] != 0 ? $0[1] : $0[2] }), // evaluated lazily in `value`
    ]

    static let constants: [String: Double] = ["pi": .pi, "π": .pi, "e": M_E, "tau": 2 * .pi, "τ": 2 * .pi]

    // MARK: Tokens

    private enum Token: Equatable {
        case number(Double)
        case name(String)
        case op(String)
        case open, close, comma, bar
    }

    private static func tokenize(_ source: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(source)
        var i = 0
        func peek(_ k: Int = 0) -> Character? { i + k < chars.count ? chars[i + k] : nil }

        while let c = peek() {
            if c.isWhitespace { i += 1; continue }
            if c.isNumber && c.isASCII || (c == "." && peek(1)?.isNumber == true) {
                var s = ""
                while let d = peek(), d.isASCII, d.isNumber || d == "." { s.append(d); i += 1 }
                // Scientific notation: 2e-3, 1.5E6 (but "2e" alone is 2 times e).
                if let e = peek(), e == "e" || e == "E" {
                    let next = peek(1)
                    let signed = (next == "+" || next == "-") && peek(2)?.isNumber == true
                    if next?.isNumber == true || signed {
                        s.append("e"); i += 1
                        if signed { s.append(chars[i]); i += 1 }
                        while let d = peek(), d.isASCII, d.isNumber { s.append(d); i += 1 }
                    }
                }
                guard let v = Double(s) else { throw ParseError(description: "bad number “\(s)”") }
                tokens.append(.number(v))
                continue
            }
            if c.isLetter || c == "_" {
                var s = ""
                // Letters, plain digits and _ (not ² or ³, which Swift also counts as numbers).
                func continues(_ d: Character) -> Bool { d.isLetter || (d.isASCII && d.isNumber) || d == "_" }
                while let d = peek(), continues(d) { s.append(d); i += 1 }
                // Point coordinates: E.x, E.y
                while peek() == ".", let d = peek(1), d.isLetter {
                    s.append("."); i += 1
                    while let d = peek(), continues(d) { s.append(d); i += 1 }
                }
                tokens.append(.name(s))
                continue
            }
            i += 1
            switch c {
            case "+": tokens.append(.op("+"))
            case "-", "−", "–": tokens.append(.op("-"))
            case "*", "×", "·", "⋅", "∙":
                if c == "*" && peek() == "*" { i += 1; tokens.append(.op("^")) } else { tokens.append(.op("*")) }
            case "/", "÷": tokens.append(.op("/"))
            case "^": tokens.append(.op("^"))
            case "²": tokens += [.op("^"), .number(2)]
            case "³": tokens += [.op("^"), .number(3)]
            case "<", ">", "≤", "≥":
                if peek() == "=" { i += 1; tokens.append(.op(c == "<" ? "<=" : ">=")) }
                else if c == "≤" { tokens.append(.op("<=")) }
                else if c == "≥" { tokens.append(.op(">=")) }
                else { tokens.append(.op(String(c))) }
            case "(", "[": tokens.append(.open)
            case ")", "]": tokens.append(.close)
            case ",": tokens.append(.comma)
            case "|": tokens.append(.bar)
            default: throw ParseError(description: "unexpected “\(c)”")
            }
        }
        return tokens
    }

    // MARK: Parser (precedence: comparison < + − < × ÷ and implicit × < unary − < ^)

    private struct Parser {
        let tokens: [Token]
        let functions: Set<String>
        var i = 0
        var depth = 0

        init(tokens: [Token], functions: Set<String>) {
            self.tokens = tokens
            self.functions = functions
        }

        var peek: Token? { i < tokens.count ? tokens[i] : nil }

        mutating func parseAll() throws -> MathExpr {
            guard !tokens.isEmpty else { throw ParseError(description: "empty expression") }
            let e = try comparison()
            guard i == tokens.count else { throw ParseError(description: "unexpected “\(describe(tokens[i]))”") }
            return e
        }

        mutating func comparison() throws -> MathExpr {
            let l = try additive()
            if case .op(let o)? = peek, ["<", ">", "<=", ">="].contains(o) {
                i += 1
                return .binary(o, l, try additive())
            }
            return l
        }

        mutating func additive() throws -> MathExpr {
            var l = try term()
            while case .op(let o)? = peek, o == "+" || o == "-" {
                i += 1
                l = .binary(o, l, try term())
            }
            return l
        }

        mutating func term() throws -> MathExpr {
            var l = try unary()
            while true {
                if case .op(let o)? = peek, o == "*" || o == "/" {
                    i += 1
                    l = .binary(o, l, try unary())
                } else if startsFactor(peek) {
                    l = .binary("*", l, try power()) // 2x, 3(x+1), a(x-h)^2
                } else {
                    return l
                }
            }
        }

        mutating func unary() throws -> MathExpr {
            if case .op(let o)? = peek, o == "-" || o == "+" {
                i += 1
                let e = try unary()
                return o == "-" ? .negate(e) : e
            }
            return try power()
        }

        mutating func power() throws -> MathExpr {
            let base = try primary()
            if case .op("^")? = peek {
                i += 1
                return .binary("^", base, try unary()) // right-associative, allows 2^-x
            }
            return base
        }

        mutating func primary() throws -> MathExpr {
            depth += 1
            defer { depth -= 1 }
            guard depth < 60 else { throw ParseError(description: "expression is nested too deeply") }
            switch peek {
            case .number(let v)?:
                i += 1
                return .number(v)
            case .name(let n)?:
                i += 1
                let isBuiltin = MathExpr.builtins[n] != nil
                if peek == .open && (isBuiltin || functions.contains(n)) {
                    i += 1
                    var args: [MathExpr] = []
                    if peek != .close {
                        args.append(try comparison())
                        while peek == .comma {
                            i += 1
                            args.append(try comparison())
                        }
                    }
                    guard peek == .close else { throw ParseError(description: "missing “)” after \(n)(…") }
                    i += 1
                    if let builtin = MathExpr.builtins[n], !builtin.arity.accepts(args.count) {
                        throw ParseError(description: "\(n) takes a different number of values")
                    }
                    return .call(n, args)
                }
                if isBuiltin && startsFactor(peek) { // sin x
                    return .call(n, [try power()])
                }
                return .name(n)
            case .open?:
                i += 1
                let e = try comparison()
                guard peek == .close else { throw ParseError(description: "missing “)”") }
                i += 1
                return e
            case .bar?:
                i += 1
                let e = try comparison()
                guard peek == .bar else { throw ParseError(description: "missing closing “|”") }
                i += 1
                return .call("abs", [e])
            case let t?:
                throw ParseError(description: "unexpected “\(describe(t))”")
            case nil:
                throw ParseError(description: "expression ends too soon")
            }
        }

        func startsFactor(_ t: Token?) -> Bool {
            switch t {
            case .number?, .name?, .open?: return true
            default: return false
            }
        }

        func describe(_ t: Token) -> String {
            switch t {
            case .number(let v): return MathFormat.short(v)
            case .name(let n): return n
            case .op(let o): return o
            case .open: return "("
            case .close: return ")"
            case .comma: return ","
            case .bar: return "|"
            }
        }
    }
}

/// Values and curves an expression can see. A class so curve functions can call each other
/// (with a depth limit) and temporarily bind x while they run.
final class MathEnv {
    var values: [String: Double] = [:]
    var functions: [String: (Double) -> Double] = [:]
    private var depth = 0

    init(values: [String: Double] = [:]) {
        self.values = values
    }

    func value(of name: String) -> Double {
        values[name] ?? MathExpr.constants[name] ?? .nan
    }

    func call(_ name: String, _ x: Double) -> Double {
        guard let f = functions[name], depth < 24 else { return .nan }
        depth += 1
        defer { depth -= 1 }
        return f(x)
    }

    /// Evaluates `expr` with `name` (usually x or t) set to `v`, restoring the old value after.
    func evaluate(_ expr: MathExpr, setting name: String, to v: Double) -> Double {
        let old = values[name]
        values[name] = v
        defer { values[name] = old }
        return expr.value(self)
    }
}

enum MathFormat {
    /// Compact numbers for ticks and readouts: 2, 2.5, 0.33, −1.25, 1200, 3.1e+06.
    static func short(_ v: Double) -> String {
        guard v.isFinite else { return v.isNaN ? "undefined" : (v > 0 ? "∞" : "−∞") }
        let a = abs(v)
        if a != 0 && (a >= 1e6 || a < 1e-3) {
            return String(format: "%.2g", v).replacingOccurrences(of: "-", with: "−")
        }
        let decimals = a >= 100 ? 1 : 2
        var s = String(format: "%.\(decimals)f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        if s == "-0" { s = "0" }
        return s.replacingOccurrences(of: "-", with: "−")
    }
}
