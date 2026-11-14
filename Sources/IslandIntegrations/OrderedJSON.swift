import Foundation

/// Minimal JSON value that keeps object key order and number lexemes, so editing
/// an agent's configuration only changes the entries Agent Island owns.
public indirect enum JSONValue: Equatable, Sendable {
    case object([(String, JSONValue)])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case let (.object(a), .object(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.array(a), .array(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.number(a), .number(b)): return a == b || Double(a) == Double(b)
        case let (.bool(a), .bool(b)): return a == b
        case (.null, .null): return true
        default: return false
        }
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.last { $0.0 == key }?.1
    }

    public var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
    public var objectValue: [(String, JSONValue)]? { if case .object(let value) = self { return value }; return nil }

    /// Replace or append a key, keeping the position of an existing key.
    public func setting(_ key: String, _ value: JSONValue?) -> JSONValue {
        guard case .object(var members) = self else { return self }
        if let index = members.firstIndex(where: { $0.0 == key }) {
            if let value { members[index].1 = value } else { members.remove(at: index) }
        } else if let value {
            members.append((key, value))
        }
        return .object(members)
    }

    // MARK: Parsing

    public static func parse(_ data: Data) throws -> JSONValue {
        var parser = Parser(bytes: Array(data))
        parser.skipWhitespace()
        if parser.index < parser.bytes.count, parser.bytes[parser.index] == 0xEF { parser.index += 3 } // UTF-8 BOM
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw JSONError.trailingData }
        return value
    }

    public enum JSONError: Error, LocalizedError {
        case unexpected(Int), trailingData, tooDeep
        public var errorDescription: String? {
            switch self {
            case .unexpected(let offset): return "JSON 格式无效（位置 \(offset)）"
            case .trailingData: return "JSON 末尾有多余内容"
            case .tooDeep: return "JSON 嵌套过深"
            }
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
        }

        mutating func value(depth: Int) throws -> JSONValue {
            guard depth < 256 else { throw JSONError.tooDeep }
            skipWhitespace()
            guard index < bytes.count else { throw JSONError.unexpected(index) }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1
                var members: [(String, JSONValue)] = []
                skipWhitespace()
                if peek("}") { index += 1; return .object(members) }
                while true {
                    skipWhitespace()
                    let key = try string()
                    skipWhitespace()
                    try expect(":")
                    members.append((key, try value(depth: depth + 1)))
                    skipWhitespace()
                    if peek(",") { index += 1; continue }
                    try expect("}")
                    return .object(members)
                }
            case UInt8(ascii: "["):
                index += 1
                var items: [JSONValue] = []
                skipWhitespace()
                if peek("]") { index += 1; return .array(items) }
                while true {
                    items.append(try value(depth: depth + 1))
                    skipWhitespace()
                    if peek(",") { index += 1; continue }
                    try expect("]")
                    return .array(items)
                }
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return .number(try number())
            }
        }

        func peek(_ character: Character) -> Bool { index < bytes.count && bytes[index] == character.asciiValue! }

        mutating func expect(_ character: Character) throws {
            guard peek(character) else { throw JSONError.unexpected(index) }
            index += 1
        }

        mutating func literal(_ word: String) throws {
            let expected = Array(word.utf8)
            guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else { throw JSONError.unexpected(index) }
            index += expected.count
        }

        mutating func number() throws -> String {
            let start = index
            while index < bytes.count, "+-0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
            let lexeme = String(decoding: bytes[start..<index], as: UTF8.self)
            guard !lexeme.isEmpty, Double(lexeme) != nil else { throw JSONError.unexpected(start) }
            return lexeme
        }

        mutating func string() throws -> String {
            try expect("\"")
            var scalars = String.UnicodeScalarView()
            var raw: [UInt8] = []
            func flush() { if !raw.isEmpty { scalars.append(contentsOf: String(decoding: raw, as: UTF8.self).unicodeScalars); raw.removeAll() } }
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == UInt8(ascii: "\"") { flush(); return String(scalars) }
                if byte < 0x20 { throw JSONError.unexpected(index - 1) }
                if byte != UInt8(ascii: "\\") { raw.append(byte); continue }
                flush()
                guard index < bytes.count else { break }
                let escape = bytes[index]; index += 1
                switch escape {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800...0xDBFF).contains(code), peek("\\") {
                        index += 1; try expect("u")
                        let low = try hex4()
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    scalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                default: throw JSONError.unexpected(index - 1)
                }
            }
            throw JSONError.unexpected(index)
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count, let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else { throw JSONError.unexpected(index) }
            index += 4
            return value
        }
    }

    // MARK: Serialization (two-space indent, the format Claude Code and Codex write)

    public func serialized() -> Data {
        var output = ""
        write(into: &output, indent: 0)
        output += "\n"
        return Data(output.utf8)
    }

    private func write(into output: inout String, indent: Int) {
        let pad = String(repeating: "  ", count: indent + 1)
        let close = String(repeating: "  ", count: indent)
        switch self {
        case .object(let members):
            if members.isEmpty { output += "{}"; return }
            output += "{\n"
            for (offset, member) in members.enumerated() {
                output += pad + Self.quote(member.0) + ": "
                member.1.write(into: &output, indent: indent + 1)
                output += offset == members.count - 1 ? "\n" : ",\n"
            }
            output += close + "}"
        case .array(let items):
            if items.isEmpty { output += "[]"; return }
            output += "[\n"
            for (offset, item) in items.enumerated() {
                output += pad
                item.write(into: &output, indent: indent + 1)
                output += offset == items.count - 1 ? "\n" : ",\n"
            }
            output += close + "]"
        case .string(let value): output += Self.quote(value)
        case .number(let lexeme): output += lexeme
        case .bool(let value): output += value ? "true" : "false"
        case .null: output += "null"
        }
    }

    static func quote(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            default:
                if scalar.value < 0x20 { result += String(format: "\\u%04x", scalar.value) }
                else { result.unicodeScalars.append(scalar) }
            }
        }
        return result + "\""
    }
}
