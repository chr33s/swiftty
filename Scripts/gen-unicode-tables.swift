// Generates Sources/SwifttyCore/Unicode/Tables.swift.
//
// Widths follow wcwidth conventions: zero for nonspacing/enclosing marks,
// format characters (except prepended concatenation marks) and Hangul
// medial/final jamo; two for East Asian
// Wide/Fullwidth and emoji-presentation scalars; one otherwise.
//
// Usage: swift Scripts/gen-unicode-tables.swift [EastAsianWidth.txt]
// Local inputs also require PropList.txt, extracted/DerivedGeneralCategory.txt
// and emoji/emoji-data.txt beside EastAsianWidth.txt in the same UCD tree.
import Foundation

guard CommandLine.arguments.count <= 2 else {
    FileHandle.standardError.write(Data("usage: gen-unicode-tables.swift [EastAsianWidth.txt]\n".utf8))
    exit(2)
}
let source = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(string: "https://www.unicode.org/Public/UCD/latest/ucd/EastAsianWidth.txt")!
func fail(_ message: String, line: Int? = nil, file: URL? = nil) -> Never {
    let input = file ?? source
    let location = input.isFileURL ? input.path : input.absoluteString
    let suffix = line.map { ":\($0)" } ?? ""
    FileHandle.standardError.write(Data("\(location)\(suffix): \(message)\n".utf8))
    exit(1)
}

let text: String
do {
    text = try String(contentsOf: source, encoding: .utf8)
} catch {
    fail("cannot read input: \(error.localizedDescription)")
}

func codePoint(_ token: String) -> Int? {
    guard !token.isEmpty, token.utf8.count <= 6,
          token.utf8.allSatisfy({ (48 ... 57).contains($0) || (65 ... 70).contains($0) || (97 ... 102).contains($0) }),
          let value = Int(token, radix: 16), value <= 0x10FFFF else { return nil }
    return value
}

func requireEOF(_ text: String, file: URL? = nil) {
    let last = text.split(whereSeparator: \.isNewline).last {
        !$0.trimmingCharacters(in: .whitespaces).isEmpty
    }?.trimmingCharacters(in: .whitespaces)
    guard last == "# EOF" || last == "#EOF" else {
        fail("missing final EOF marker (input may be truncated)", file: file)
    }
}

var version = "unknown"
var wide = [Bool](repeating: false, count: 0x110000)
var widthAssigned = [Bool](repeating: false, count: 0x110000)
var records = 0
let properties: Set<String> = ["A", "F", "H", "N", "Na", "W"]
for (index, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
    let number = index + 1
    if line.hasPrefix("# EastAsianWidth-") {
        let header = line.trimmingCharacters(in: .whitespaces)
        guard header.hasSuffix(".txt") else { fail("invalid version header", line: number) }
        let candidate = String(header.dropFirst(17).dropLast(4))
        let components = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              components.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48 ... 57).contains($0) } }) else {
            fail("invalid version header", line: number)
        }
        guard version == "unknown" || version == candidate else { fail("conflicting version headers", line: number) }
        version = candidate
    }
    let body = line.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces)
    guard !body.isEmpty else { continue }
    let fields = body.split(separator: ";", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    guard fields.count == 2, properties.contains(fields[1]) else { fail("invalid East_Asian_Width record", line: number) }
    let bounds = fields[0].components(separatedBy: "..")
    guard (1 ... 2).contains(bounds.count), let first = codePoint(bounds[0]),
          let last = codePoint(bounds[bounds.count - 1]), first <= last else {
        fail("invalid code point or range", line: number)
    }
    records += 1
    let isWide = fields[1] == "W" || fields[1] == "F"
    for cp in first ... last {
        guard !widthAssigned[cp] else { fail("overlapping East_Asian_Width ranges", line: number) }
        widthAssigned[cp] = true
        wide[cp] = isWide
    }
}
guard records > 0 else { fail("input contains no East_Asian_Width records") }
guard version != "unknown" else { fail("missing version header") }
requireEOF(text)

/// Read all width properties from the release declared by EastAsianWidth,
/// rather than mixing that release with the host Swift runtime's Unicode data.
func parseProperties(_ path: String, exclusive: Bool = false, _ body: (ClosedRange<Int>, String, Int, URL) -> Void) {
    let input = source.isFileURL
        ? source.deletingLastPathComponent().appendingPathComponent(path)
        : URL(string: "https://www.unicode.org/Public/\(version)/ucd/\(path)")!
    let text: String
    do {
        text = try String(contentsOf: input, encoding: .utf8)
    } catch {
        fail("cannot read input: \(error.localizedDescription)", file: input)
    }
    let emoji = path.hasPrefix("emoji/")
    let name = input.deletingPathExtension().lastPathComponent
    let prefix = emoji ? "# Version:" : "# \(name)-"
    var release: String?
    var records = 0
    var assigned = exclusive ? [Bool](repeating: false, count: 0x110000) : []
    for (index, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
        let number = index + 1
        let header = line.trimmingCharacters(in: .whitespaces)
        if header.hasPrefix(prefix) {
            let candidate: String
            if emoji {
                candidate = String(header.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            } else {
                guard header.hasSuffix(".txt") else { fail("invalid version header", line: number, file: input) }
                candidate = String(header.dropFirst(prefix.count).dropLast(4))
            }
            let parts = candidate.split(separator: ".", omittingEmptySubsequences: false)
            guard (parts.count == 3 || (emoji && parts.count == 2)),
                  parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48 ... 57).contains($0) } }) else {
                fail("invalid version header", line: number, file: input)
            }
            let normalized = parts.count == 2 ? candidate + ".0" : candidate
            guard release == nil || release == normalized else { fail("conflicting version headers", line: number, file: input) }
            release = normalized
        }
        let content = line.prefix { $0 != "#" }.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { continue }
        let fields = content.split(separator: ";", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count == 2, !fields[1].isEmpty else { fail("invalid property record", line: number, file: input) }
        let bounds = fields[0].components(separatedBy: "..")
        guard (1 ... 2).contains(bounds.count), let first = codePoint(bounds[0]),
              let last = codePoint(bounds[bounds.count - 1]), first <= last else {
            fail("invalid code point or range", line: number, file: input)
        }
        if exclusive {
            for cp in first ... last {
                guard !assigned[cp] else { fail("overlapping property ranges", line: number, file: input) }
                assigned[cp] = true
            }
        }
        body(first ... last, fields[1], number, input)
        records += 1
    }
    guard records > 0 else { fail("input contains no property records", file: input) }
    guard let release else { fail("missing version header", file: input) }
    guard release == version else { fail("Unicode version \(release) does not match \(version)", file: input) }
    requireEOF(text, file: input)
}

// Prepended concatenation marks display despite their Cf category.
var prependedConcatenationMarks = Set<Int>()
parseProperties("PropList.txt") { range, property, _, _ in
    if property == "Prepended_Concatenation_Mark" { prependedConcatenationMarks.formUnion(range) }
}
guard !prependedConcatenationMarks.isEmpty else { fail("input contains no Prepended_Concatenation_Mark records") }

var zero = [Bool](repeating: false, count: 0x110000)
let categories: Set<String> = ["Lu", "Ll", "Lt", "Lm", "Lo", "Mn", "Mc", "Me", "Nd", "Nl", "No", "Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po", "Sm", "Sc", "Sk", "So", "Zs", "Zl", "Zp", "Cc", "Cf", "Cs", "Co", "Cn"]
parseProperties("extracted/DerivedGeneralCategory.txt", exclusive: true) { range, category, number, input in
    guard categories.contains(category) else { fail("unknown general category \(category)", line: number, file: input) }
    switch category {
    case "Mn", "Me": for cp in range { zero[cp] = true }
    case "Cf": for cp in range { zero[cp] = cp != 0x00AD && !prependedConcatenationMarks.contains(cp) }
    default: break
    }
}
for cp in 0x1160...0x11FF { zero[cp] = true }
for cp in 0xD7B0...0xD7FF { zero[cp] = true }
let emojiProperties: Set<String> = ["Emoji", "Emoji_Presentation", "Emoji_Modifier", "Emoji_Modifier_Base", "Emoji_Component", "Extended_Pictographic"]
parseProperties("emoji/emoji-data.txt") { range, property, number, input in
    guard emojiProperties.contains(property) else { fail("unknown emoji property \(property)", line: number, file: input) }
    if property == "Emoji_Presentation" { for cp in range { wide[cp] = true } }
}
for cp in 0..<0x110000 {
    if zero[cp] { wide[cp] = false }
}

func ranges(_ set: [Bool]) -> [(UInt32, UInt32)] {
    var out: [(UInt32, UInt32)] = []
    var cp = 0
    while cp < set.count {
        guard set[cp] else { cp += 1; continue }
        let start = cp
        while cp + 1 < set.count, set[cp + 1] { cp += 1 }
        out.append((UInt32(start), UInt32(cp)))
        cp += 1
    }
    return out
}

func emit(_ name: String, _ list: [(UInt32, UInt32)]) {
    print("    /// \(list.count) inclusive ranges, flattened as `[lo, hi, lo, hi, ...]`.")
    print("    static let \(name): [UInt32] = [")
    var row: [String] = []
    for (lo, hi) in list {
        row.append(String(format: "0x%05X, 0x%05X", lo, hi))
        if row.count == 4 { print("        " + row.joined(separator: ", ") + ","); row = [] }
    }
    if !row.isEmpty { print("        " + row.joined(separator: ", ") + ",") }
    print("    ]")
}

// Two-stage lookup table: stage 1 maps `scalar >> 8` to a deduplicated
// 256-entry block in stage 2. Stage 2 is emitted as a StaticString of ASCII
// digits '0'/'1'/'2' so it lives in the binary's constant data and costs
// nothing at startup.
var widths = [UInt8](repeating: 1, count: 0x110000)
for cp in 0 ..< 0x110000 {
    if wide[cp] { widths[cp] = 2 }
    if zero[cp] { widths[cp] = 0 }
}
var stage1: [Int] = []
var stage2: [UInt8] = []
var seen: [[UInt8]: Int] = [:]
for block in 0 ..< 0x1100 {
    let slice = Array(widths[block << 8 ..< (block + 1) << 8])
    if let index = seen[slice] {
        stage1.append(index)
    } else {
        seen[slice] = stage2.count >> 8
        stage1.append(stage2.count >> 8)
        stage2.append(contentsOf: slice)
    }
}

print("// Generated by Scripts/gen-unicode-tables.swift from UCD \(version) (EastAsianWidth,")
print("// DerivedGeneralCategory, PropList and emoji-data). Do not edit.")
print("// swiftlint:disable all")
print("")
print("enum UnicodeTables {")
print("    static let version = \"\(version)\"")
print("")
emit("zeroWidth", ranges(zero))
print("")
emit("wide", ranges(wide))
print("")
print("    /// Block index for each 256-scalar block (\(stage1.count) entries).")
print("    static let stage1: [UInt16] = [")
for chunk in stride(from: 0, to: stage1.count, by: 16) {
    print("        " + stage1[chunk ..< min(chunk + 16, stage1.count)].map { String($0) }.joined(separator: ", ") + ",")
}
print("    ]")
print("")
print("    /// \(stage2.count >> 8) unique blocks of widths as ASCII digits.")
print("    static let stage2: StaticString = \"" + String(decoding: stage2.map { $0 + 0x30 }, as: UTF8.self) + "\"")
print("}")
