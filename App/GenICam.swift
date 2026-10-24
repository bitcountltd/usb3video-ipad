//
//  GenICam.swift
//  A compact GenICam (GenApi) interpreter: enough of the standard to drive camera
//  features (exposure, gain, pixel format, acquisition start/stop ...) by name.
//
//  Supported nodes: Integer, Float, Boolean, Command, Enumeration, IntReg, MaskedIntReg,
//  FloatReg, StringReg, StructReg/StructEntry, Converter, IntConverter, SwissKnife, IntSwissKnife.
//  Not supported: selectors' side effects, caching, pIsLocked/pIsAvailable, multiple ports.
//

import Foundation
import Compression

protocol RegisterPort: AnyObject {
    func readMemory(address: UInt64, length: Int) throws -> Data
    func writeMemory(address: UInt64, data: Data) throws
}

extension DriverConnection: RegisterPort {}

enum GenICamError: LocalizedError {
    case missingNode(String)
    case unsupported(String)
    case badFile(String)
    case formula(String)

    var errorDescription: String? {
        switch self {
        case .missingNode(let n): return "Feature \(n) not found"
        case .unsupported(let n): return "Unsupported: \(n)"
        case .badFile(let n): return "Camera description: \(n)"
        case .formula(let n): return "Formula: \(n)"
        }
    }
}

final class GenICamNode {
    struct Property {
        let tag: String
        let attributes: [String: String]
        let text: String
    }

    let kind: String
    let name: String
    var properties: [Property] = []
    var entries: [GenICamNode] = []

    init(kind: String, name: String) {
        self.kind = kind
        self.name = name
    }

    func first(_ tag: String) -> String? {
        properties.first { $0.tag == tag }?.text
    }

    func all(_ tag: String) -> [Property] {
        properties.filter { $0.tag == tag }
    }
}

// MARK: - Feature model for the UI

enum FeatureKind {
    case float(min: Double?, max: Double?, unit: String)
    case integer(min: Int64?, max: Int64?, increment: Int64)
    case enumeration([String])
    case boolean
    case command
    case string
}

enum FeatureValue: Equatable {
    case number(Double)
    case text(String)
    case flag(Bool)
    case none
}

struct Feature: Identifiable {
    let name: String
    let displayName: String
    let kind: FeatureKind
    var value: FeatureValue
    var writable: Bool
    var id: String { name }
}

// MARK: - Device

final class GenICamDevice {
    private let port: RegisterPort
    private(set) var nodes: [String: GenICamNode] = [:]
    private var localValues: [String: Double] = [:]
    private var evaluationDepth = 0

    /// Node references can chain (and badly formed files can loop); fail instead of overflowing.
    private func nested<T>(_ name: String, _ body: () throws -> T) throws -> T {
        evaluationDepth += 1
        defer { evaluationDepth -= 1 }
        guard evaluationDepth < 64 else { throw GenICamError.badFile("node references nest too deeply at \(name)") }
        return try body()
    }

    init(port: RegisterPort, xml: Data) throws {
        self.port = port
        let parser = GenApiParser()
        nodes = try parser.parse(xml)
    }

    func has(_ name: String) -> Bool { nodes[name] != nil }

    private func node(_ name: String) throws -> GenICamNode {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let n = nodes[key] else { throw GenICamError.missingNode(key) }
        return n
    }

    // MARK: Loading the description file from the camera

    static func loadDescription(from port: RegisterPort) throws -> Data {
        let manifestAddress = try readU64(port, 0x01D0)
        let count = try readU64(port, manifestAddress)
        guard count > 0 else { throw GenICamError.badFile("manifest is empty") }
        let entry = try port.readMemory(address: manifestAddress + 8, length: 64)
        let schema = entry.u32(4)
        let address = entry.u64(8)
        let size = Int(entry.u64(16))
        guard size > 0, size < 64 << 20 else { throw GenICamError.badFile("bad size \(size)") }
        let file = try port.readMemory(address: address, length: size)
        return ((schema >> 10) & 0x1F) == 1 ? try unzipFirstEntry(file) : file
    }

    private static func readU64(_ port: RegisterPort, _ address: UInt64) throws -> UInt64 {
        try port.readMemory(address: address, length: 8).u64(0)
    }

    private static func unzipFirstEntry(_ zip: Data) throws -> Data {
        var method: UInt16
        var compressed: Int
        var uncompressed: Int
        var local: Int

        // Prefer the central directory: local headers may defer sizes to a data descriptor.
        if let eocd = (0...max(0, zip.count - 22)).reversed().first(where: { zip.u32($0) == 0x0605_4B50 }) {
            let cd = Int(zip.u32(eocd + 16))
            guard zip.u32(cd) == 0x0201_4B50 else { throw GenICamError.badFile("bad zip directory") }
            method = zip.u16(cd + 10)
            compressed = Int(zip.u32(cd + 20))
            uncompressed = Int(zip.u32(cd + 24))
            local = Int(zip.u32(cd + 42))
        } else {
            guard zip.u32(0) == 0x0403_4B50 else { throw GenICamError.badFile("not a zip file") }
            method = zip.u16(8)
            compressed = Int(zip.u32(18))
            uncompressed = Int(zip.u32(22))
            local = 0
        }
        guard zip.u32(local) == 0x0403_4B50 else { throw GenICamError.badFile("bad zip header") }
        let start = local + 30 + Int(zip.u16(local + 26)) + Int(zip.u16(local + 28))
        guard start + compressed <= zip.count else { throw GenICamError.badFile("truncated zip") }
        let payload = zip.subdata(in: start ..< start + compressed)
        if method == 0 { return payload }
        guard method == 8 else { throw GenICamError.badFile("zip method \(method)") }

        var output = Data(count: uncompressed)
        let written = output.withUnsafeMutableBytes { dst in
            payload.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, uncompressed,
                                          src.bindMemory(to: UInt8.self).baseAddress!, compressed,
                                          nil, COMPRESSION_ZLIB)   // raw DEFLATE
            }
        }
        guard written == uncompressed else { throw GenICamError.badFile("inflate failed") }
        return output
    }

    // MARK: Reading

    func intValue(_ name: String) throws -> Int64 {
        try nested(name) { try intValueUnguarded(name) }
    }

    private func intValueUnguarded(_ name: String) throws -> Int64 {
        let n = try node(name)
        switch n.kind {
        case "Integer":
            if let local = localValues[n.name] { return Int64(local) }
            return try Int64(numeric(n, "Value") ?? 0)
        case "IntReg", "MaskedIntReg", "StructEntry":
            return try readRegisterInt(n)
        case "Enumeration":
            if let local = localValues[n.name] { return Int64(local) }
            return try Int64(numeric(n, "Value") ?? 0)
        case "Boolean":
            let raw = try Int64(numeric(n, "Value") ?? 0)
            return raw == onValue(n) ? 1 : 0
        case "IntConverter", "Converter":
            return Int64(try convertFrom(n).rounded())
        case "IntSwissKnife":
            return Int64(try evaluate(n, formulaTag: "Formula", integer: true))
        default:
            return Int64(try floatValue(name).rounded())
        }
    }

    func floatValue(_ name: String) throws -> Double {
        try nested(name) { try floatValueUnguarded(name) }
    }

    private func floatValueUnguarded(_ name: String) throws -> Double {
        let n = try node(name)
        switch n.kind {
        case "Float":
            if let local = localValues[n.name] { return local }
            return try numeric(n, "Value") ?? 0
        case "FloatReg":
            return try readRegisterFloat(n)
        case "Converter", "IntConverter":
            return try convertFrom(n)
        case "SwissKnife":
            return try evaluate(n, formulaTag: "Formula", integer: false)
        case "IntSwissKnife":
            return try evaluate(n, formulaTag: "Formula", integer: true)
        default:
            return Double(try intValue(name))
        }
    }

    func stringValue(_ name: String) throws -> String {
        let n = try node(name)
        switch n.kind {
        case "StringReg":
            let data = try port.readMemory(address: try address(n), length: try length(n))
            return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        case "String":
            return n.first("Value") ?? ""
        case "Enumeration":
            return try enumSymbol(n)
        default:
            return String(try floatValue(name))
        }
    }

    // MARK: Writing

    func setInt(_ name: String, _ value: Int64) throws {
        let n = try node(name)
        switch n.kind {
        case "Integer", "Enumeration":
            if let target = n.first("pValue") {
                try setInt(target, value)
            } else {
                localValues[n.name] = Double(value)
            }
        case "IntReg", "MaskedIntReg", "StructEntry":
            try writeRegisterInt(n, value)
        case "Boolean":
            guard let target = n.first("pValue") else { throw GenICamError.unsupported("\(name) has no pValue") }
            try setInt(target, value != 0 ? onValue(n) : offValue(n))
        case "Float", "FloatReg", "Converter", "IntConverter":
            try setFloat(name, Double(value))
        default:
            throw GenICamError.unsupported("writing \(n.kind) \(name)")
        }
    }

    func setFloat(_ name: String, _ value: Double) throws {
        let n = try node(name)
        switch n.kind {
        case "Float":
            if let target = n.first("pValue") {
                try setNumeric(target, value)
            } else {
                localValues[n.name] = value
            }
        case "FloatReg":
            try writeRegisterFloat(n, value)
        case "Converter", "IntConverter":
            var vars = try variables(n)
            vars["FROM"] = value
            let raw = try Formula(n.first("FormulaTo") ?? "FROM", integer: n.kind == "IntConverter").evaluate(vars)
            guard let target = n.first("pValue") else { throw GenICamError.unsupported("\(name) has no pValue") }
            try setNumeric(target, raw)
        default:
            try setInt(name, Int64(value.rounded()))
        }
    }

    private func setNumeric(_ name: String, _ value: Double) throws {
        let kind = try node(name).kind
        if ["Float", "FloatReg", "Converter"].contains(kind) {
            try setFloat(name, value)
        } else {
            try setInt(name, Int64(value.rounded()))
        }
    }

    func execute(_ name: String) throws {
        let n = try node(name)
        guard n.kind == "Command", let target = n.first("pValue") else {
            throw GenICamError.unsupported("\(name) is not a command")
        }
        let value = try numeric(n, "CommandValue") ?? 1
        try setInt(target, Int64(value))
    }

    // MARK: Enumerations

    func enumSymbols(_ name: String) throws -> [String] {
        let n = try node(name)
        return n.entries.filter { entry in
            guard let p = entry.first("pIsImplemented") else { return true }
            return (try? intValue(p)) != 0
        }.map(\.name)
    }

    private func enumSymbol(_ n: GenICamNode) throws -> String {
        let value = try intValue(n.name)
        return n.entries.first { entryValue($0) == value }?.name ?? String(value)
    }

    func setEnum(_ name: String, symbol: String) throws {
        let n = try node(name)
        guard let entry = n.entries.first(where: { $0.name == symbol }), let value = entryValue(entry) else {
            throw GenICamError.missingNode("\(name)::\(symbol)")
        }
        try setInt(name, value)
    }

    private func entryValue(_ entry: GenICamNode) -> Int64? {
        entry.first("Value").flatMap { parseNumber($0) }.map { Int64($0) }
    }

    // MARK: UI description

    func feature(_ name: String) -> Feature? {
        guard let n = nodes[name] else { return nil }
        let display = n.first("DisplayName") ?? name
        let writable = (n.first("AccessMode") ?? accessModeOfTarget(n)) != "RO"
        do {
            switch n.kind {
            case "Float", "FloatReg", "Converter", "SwissKnife":
                return Feature(name: name, displayName: display,
                               kind: .float(min: try? numeric(n, "Min"), max: try? numeric(n, "Max"),
                                            unit: n.first("Unit") ?? ""),
                               value: .number(try floatValue(name)), writable: writable)
            case "Integer", "IntReg", "MaskedIntReg", "StructEntry", "IntConverter", "IntSwissKnife":
                let inc = (try? numeric(n, "Inc")).flatMap { $0 }.map { Int64($0) } ?? 1
                return Feature(name: name, displayName: display,
                               kind: .integer(min: (try? numeric(n, "Min")).flatMap { $0 }.map { Int64($0) },
                                              max: (try? numeric(n, "Max")).flatMap { $0 }.map { Int64($0) },
                                              increment: max(1, inc)),
                               value: .number(Double(try intValue(name))), writable: writable)
            case "Enumeration":
                return Feature(name: name, displayName: display, kind: .enumeration(try enumSymbols(name)),
                               value: .text(try enumSymbol(n)), writable: writable)
            case "Boolean":
                return Feature(name: name, displayName: display, kind: .boolean,
                               value: .flag(try intValue(name) != 0), writable: writable)
            case "Command":
                return Feature(name: name, displayName: display, kind: .command, value: .none, writable: true)
            case "StringReg", "String":
                return Feature(name: name, displayName: display, kind: .string,
                               value: .text(try stringValue(name)), writable: false)
            default:
                return nil
            }
        } catch {
            return nil
        }
    }

    private func accessModeOfTarget(_ n: GenICamNode) -> String? {
        guard let target = n.first("pValue"), let t = nodes[target] else { return nil }
        return t.first("AccessMode") ?? accessModeOfTarget(t)
    }

    // MARK: Registers

    private func address(_ n: GenICamNode) throws -> UInt64 {
        var total: Int64 = 0
        for p in n.properties {
            switch p.tag {
            case "Address": total &+= Int64(parseNumber(p.text) ?? 0)
            case "pAddress": total &+= try intValue(p.text)
            case "pIndex":
                let offset = try p.attributes["Offset"].flatMap { parseNumber($0) }
                    ?? p.attributes["pOffset"].map { Double(try intValue($0)) } ?? 1
                total &+= try intValue(p.text) &* Int64(offset)
            default: break
            }
        }
        return UInt64(bitPattern: total)
    }

    private func length(_ n: GenICamNode) throws -> Int {
        if let l = n.first("Length"), let v = parseNumber(l) { return Int(v) }
        if let p = n.first("pLength") { return Int(try intValue(p)) }
        return 4
    }

    private func isBigEndian(_ n: GenICamNode) -> Bool { n.first("Endianess") == "BigEndian" }

    private func readRaw(_ n: GenICamNode) throws -> (UInt64, Int) {
        let len = try length(n)
        guard len <= 8 else { throw GenICamError.unsupported("\(len)-byte register \(n.name)") }
        let data = try port.readMemory(address: try address(n), length: len)
        var value: UInt64 = 0
        for i in 0..<len {
            let byte = UInt64(data[data.startIndex + (isBigEndian(n) ? i : len - 1 - i)])
            value = (value << 8) | byte
        }
        return (value, len)
    }

    private func writeRaw(_ n: GenICamNode, _ value: UInt64, length len: Int) throws {
        var bytes = [UInt8](repeating: 0, count: len)
        for i in 0..<len {
            let byte = UInt8(truncatingIfNeeded: value >> (8 * UInt64(i)))
            bytes[isBigEndian(n) ? len - 1 - i : i] = byte
        }
        try port.writeMemory(address: try address(n), data: Data(bytes))
    }

    /// (shift, width) of a MaskedIntReg/StructEntry in the register, or nil for a full register.
    private func bitField(_ n: GenICamNode, bits: Int) -> (Int, Int)? {
        var lsb = n.first("LSB").flatMap { parseNumber($0) }.map { Int($0) }
        var msb = n.first("MSB").flatMap { parseNumber($0) }.map { Int($0) }
        if let bit = n.first("Bit").flatMap({ parseNumber($0) }).map({ Int($0) }) {
            lsb = bit
            msb = bit
        }
        guard let l = lsb, let m = msb else { return nil }
        if isBigEndian(n) {   // bit 0 is the most significant bit
            return (bits - 1 - l, l - m + 1)
        }
        return (l, m - l + 1)
    }

    private func readRegisterInt(_ n: GenICamNode) throws -> Int64 {
        let (raw, len) = try readRaw(n)
        let signed = n.first("Sign") == "Signed"
        if let (shift, width) = bitField(n, bits: len * 8) {
            let mask: UInt64 = width >= 64 ? ~0 : (1 << UInt64(width)) - 1
            let field = (raw >> UInt64(shift)) & mask
            if signed, width < 64, field & (1 << UInt64(width - 1)) != 0 {
                return Int64(bitPattern: field | ~mask)
            }
            return Int64(bitPattern: field)
        }
        if signed, len < 8, raw & (1 << UInt64(len * 8 - 1)) != 0 {
            return Int64(bitPattern: raw | ~((1 << UInt64(len * 8)) - 1))
        }
        return Int64(bitPattern: raw)
    }

    private func writeRegisterInt(_ n: GenICamNode, _ value: Int64) throws {
        let len = try length(n)
        if let (shift, width) = bitField(n, bits: len * 8) {
            let (raw, _) = try readRaw(n)
            let mask: UInt64 = (width >= 64 ? ~0 : (1 << UInt64(width)) - 1) << UInt64(shift)
            let updated = (raw & ~mask) | ((UInt64(bitPattern: value) << UInt64(shift)) & mask)
            try writeRaw(n, updated, length: len)
        } else {
            try writeRaw(n, UInt64(bitPattern: value), length: len)
        }
    }

    private func readRegisterFloat(_ n: GenICamNode) throws -> Double {
        let (raw, len) = try readRaw(n)
        return len == 4 ? Double(Float(bitPattern: UInt32(truncatingIfNeeded: raw))) : Double(bitPattern: raw)
    }

    private func writeRegisterFloat(_ n: GenICamNode, _ value: Double) throws {
        let len = try length(n)
        let raw = len == 4 ? UInt64(Float(value).bitPattern) : value.bitPattern
        try writeRaw(n, raw, length: len)
    }

    // MARK: Formulas

    /// Literal `<Tag>` or pointer `<pTag>`.
    private func numeric(_ n: GenICamNode, _ tag: String) throws -> Double? {
        if let literal = n.first(tag), let v = parseNumber(literal) { return v }
        if let pointer = n.first("p" + tag) { return try floatValue(pointer) }
        return nil
    }

    private func onValue(_ n: GenICamNode) -> Int64 { n.first("OnValue").flatMap { parseNumber($0) }.map { Int64($0) } ?? 1 }
    private func offValue(_ n: GenICamNode) -> Int64 { n.first("OffValue").flatMap { parseNumber($0) }.map { Int64($0) } ?? 0 }

    private func variables(_ n: GenICamNode) throws -> [String: Double] {
        var vars: [String: Double] = [:]
        for p in n.properties {
            guard let varName = p.attributes["Name"] else { continue }
            switch p.tag {
            case "pVariable": vars[varName] = try floatValue(p.text)
            case "Constant": vars[varName] = parseNumber(p.text) ?? 0
            case "Expression": vars[varName] = try Formula(p.text, integer: n.kind.hasPrefix("Int")).evaluate(vars)
            default: break
            }
        }
        return vars
    }

    private func convertFrom(_ n: GenICamNode) throws -> Double {
        guard let target = n.first("pValue") else { throw GenICamError.unsupported("\(n.name) has no pValue") }
        var vars = try variables(n)
        vars["TO"] = try floatValue(target)
        return try Formula(n.first("FormulaFrom") ?? "TO", integer: n.kind == "IntConverter").evaluate(vars)
    }

    private func evaluate(_ n: GenICamNode, formulaTag: String, integer: Bool) throws -> Double {
        try Formula(n.first(formulaTag) ?? "0", integer: integer).evaluate(try variables(n))
    }
}

func parseNumber(_ text: String) -> Double? {
    let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let negative = s.hasPrefix("-")
    let body = negative ? String(s.dropFirst()) : s
    if body.lowercased().hasPrefix("0x"), let v = UInt64(body.dropFirst(2), radix: 16) {
        return negative ? -Double(v) : Double(v)
    }
    return Double(s)
}

// MARK: - XML

private final class GenApiParser: NSObject, XMLParserDelegate {
    private var nodes: [String: GenICamNode] = [:]
    private var structs: [GenICamNode] = []
    private var stack: [String] = []
    private var current: GenICamNode?
    private var currentDepth = 0
    private var sub: GenICamNode?
    private var subDepth = 0
    private var property: (tag: String, attributes: [String: String], depth: Int)?
    private var text = ""
    private var error: Error?

    func parse(_ data: Data) throws -> [String: GenICamNode] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw error ?? parser.parserError ?? GenICamError.badFile("XML parse error")
        }
        // Each StructEntry becomes a register node inheriting its StructReg's address fields.
        for s in structs {
            for entry in s.entries {
                let node = GenICamNode(kind: "StructEntry", name: entry.name)
                let overridden = Set(entry.properties.map(\.tag))
                node.properties = s.properties.filter { !overridden.contains($0.tag) } + entry.properties
                nodes[entry.name] = node
            }
        }
        return nodes
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        let depth = stack.count
        let parent = stack.last ?? ""
        if current == nil, let name = attributes["Name"], parent == "RegisterDescription" || parent == "Group" {
            current = GenICamNode(kind: element, name: name)
            currentDepth = depth
        } else if let node = current, sub == nil, depth == currentDepth + 1,
                  element == "EnumEntry" || element == "StructEntry" {
            sub = GenICamNode(kind: element, name: attributes["Name"] ?? "")
            subDepth = depth
            _ = node
        } else if property == nil, current != nil, depth == (sub != nil ? subDepth : currentDepth) + 1 {
            property = (element, attributes, depth)
            text = ""
        }
        stack.append(element)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if property != nil { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        stack.removeLast()
        let depth = stack.count
        if let p = property, p.depth == depth {
            let value = GenICamNode.Property(tag: p.tag, attributes: p.attributes,
                                             text: text.trimmingCharacters(in: .whitespacesAndNewlines))
            (sub ?? current)?.properties.append(value)
            property = nil
        } else if let s = sub, subDepth == depth {
            current?.entries.append(s)
            sub = nil
        } else if let node = current, currentDepth == depth {
            if node.kind == "StructReg" {
                structs.append(node)
            } else {
                nodes[node.name] = node
            }
            current = nil
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        error = parseError
    }
}

// MARK: - Formula evaluator (GenICam SwissKnife / Converter syntax)

struct Formula {
    private enum Token: Equatable {
        case number(Double)
        case identifier(String)
        case op(String)
    }

    private let tokens: [Token]
    private let integer: Bool

    init(_ source: String, integer: Bool) throws {
        self.integer = integer
        tokens = try Formula.tokenize(source)
    }

    func evaluate(_ variables: [String: Double]) throws -> Double {
        var parser = Parser(tokens: tokens, variables: variables, integer: integer)
        let value = try parser.ternary()
        guard parser.index == tokens.count else { throw GenICamError.formula("unexpected trailing input") }
        return value
    }

    private static let operators = ["**", "<<", ">>", "<=", ">=", "<>", "&&", "||",
                                    "+", "-", "*", "/", "%", "&", "|", "^", "~", "!", "=", "<", ">",
                                    "?", ":", "(", ")", ","]

    private static func tokenize(_ s: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                var j = i
                if c == "0", j + 1 < chars.count, chars[j + 1] == "x" || chars[j + 1] == "X" {
                    j += 2
                    while j < chars.count, chars[j].isHexDigit { j += 1 }
                } else {
                    while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
                    if j < chars.count, chars[j] == "e" || chars[j] == "E" {
                        j += 1
                        if j < chars.count, chars[j] == "-" || chars[j] == "+" { j += 1 }
                        while j < chars.count, chars[j].isNumber { j += 1 }
                    }
                }
                guard let v = parseNumber(String(chars[i..<j])) else { throw GenICamError.formula("bad number") }
                tokens.append(.number(v))
                i = j
                continue
            }
            if c.isLetter || c == "_" {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "." { j += 1 }
                tokens.append(.identifier(String(chars[i..<j])))
                i = j
                continue
            }
            let rest = String(chars[i..<min(i + 2, chars.count)])
            guard let op = operators.first(where: { rest.hasPrefix($0) }) else {
                throw GenICamError.formula("unexpected '\(c)'")
            }
            tokens.append(.op(op))
            i += op.count
        }
        return tokens
    }

    private struct Parser {
        let tokens: [Token]
        let variables: [String: Double]
        let integer: Bool
        var index = 0

        private mutating func accept(_ op: String) -> Bool {
            if index < tokens.count, tokens[index] == .op(op) { index += 1; return true }
            return false
        }

        private func i64(_ v: Double) -> Int64 { Int64(v.rounded(.towardZero)) }

        private var depth = 0

        mutating func ternary() throws -> Double {
            depth += 1
            defer { depth -= 1 }
            guard depth < 256 else { throw GenICamError.formula("nested too deeply") }
            let condition = try binary(1)
            if accept("?") {
                let a = try ternary()
                guard accept(":") else { throw GenICamError.formula("expected ':'") }
                let b = try ternary()
                return condition != 0 ? a : b
            }
            return condition
        }

        private static let precedence: [String: Int] = [
            "||": 1, "&&": 2, "|": 3, "^": 4, "&": 5, "=": 6, "<>": 6,
            "<": 7, ">": 7, "<=": 7, ">=": 7, "<<": 8, ">>": 8, "+": 9, "-": 9, "*": 10, "/": 10, "%": 10,
        ]

        /// Precedence climbing: one stack frame per nesting level rather than one per precedence level.
        mutating func binary(_ minPrecedence: Int) throws -> Double {
            var lhs = try power()
            while index < tokens.count, case .op(let op) = tokens[index],
                  let prec = Parser.precedence[op], prec >= minPrecedence {
                index += 1
                let rhs = try binary(prec + 1)
                lhs = try apply(op, lhs, rhs)
            }
            return lhs
        }

        private func apply(_ op: String, _ lhs: Double, _ rhs: Double) throws -> Double {
            switch op {
            case "||": return (lhs != 0 || rhs != 0) ? 1 : 0
            case "&&": return (lhs != 0 && rhs != 0) ? 1 : 0
            case "|": return Double(i64(lhs) | i64(rhs))
            case "^": return Double(i64(lhs) ^ i64(rhs))
            case "&": return Double(i64(lhs) & i64(rhs))
            case "=": return lhs == rhs ? 1 : 0
            case "<>": return lhs != rhs ? 1 : 0
            case "<": return lhs < rhs ? 1 : 0
            case ">": return lhs > rhs ? 1 : 0
            case "<=": return lhs <= rhs ? 1 : 0
            case ">=": return lhs >= rhs ? 1 : 0
            case "<<": return Double(i64(lhs) << i64(rhs))
            case ">>": return Double(i64(lhs) >> i64(rhs))
            case "+": return lhs + rhs
            case "-": return lhs - rhs
            case "*": return lhs * rhs
            case "/":
                guard rhs != 0 else { throw GenICamError.formula("division by zero") }
                return integer ? Double(i64(lhs) / i64(rhs)) : lhs / rhs
            case "%":
                guard rhs != 0 else { throw GenICamError.formula("division by zero") }
                return Double(i64(lhs) % i64(rhs))
            default:
                throw GenICamError.formula("unknown operator \(op)")
            }
        }

        mutating func power() throws -> Double {
            let base = try unary()
            if accept("**") { return pow(base, try power()) }
            return base
        }

        mutating func unary() throws -> Double {
            if accept("-") { return -(try unary()) }
            if accept("+") { return try unary() }
            if accept("!") { return try unary() == 0 ? 1 : 0 }
            if accept("~") { return Double(~i64(try unary())) }
            return try primary()
        }

        mutating func primary() throws -> Double {
            guard index < tokens.count else { throw GenICamError.formula("unexpected end") }
            let token = tokens[index]
            index += 1
            switch token {
            case .number(let v):
                return v
            case .op("("):
                let v = try ternary()
                guard accept(")") else { throw GenICamError.formula("expected ')'") }
                return v
            case .identifier(let name):
                if accept("(") {
                    var args: [Double] = []
                    if !accept(")") {
                        repeat { args.append(try ternary()) } while accept(",")
                        guard accept(")") else { throw GenICamError.formula("expected ')'") }
                    }
                    return try call(name.uppercased(), args)
                }
                if let v = variables[name] { return v }
                switch name.uppercased() {
                case "PI": return .pi
                case "E": return M_E
                default: throw GenICamError.formula("unknown variable \(name)")
                }
            default:
                throw GenICamError.formula("unexpected token")
            }
        }

        private func call(_ name: String, _ a: [Double]) throws -> Double {
            guard let x = a.first else { throw GenICamError.formula("\(name) needs an argument") }
            switch name {
            case "ABS": return abs(x)
            case "SGN": return x > 0 ? 1 : (x < 0 ? -1 : 0)
            case "NEG": return -x
            case "SQRT": return sqrt(x)
            case "EXP": return exp(x)
            case "LN": return log(x)
            case "LG": return log10(x)
            case "SIN": return sin(x)
            case "COS": return cos(x)
            case "TAN": return tan(x)
            case "ASIN": return asin(x)
            case "ACOS": return acos(x)
            case "ATAN": return atan(x)
            case "TRUNC": return x.rounded(.towardZero)
            case "FLOOR": return x.rounded(.down)
            case "CEIL": return x.rounded(.up)
            case "ROUND":
                let digits = a.count > 1 ? a[1] : 0
                let scale = pow(10, digits)
                return (x * scale).rounded() / scale
            default: throw GenICamError.formula("unknown function \(name)")
            }
        }
    }
}

// MARK: - Little-endian helpers

extension Data {
    func u16(_ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        return withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
    }

    func u32(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    func u64(_ offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= count else { return 0 }
        return withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
    }
}
