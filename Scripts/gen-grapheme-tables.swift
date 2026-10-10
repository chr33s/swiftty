// Generates Sources/SwifttyCore/Terminal/GraphemeBreakTables.swift (default)
// or Tests/SwifttyCoreTests/GraphemeBreakTestData.swift (`--test-data`).
//
// The per-scalar properties replicate Ghostty's unicode props table
// (src/unicode/props_uucode.zig, built by the `uucode` package):
//
//   grapheme_break          uucode `grapheme_break_no_control`: UAX #29
//                           Grapheme_Cluster_Break refined with
//                           Indic_Conjunct_Break, Extended_Pictographic and
//                           Emoji_Modifier(_Base); Control/CR/LF fold to Other.
//   width_zero_in_grapheme  uucode `wcwidth_zero_in_grapheme` (see below).
//   emoji_vs_base           scalars with a "text style" (FE0E) line in
//                           emoji-variation-sequences.txt.
//
// Usage:
//   Scripts/update-grapheme-tables.sh <ucd-dir>
// This stages both outputs before replacing the checked-in files.
//
// <ucd-dir> is a UCD tree laid out like uucode's vendored copy
// (Ghostty's zig-pkg/uucode-*/ucd): DerivedCoreProperties.txt,
// extracted/DerivedGeneralCategory.txt, auxiliary/GraphemeBreakProperty.txt,
// auxiliary/GraphemeBreakTest.txt, emoji/emoji-data.txt,
// emoji/emoji-variation-sequences.txt. Use the same Unicode version as the
// Ghostty build being mirrored.
import Foundation

let args = CommandLine.arguments.dropFirst()
guard let dir = args.first,
  args.count == 1 || (args.count == 2 && args.last == "--test-data")
else {
  FileHandle.standardError.write(
    "usage: gen-grapheme-tables.swift <ucd-dir> [--test-data]\n"
      .data(using: .utf8)!
  )
  exit(2)
}
let ucd = URL(fileURLWithPath: dir)

func fail(_ path: String, _ message: String, line: Int? = nil) -> Never {
  let suffix = line.map { ":\($0)" } ?? ""
  FileHandle.standardError.write(
    Data("\(ucd.appendingPathComponent(path).path)\(suffix): \(message)\n".utf8)
  )
  exit(1)
}

func codePoint(_ token: String) -> Int? {
  guard !token.isEmpty, token.utf8.count <= 6,
    token.utf8.allSatisfy({
      (48 ... 57).contains($0) || (65 ... 70).contains($0)
        || (97 ... 102).contains($0)
    }), let value = Int(token, radix: 16), value <= 0x10FFFF
  else { return nil }
  return value
}

func records(_ text: String) -> [(line: Int, content: String)] {
  text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    .enumerated()
    .compactMap { index, line in
      let content = line.prefix { $0 != "#" }
        .trimmingCharacters(in: .whitespaces)
      return content.isEmpty ? nil : (index + 1, content)
    }
}

var inputVersion: String?

func read(_ path: String) -> String {
  let url = ucd.appendingPathComponent(path)
  let text: String
  do { text = try String(contentsOf: url, encoding: .utf8) } catch {
    FileHandle.standardError.write(
      Data("cannot read \(url.path): \(error.localizedDescription)\n".utf8)
    )
    exit(1)
  }
  let release = version(text, path: path)
  if let inputVersion, release != inputVersion {
    fail(path, "Unicode version \(release) does not match \(inputVersion)")
  }
  inputVersion = release
  let last = text.split(whereSeparator: \.isNewline)
    .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
    .trimmingCharacters(in: .whitespaces)
  guard last == "# EOF" || last == "#EOF" else {
    fail(path, "missing final EOF marker (input may be truncated)")
  }
  return text
}

func version(_ text: String, path: String) -> String {
  let emoji = path.hasPrefix("emoji/")
  let name = URL(fileURLWithPath: path).deletingPathExtension()
    .lastPathComponent
  let prefix = emoji ? "# Version:" : "# \(name)-"
  var found: String?
  for (index, line)
    in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    .enumerated()
  {
    let header = line.trimmingCharacters(in: .whitespaces)
    guard header.hasPrefix(prefix) else { continue }
    let value: String
    if emoji {
      value = String(header.dropFirst(prefix.count))
        .trimmingCharacters(in: .whitespaces)
    } else {
      guard header.hasSuffix(".txt") else {
        fail(path, "invalid version header", line: index + 1)
      }
      value = String(header.dropFirst(prefix.count).dropLast(4))
    }
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard (parts.count == 3 || (emoji && parts.count == 2)),
      parts.allSatisfy({
        !$0.isEmpty && $0.utf8.allSatisfy { (48 ... 57).contains($0) }
      })
    else { fail(path, "invalid version header", line: index + 1) }
    let release = parts.count == 2 ? value + ".0" : value
    guard found == nil || found == release else {
      fail(path, "conflicting version headers", line: index + 1)
    }
    found = release
  }
  guard let found else { fail(path, "missing version header") }
  return found
}

/// Parses `lo..hi ; field1 ; field2 # comment` lines.
func parse(
  _ text: String,
  path: String,
  fieldCount: ClosedRange<Int> = 1 ... 1,
  exclusive: Bool = false,
  _ body: (ClosedRange<Int>, [String], Int) -> Void
) {
  let entries = records(text)
  var assigned = exclusive ? [Bool](repeating: false, count: 0x110000) : []
  guard !entries.isEmpty else {
    fail(path, "input contains no property records")
  }
  for (number, content) in entries {
    let fields = content.split(separator: ";", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    guard fieldCount.contains(fields.count - 1),
      fields.allSatisfy({ !$0.isEmpty })
    else { fail(path, "invalid property record", line: number) }
    let bounds = fields[0].components(separatedBy: "..")
    guard (1 ... 2).contains(bounds.count), let first = codePoint(bounds[0]),
      let last = codePoint(bounds[bounds.count - 1]), first <= last
    else { fail(path, "invalid code point or range", line: number) }
    if exclusive {
      for cp in first ... last {
        guard !assigned[cp] else {
          fail(path, "overlapping property ranges", line: number)
        }
        assigned[cp] = true
      }
    }
    body(first ... last, Array(fields.dropFirst()), number)
  }
}

// Original Grapheme_Cluster_Break names, shared by both generation modes.
enum OGB: String {
  case other = "Other"
  case prepend = "Prepend"
  case cr = "CR"
  case lf = "LF"
  case control = "Control"
  case extend = "Extend"
  case ri = "Regional_Indicator"
  case spacingMark = "SpacingMark"
  case l = "L"
  case v = "V"
  case t = "T"
  case lv = "LV"
  case lvt = "LVT"
  case zwj = "ZWJ"
}

// MARK: - Test data mode

if args.contains("--test-data") {
  let text = read("auxiliary/GraphemeBreakTest.txt")
  // Scalars whose original Grapheme_Cluster_Break is Control/CR/LF. Ghostty
  // filters those before graphemeBreak, so the conformance test skips them.
  var controls = Set<Int>()
  parse(
    read("auxiliary/GraphemeBreakProperty.txt"),
    path: "auxiliary/GraphemeBreakProperty.txt",
    exclusive: true
  ) { range, f, number in
    guard OGB(rawValue: f[0]) != nil else {
      fail(
        "auxiliary/GraphemeBreakProperty.txt",
        "unknown GCB \(f[0])",
        line: number
      )
    }
    if ["Control", "CR", "LF"].contains(f[0]) {
      for cp in range { controls.insert(cp) }
    }
  }
  var used = Set<Int>()
  var cases: [String] = []
  for (number, content) in records(text) {
    let source = content.split(whereSeparator: \.isWhitespace)
    guard source.count >= 3, source.count % 2 == 1, source.first == "÷",
      source.last == "÷"
    else {
      fail(
        "auxiliary/GraphemeBreakTest.txt",
        "invalid grapheme test boundaries",
        line: number
      )
    }
    for (index, token) in source.enumerated() {
      if index % 2 == 0 {
        guard token == "÷" || token == "×" else {
          fail(
            "auxiliary/GraphemeBreakTest.txt",
            "invalid break marker",
            line: number
          )
        }
      } else {
        guard let point = codePoint(String(token)), Unicode.Scalar(point) != nil
        else {
          fail(
            "auxiliary/GraphemeBreakTest.txt",
            "invalid Unicode scalar",
            line: number
          )
        }
        used.insert(point)
      }
    }
    // Compact encoding: "÷" -> "/", "×" -> "x", scalars as hex.
    let tokens = source.map { tok -> String in
      switch tok {
      case "÷": "/"
      case "×": "x"
      default: String(tok)
      }
    }
    cases.append(tokens.joined(separator: " "))
  }
  guard !cases.isEmpty else {
    fail(
      "auxiliary/GraphemeBreakTest.txt",
      "input contains no grapheme test cases"
    )
  }
  let testVersion = version(text, path: "auxiliary/GraphemeBreakTest.txt")
  print(
    "// Generated by Scripts/gen-grapheme-tables.swift --test-data from GraphemeBreakTest-\(testVersion).txt. Do not edit."
  )
  print(
    "// Each line: \"/\" = break (÷), \"x\" = no break (×), scalars in hex."
  )
  print("// swiftlint:disable all")
  print("")
  print("enum GraphemeBreakTestData {")
  print("    static let version = \"\(testVersion)\"")
  print("    static let cases: [String] = [")
  for c in cases { print("        \"\(c)\",") }
  print("    ]")
  print("")
  print(
    "    /// Scalars in `cases` with Grapheme_Cluster_Break Control, CR or LF."
  )
  let ctl = used.intersection(controls).sorted()
    .map { String(format: "0x%04X", $0) }
  print(
    "    static let controls: Set<UInt32> = [" + ctl.joined(separator: ", ")
      + "]"
  )
  print("}")
  print("")
  print("// swiftlint:enable all")
  exit(0)
}

// MARK: - Property tables

let count = 0x110000

var ogb = [OGB](repeating: .other, count: count)
let gbpText = read("auxiliary/GraphemeBreakProperty.txt")
parse(gbpText, path: "auxiliary/GraphemeBreakProperty.txt", exclusive: true) {
  range,
  f,
  number in
  guard let value = OGB(rawValue: f[0]) else {
    fail(
      "auxiliary/GraphemeBreakProperty.txt",
      "unknown GCB \(f[0])",
      line: number
    )
  }
  for cp in range { ogb[cp] = value }
}

enum InCB { case none, linker, consonant, extend }
var incb = [InCB](repeating: .none, count: count)
var incbAssigned = [Bool](repeating: false, count: count)
var defaultIgnorable = [Bool](repeating: false, count: count)
parse(
  read("DerivedCoreProperties.txt"),
  path: "DerivedCoreProperties.txt",
  fieldCount: 1 ... 2
) { range, f, number in
  guard f.count == (f[0] == "InCB" ? 2 : 1) else {
    fail("DerivedCoreProperties.txt", "invalid property fields", line: number)
  }
  if f[0] == "InCB" {
    let value: InCB =
      switch f[1] {
      case "Linker": .linker
      case "Consonant": .consonant
      case "Extend": .extend
      case "None": .none
      default:
        fail("DerivedCoreProperties.txt", "unknown InCB \(f[1])", line: number)
      }
    for cp in range {
      guard !incbAssigned[cp] else {
        fail(
          "DerivedCoreProperties.txt",
          "overlapping InCB ranges",
          line: number
        )
      }
      incbAssigned[cp] = true
      incb[cp] = value
    }
  } else if f[0] == "Default_Ignorable_Code_Point" {
    for cp in range { defaultIgnorable[cp] = true }
  }
}

var extPict = [Bool](repeating: false, count: count)
var emojiModifier = [Bool](repeating: false, count: count)
var emojiModifierBase = [Bool](repeating: false, count: count)
let emojiText = read("emoji/emoji-data.txt")
let emojiProperties: Set<String> = [
  "Emoji", "Emoji_Presentation", "Emoji_Modifier", "Emoji_Modifier_Base",
  "Emoji_Component", "Extended_Pictographic",
]
parse(emojiText, path: "emoji/emoji-data.txt") { range, f, number in
  guard emojiProperties.contains(f[0]) else {
    fail("emoji/emoji-data.txt", "unknown emoji property \(f[0])", line: number)
  }
  switch f[0] {
  case "Extended_Pictographic": for cp in range { extPict[cp] = true }
  case "Emoji_Modifier": for cp in range { emojiModifier[cp] = true }
  case "Emoji_Modifier_Base": for cp in range { emojiModifierBase[cp] = true }
  default: break
  }
}

// General categories that matter for wcwidth_zero_in_grapheme.
enum GC { case other, cc, cs, zl, zp, mn, me }
var gc = [GC](repeating: .other, count: count)
let categories: Set<String> = [
  "Lu", "Ll", "Lt", "Lm", "Lo", "Mn", "Mc", "Me", "Nd", "Nl", "No", "Pc", "Pd",
  "Ps", "Pe", "Pi", "Pf", "Po", "Sm", "Sc", "Sk", "So", "Zs", "Zl", "Zp", "Cc",
  "Cf", "Cs", "Co", "Cn",
]
parse(
  read("extracted/DerivedGeneralCategory.txt"),
  path: "extracted/DerivedGeneralCategory.txt",
  exclusive: true
) { range, f, number in
  guard categories.contains(f[0]) else {
    fail(
      "extracted/DerivedGeneralCategory.txt",
      "unknown general category \(f[0])",
      line: number
    )
  }
  let value: GC =
    switch f[0] {
    case "Cc": .cc
    case "Cs": .cs
    case "Zl": .zl
    case "Zp": .zp
    case "Mn": .mn
    case "Me": .me
    default: .other
    }
  for cp in range { gc[cp] = value }
}

var vsBase = [Bool](repeating: false, count: count)
let variations = records(read("emoji/emoji-variation-sequences.txt"))
guard !variations.isEmpty else {
  fail(
    "emoji/emoji-variation-sequences.txt",
    "input contains no variation sequences"
  )
}
for (number, content) in variations {
  var fields = content.split(separator: ";", omittingEmptySubsequences: false)
    .map { $0.trimmingCharacters(in: .whitespaces) }
  if fields.last == "" { fields.removeLast() }
  guard fields.count == 2 else {
    fail(
      "emoji/emoji-variation-sequences.txt",
      "invalid variation record",
      line: number
    )
  }
  let tokens = fields[0].split(whereSeparator: \.isWhitespace)
  guard tokens.count == 2, let base = codePoint(String(tokens[0])),
    Unicode.Scalar(base) != nil, let selector = codePoint(String(tokens[1])),
    (selector == 0xFE0E && fields[1] == "text style")
      || (selector == 0xFE0F && fields[1] == "emoji style")
  else {
    fail(
      "emoji/emoji-variation-sequences.txt",
      "invalid variation sequence",
      line: number
    )
  }
  if selector == 0xFE0E { vsBase[base] = true }
}

// GraphemeBreakNoControl ordinals (must match GraphemeBreak.Property in Swift).
let other = 0
let prepend = 1
let ri = 2
let spacingMark = 3
let hl = 4
let hv = 5
let ht = 6
let hlv = 7
let hlvt = 8
let zwj = 9
let zwnj = 10
let extendedPictographic = 11
let emojiModBase = 12
let emojiMod = 13
let incbExtend = 14
let incbLinkerExtend = 15
let incbLinkerOther = 16
let incbConsonant = 17

var props = [UInt8](repeating: 0, count: count)
for cp in 0 ..< count {
  // uucode GraphemeBreak component (components.zig), then NoControl folding.
  let gb: Int
  if emojiModifier[cp] {
    guard ogb[cp] == .extend else {
      fail(
        "emoji/emoji-data.txt",
        "Emoji_Modifier must have GCB Extend at U+\(String(cp, radix: 16))"
      )
    }
    gb = emojiMod
  } else if emojiModifierBase[cp] {
    guard extPict[cp] else {
      fail(
        "emoji/emoji-data.txt",
        "Emoji_Modifier_Base must be Extended_Pictographic at U+\(String(cp, radix: 16))"
      )
    }
    gb = emojiModBase
  } else if extPict[cp] {
    guard ogb[cp] == .other else {
      fail(
        "emoji/emoji-data.txt",
        "Extended_Pictographic must have GCB Other at U+\(String(cp, radix: 16))"
      )
    }
    gb = extendedPictographic
  } else {
    switch incb[cp] {
    case .none:
      switch ogb[cp] {
      case .other, .cr, .lf, .control: gb = other
      case .prepend: gb = prepend
      case .ri: gb = ri
      case .spacingMark: gb = spacingMark
      case .l: gb = hl
      case .v: gb = hv
      case .t: gb = ht
      case .lv: gb = hlv
      case .lvt: gb = hlvt
      case .zwj: gb = zwj
      case .extend:
        guard cp == 0x200C else {
          fail(
            "DerivedCoreProperties.txt",
            "Extend without InCB at U+\(String(cp, radix: 16))"
          )
        }
        gb = zwnj
      }
    case .extend: gb = cp == 0x200D ? zwj : incbExtend
    case .linker: gb = ogb[cp] == .extend ? incbLinkerExtend : incbLinkerOther
    case .consonant: gb = incbConsonant
    }
  }

  // uucode Wcwidth component (components.zig):
  //   width == 0  <=>  gc in {Cc, Cs, Zl, Zp} or (Default_Ignorable and not U+00AD)
  //   wcwidth_zero_in_grapheme = width == 0 or Emoji_Modifier or gc in {Mn, Me}
  //                              or GCB in {V, T, Prepend}
  let width0 =
    gc[cp] == .cc || gc[cp] == .cs || gc[cp] == .zl || gc[cp] == .zp
    || (cp != 0x00AD && defaultIgnorable[cp])
  let zero =
    width0 || emojiModifier[cp] || gc[cp] == .mn || gc[cp] == .me
    || ogb[cp] == .v || ogb[cp] == .t || ogb[cp] == .prepend

  props[cp] = UInt8(gb) | (zero ? 0x20 : 0) | (vsBase[cp] ? 0x40 : 0)
}

// Two-stage table; pick the block size giving the smallest total.
func build(shift: Int) -> (stage1: [Int], stage2: [UInt8]) {
  let size = 1 << shift
  var stage1: [Int] = []
  var stage2: [UInt8] = []
  var seen: [[UInt8]: Int] = [:]
  for block in 0 ..< count >> shift {
    let slice = Array(props[block << shift ..< (block + 1) << shift])
    if let index = seen[slice] {
      stage1.append(index)
    } else {
      seen[slice] = stage2.count >> shift
      stage1.append(stage2.count >> shift)
      stage2.append(contentsOf: slice)
    }
    _ = size
  }
  return (stage1, stage2)
}
var best = (shift: 0, stage1: [Int](), stage2: [UInt8]())
for shift in 5 ... 8 {
  let t = build(shift: shift)
  let bytes = t.stage1.count * 2 + t.stage2.count
  FileHandle.standardError.write(
    "shift=\(shift) stage1=\(t.stage1.count) stage2=\(t.stage2.count) total=\(bytes)\n"
      .data(using: .utf8)!
  )
  if best.stage1.isEmpty || bytes < best.stage1.count * 2 + best.stage2.count {
    best = (shift, t.stage1, t.stage2)
  }
}
precondition(best.stage2.count >> best.shift <= Int(UInt16.max))

func escape(_ bytes: [UInt8]) -> String {
  var s = ""
  for b in bytes {
    switch b {
    case 0x21 ... 0x7E where b != 0x22 && b != 0x5C:
      s.unicodeScalars.append(Unicode.Scalar(b))
    default: s += "\\u{\(String(b, radix: 16, uppercase: true))}"
    }
  }
  return s
}

let ucdVersion = version(gbpText, path: "auxiliary/GraphemeBreakProperty.txt")
print(
  "// Generated by Scripts/gen-grapheme-tables.swift from UCD \(ucdVersion) (GraphemeBreakProperty,"
)
print(
  "// DerivedCoreProperties InCB/Default_Ignorable, DerivedGeneralCategory, emoji-data,"
)
print("// emoji-variation-sequences). Do not edit.")
print("// swiftlint:disable all")
print("")
print("enum GraphemeBreakTables {")
print("    static let version = \"\(ucdVersion)\"")
print("")
print("    /// Block size is `1 << shift` scalars.")
print("    static let shift = \(best.shift)")
print("")
print(
  "    /// Block index for each block of scalars (\(best.stage1.count) entries)."
)
print("    static let stage1: [UInt16] = [")
for chunk in stride(from: 0, to: best.stage1.count, by: 24) {
  print(
    "        "
      + best.stage1[chunk ..< min(chunk + 24, best.stage1.count)]
      .map { String($0) }.joined(separator: ", ") + ","
  )
}
print("    ]")
print("")
print(
  "    /// \(best.stage2.count >> best.shift) unique blocks of property bytes:"
)
print(
  "    /// bits 0-4 GraphemeBreak.Property, bit 5 width_zero_in_grapheme, bit 6 emoji_vs_base."
)
print("    static let stage2: StaticString = \"" + escape(best.stage2) + "\"")
print("")
print("    static let stage2Count = \(best.stage2.count)")
print("}")
print("")
print("// swiftlint:enable all")
